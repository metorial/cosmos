package grpc

import (
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/metorial/fleet/cosmos/internal/controller/database"
	pb "github.com/metorial/fleet/cosmos/internal/proto"
	log "github.com/sirupsen/logrus"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
)

type Server struct {
	pb.UnimplementedCosmosControllerServer

	db         *database.ControllerDB
	port       int
	tlsConfig  *tls.Config
	grpcServer *grpc.Server

	streamsMu sync.RWMutex
	streams   map[string]pb.CosmosController_StreamAgentMessagesServer
}

type ServerConfig struct {
	DB        *database.ControllerDB
	Port      int
	TLSConfig *tls.Config
}

func NewServer(config *ServerConfig) *Server {
	return &Server{
		db:        config.DB,
		port:      config.Port,
		tlsConfig: config.TLSConfig,
		streams:   make(map[string]pb.CosmosController_StreamAgentMessagesServer),
	}
}

func (s *Server) Start() error {
	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", s.port))
	if err != nil {
		return fmt.Errorf("failed to listen: %w", err)
	}

	var opts []grpc.ServerOption

	if s.tlsConfig != nil {
		creds := credentials.NewTLS(s.tlsConfig)
		opts = append(opts, grpc.Creds(creds))
		log.Info("gRPC server using TLS")
	}

	s.grpcServer = grpc.NewServer(opts...)
	pb.RegisterCosmosControllerServer(s.grpcServer, s)

	log.WithField("port", s.port).Info("Starting gRPC server")

	go func() {
		if err := s.grpcServer.Serve(lis); err != nil {
			log.WithError(err).Error("gRPC server error")
		}
	}()

	return nil
}

func (s *Server) Stop() error {
	log.Info("Stopping gRPC server")

	if s.grpcServer != nil {
		s.grpcServer.GracefulStop()
	}

	return nil
}

func (s *Server) StreamAgentMessages(stream pb.CosmosController_StreamAgentMessagesServer) error {
	ctx := stream.Context()

	var hostname string
	p, ok := peer.FromContext(ctx)
	if ok && s.tlsConfig != nil {
		if tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo); ok {
			if len(tlsInfo.State.PeerCertificates) > 0 {
				hostname = tlsInfo.State.PeerCertificates[0].Subject.CommonName
				log.WithField("hostname", hostname).Info("Agent connected with mTLS")
			}
		}
	}

	if hostname == "" {
		log.Warn("Agent connected without valid certificate, waiting for heartbeat")
	}

	for {
		msg, err := stream.Recv()
		if err == io.EOF {
			log.WithField("hostname", hostname).Info("Agent stream closed")
			s.removeStream(hostname)
			return nil
		}
		if err != nil {
			log.WithError(err).WithField("hostname", hostname).Warn("Error receiving message from agent")
			s.removeStream(hostname)
			return err
		}

		if hostname == "" && msg.Hostname != "" {
			hostname = msg.Hostname
			log.WithField("hostname", hostname).Info("Agent identified via heartbeat")
		}

		if hostname != "" {
			s.registerStream(hostname, stream)
		}

		if err := s.handleAgentMessage(hostname, msg); err != nil {
			log.WithError(err).WithField("hostname", hostname).Error("Error handling agent message")
		}
	}
}

func (s *Server) handleAgentMessage(hostname string, msg *pb.AgentMessage) error {
	switch m := msg.Message.(type) {
	case *pb.AgentMessage_Heartbeat:
		return s.handleHeartbeat(hostname, m.Heartbeat)
	case *pb.AgentMessage_ComponentStatus:
		return s.handleComponentStatus(hostname, m.ComponentStatus)
	case *pb.AgentMessage_HealthResult:
		return s.handleHealthResult(hostname, m.HealthResult)
	case *pb.AgentMessage_DeploymentResult:
		return s.handleDeploymentResult(hostname, m.DeploymentResult)
	default:
		log.WithField("hostname", hostname).Warn("Received unknown message type from agent")
	}

	return nil
}

func (s *Server) handleHeartbeat(hostname string, heartbeat *pb.AgentHeartbeat) error {
	log.WithFields(log.Fields{
		"hostname": hostname,
		"version":  heartbeat.AgentVersion,
	}).Debug("Received heartbeat")

	componentCount := len(heartbeat.ComponentStatuses)

	agent := &database.Agent{
		Hostname:       hostname,
		AgentVersion:   heartbeat.AgentVersion,
		LastHeartbeat:  time.Now(),
		Online:         true,
		ComponentCount: componentCount,
	}

	if err := s.db.UpsertAgent(agent); err != nil {
		return err
	}

	node := &database.Node{
		Hostname: hostname,
		Tags:     []string{"all"}, // pq.StringArray will handle conversion
		Online:   true,
		HasAgent: true,
		LastSeen: &agent.LastHeartbeat,
	}

	if err := s.db.UpsertNode(node); err != nil {
		return err
	}

	// Process component statuses from heartbeat
	for _, compStatus := range heartbeat.ComponentStatuses {
		if err := s.handleComponentStatus(hostname, compStatus); err != nil {
			log.WithError(err).WithFields(log.Fields{
				"hostname":  hostname,
				"component": compStatus.Name,
			}).Warn("Failed to handle component status from heartbeat")
		}
	}

	return nil
}

func (s *Server) handleComponentStatus(hostname string, status *pb.ComponentStatus) error {
	log.WithFields(log.Fields{
		"hostname":  hostname,
		"component": status.Name,
		"status":    status.Status,
	}).Debug("Received component status")

	deployment := &database.ComponentDeployment{
		ComponentName: status.Name,
		NodeHostname:  hostname,
		Status:        status.Status,
		Message:       status.Message,
	}

	if status.Pid > 0 {
		pid := int(status.Pid)
		deployment.PID = &pid
	}

	if status.LastStartedAt > 0 {
		t := time.Unix(status.LastStartedAt, 0)
		deployment.LastStartedAt = &t
	}

	now := time.Now()
	deployment.LastUpdated = &now

	return s.db.UpsertComponentDeployment(deployment)
}

func (s *Server) handleHealthResult(hostname string, result *pb.HealthCheckResult) error {
	log.WithFields(log.Fields{
		"hostname":  hostname,
		"component": result.ComponentName,
		"result":    result.Result,
	}).Debug("Received health check result")

	healthStatus := "healthy"
	if result.Result != "success" && result.Result != "healthy" {
		healthStatus = "unhealthy"
	}

	now := time.Now()
	deployment := &database.ComponentDeployment{
		ComponentName:   result.ComponentName,
		NodeHostname:    hostname,
		HealthStatus:    healthStatus,
		LastHealthCheck: &now,
	}

	if result.Message != "" {
		deployment.Message = result.Message
	}

	return s.db.UpsertComponentDeployment(deployment)
}

func (s *Server) handleDeploymentResult(hostname string, result *pb.DeploymentResult) error {
	log.WithFields(log.Fields{
		"hostname":  hostname,
		"component": result.ComponentName,
		"operation": result.Operation,
		"result":    result.Result,
	}).Info("Received deployment result")

	status := "running"
	if result.Result == "failure" || result.Result == "failed" {
		status = "failed"
	}

	now := time.Now()
	deployment := &database.ComponentDeployment{
		ComponentName: result.ComponentName,
		NodeHostname:  hostname,
		Status:        status,
		Message:       result.Message,
		DeployedAt:    &now,
		LastUpdated:   &now,
	}

	return s.db.UpsertComponentDeployment(deployment)
}

func (s *Server) registerStream(hostname string, stream pb.CosmosController_StreamAgentMessagesServer) {
	s.streamsMu.Lock()
	defer s.streamsMu.Unlock()

	if _, exists := s.streams[hostname]; !exists {
		log.WithField("hostname", hostname).Info("Registered agent stream")
	}

	s.streams[hostname] = stream
}

func (s *Server) removeStream(hostname string) {
	s.streamsMu.Lock()
	defer s.streamsMu.Unlock()

	if _, exists := s.streams[hostname]; exists {
		delete(s.streams, hostname)
		log.WithField("hostname", hostname).Info("Removed agent stream")
	}
}

func (s *Server) SendDeployment(hostname string, deployment *pb.ComponentDeployment) error {
	s.streamsMu.RLock()
	stream, exists := s.streams[hostname]
	s.streamsMu.RUnlock()

	log.WithFields(log.Fields{
		"hostname":      hostname,
		"component":     deployment.ComponentName,
		"stream_exists": exists,
		"total_streams": len(s.streams),
	}).Info("Attempting to send deployment to agent")

	if !exists {
		s.streamsMu.RLock()
		log.WithField("available_streams", s.getStreamHostnames()).Warn("No stream found for agent")
		s.streamsMu.RUnlock()
		return fmt.Errorf("no stream for agent %s", hostname)
	}

	msg := &pb.ControllerMessage{
		Message: &pb.ControllerMessage_Deployment{
			Deployment: deployment,
		},
	}

	log.WithFields(log.Fields{
		"hostname":  hostname,
		"component": deployment.ComponentName,
	}).Info("Sending deployment message to agent")

	err := stream.Send(msg)
	if err != nil {
		log.WithError(err).WithField("hostname", hostname).Error("Failed to send deployment message")
	} else {
		log.WithField("hostname", hostname).Info("Successfully sent deployment message")
	}

	return err
}

func (s *Server) getStreamHostnames() []string {
	hostnames := make([]string, 0, len(s.streams))
	for h := range s.streams {
		hostnames = append(hostnames, h)
	}
	return hostnames
}

func (s *Server) SendRemoval(hostname, componentName string) error {
	s.streamsMu.RLock()
	stream, exists := s.streams[hostname]
	s.streamsMu.RUnlock()

	if !exists {
		return fmt.Errorf("no stream for agent %s", hostname)
	}

	msg := &pb.ControllerMessage{
		Message: &pb.ControllerMessage_Removal{
			Removal: &pb.ComponentRemoval{
				ComponentName: componentName,
			},
		},
	}

	log.WithFields(log.Fields{
		"hostname":  hostname,
		"component": componentName,
	}).Info("Sending removal to agent")

	return stream.Send(msg)
}

func (s *Server) SendHealthConfig(hostname string, config *pb.HealthCheckConfig) error {
	s.streamsMu.RLock()
	stream, exists := s.streams[hostname]
	s.streamsMu.RUnlock()

	if !exists {
		return fmt.Errorf("no stream for agent %s", hostname)
	}

	msg := &pb.ControllerMessage{
		Message: &pb.ControllerMessage_HealthConfig{
			HealthConfig: config,
		},
	}

	return stream.Send(msg)
}

func (s *Server) SendAck(hostname, message string) error {
	s.streamsMu.RLock()
	stream, exists := s.streams[hostname]
	s.streamsMu.RUnlock()

	if !exists {
		return fmt.Errorf("no stream for agent %s", hostname)
	}

	msg := &pb.ControllerMessage{
		Message: &pb.ControllerMessage_Ack{
			Ack: &pb.Acknowledgment{
				Message: message,
			},
		},
	}

	return stream.Send(msg)
}

func (s *Server) GetConnectedAgents() []string {
	s.streamsMu.RLock()
	defer s.streamsMu.RUnlock()

	hostnames := make([]string, 0, len(s.streams))
	for hostname := range s.streams {
		hostnames = append(hostnames, hostname)
	}

	return hostnames
}

func (s *Server) BroadcastDeployment(deployment *pb.ComponentDeployment, targetNodes []string) []error {
	var errors []error

	for _, hostname := range targetNodes {
		if err := s.SendDeployment(hostname, deployment); err != nil {
			errors = append(errors, fmt.Errorf("%s: %w", hostname, err))
		}
	}

	return errors
}

func (s *Server) BroadcastRemoval(componentName string, targetNodes []string) []error {
	var errors []error

	for _, hostname := range targetNodes {
		if err := s.SendRemoval(hostname, componentName); err != nil {
			errors = append(errors, fmt.Errorf("%s: %w", hostname, err))
		}
	}

	return errors
}
