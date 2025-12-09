package grpc

import (
	"context"
	"crypto/tls"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/metorial/fleet/cosmos/internal/agent"
	"github.com/metorial/fleet/cosmos/internal/agent/database"
	pb "github.com/metorial/fleet/cosmos/internal/proto"
	log "github.com/sirupsen/logrus"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

type Client struct {
	controllerURL string
	hostname      string
	tlsConfig     *tls.Config
	db            *database.AgentDB

	conn   *grpc.ClientConn
	stream pb.CosmosController_StreamAgentMessagesClient

	mu                sync.RWMutex
	connected         bool
	reconnectInterval time.Duration

	outgoingCh chan *pb.AgentMessage
	incomingCh chan *pb.ControllerMessage

	ctx    context.Context
	cancel context.CancelFunc
}

type ClientConfig struct {
	ControllerURL     string
	Hostname          string
	TLSConfig         *tls.Config
	DB                *database.AgentDB
	ReconnectInterval time.Duration
}

func NewClient(config *ClientConfig) (*Client, error) {
	hostname := config.Hostname
	if hostname == "" {
		var err error
		hostname, err = os.Hostname()
		if err != nil {
			return nil, fmt.Errorf("failed to get hostname: %w", err)
		}
	}

	reconnectInterval := config.ReconnectInterval
	if reconnectInterval == 0 {
		reconnectInterval = 5 * time.Second
	}

	ctx, cancel := context.WithCancel(context.Background())

	return &Client{
		controllerURL:     config.ControllerURL,
		hostname:          hostname,
		tlsConfig:         config.TLSConfig,
		db:                config.DB,
		reconnectInterval: reconnectInterval,
		outgoingCh:        make(chan *pb.AgentMessage, 100),
		incomingCh:        make(chan *pb.ControllerMessage, 100),
		ctx:               ctx,
		cancel:            cancel,
	}, nil
}

func (c *Client) Start() error {
	log.WithField("controller", c.controllerURL).Info("Starting gRPC client")

	go c.connectionManager()
	go c.sendLoop()

	return nil
}

func (c *Client) Stop() error {
	log.Info("Stopping gRPC client")

	c.cancel()

	c.mu.Lock()
	if c.stream != nil {
		c.stream.CloseSend()
	}
	if c.conn != nil {
		c.conn.Close()
	}
	c.mu.Unlock()

	close(c.outgoingCh)
	close(c.incomingCh)

	return nil
}

func (c *Client) connectionManager() {
	for {
		select {
		case <-c.ctx.Done():
			return
		default:
		}

		if err := c.connect(); err != nil {
			log.WithError(err).Warn("Failed to connect to controller")
			c.setConnected(false)

			select {
			case <-c.ctx.Done():
				return
			case <-time.After(c.reconnectInterval):
				continue
			}
		}

		c.setConnected(true)
		log.Info("Connected to controller")

		if err := c.receiveLoop(); err != nil {
			log.WithError(err).Warn("Connection lost to controller")
		}

		c.setConnected(false)
		c.closeConnection()

		select {
		case <-c.ctx.Done():
			return
		case <-time.After(c.reconnectInterval):
		}
	}
}

func (c *Client) connect() error {
	var opts []grpc.DialOption

	if c.tlsConfig != nil {
		creds := credentials.NewTLS(c.tlsConfig)
		opts = append(opts, grpc.WithTransportCredentials(creds))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	conn, err := grpc.NewClient(c.controllerURL, opts...)
	if err != nil {
		return fmt.Errorf("failed to create client: %w", err)
	}

	client := pb.NewCosmosControllerClient(conn)

	stream, err := client.StreamAgentMessages(c.ctx)
	if err != nil {
		conn.Close()
		return fmt.Errorf("failed to create stream: %w", err)
	}

	c.mu.Lock()
	c.conn = conn
	c.stream = stream
	c.mu.Unlock()

	return nil
}

func (c *Client) closeConnection() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.stream != nil {
		c.stream.CloseSend()
		c.stream = nil
	}

	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
}

func (c *Client) sendLoop() {
	for {
		select {
		case <-c.ctx.Done():
			return
		case msg, ok := <-c.outgoingCh:
			if !ok {
				return
			}

			if !c.IsConnected() {
				log.Debug("Not connected, dropping message")
				continue
			}

			c.mu.RLock()
			stream := c.stream
			c.mu.RUnlock()

			if stream == nil {
				continue
			}

			if err := stream.Send(msg); err != nil {
				log.WithError(err).Warn("Failed to send message")
				c.setConnected(false)
			}
		}
	}
}

func (c *Client) receiveLoop() error {
	for {
		c.mu.RLock()
		stream := c.stream
		c.mu.RUnlock()

		if stream == nil {
			return fmt.Errorf("stream is nil")
		}

		msg, err := stream.Recv()
		if err != nil {
			if c.ctx.Err() != nil {
				return nil
			}

			if st, ok := status.FromError(err); ok {
				if st.Code() == codes.Canceled || st.Code() == codes.Unavailable {
					return fmt.Errorf("stream closed: %w", err)
				}
			}

			return fmt.Errorf("receive error: %w", err)
		}

		select {
		case c.incomingCh <- msg:
		case <-c.ctx.Done():
			return nil
		case <-time.After(5 * time.Second):
			log.Warn("Incoming message channel full, dropping message")
		}
	}
}

func (c *Client) SendHeartbeat() error {
	components, err := c.db.GetAllComponents()
	if err != nil {
		return fmt.Errorf("failed to get components: %w", err)
	}

	var componentStatuses []*pb.ComponentStatus
	for _, comp := range components {
		status, err := c.db.GetComponentStatus(comp.Name)
		if err != nil {
			log.WithError(err).WithField("component", comp.Name).Warn("Failed to get component status")
			continue
		}

		pbStatus := &pb.ComponentStatus{
			Name:         comp.Name,
			Status:       status.Status,
			Message:      status.Message,
			Pid:          int32(status.PID),
			RestartCount: int32(status.RestartCount),
		}

		if status.LastStartedAt != nil {
			pbStatus.LastStartedAt = status.LastStartedAt.Unix()
		}

		componentStatuses = append(componentStatuses, pbStatus)
	}

	msg := &pb.AgentMessage{
		Hostname:  c.hostname,
		Timestamp: time.Now().Unix(),
		Message: &pb.AgentMessage_Heartbeat{
			Heartbeat: &pb.AgentHeartbeat{
				AgentVersion:      agent.Version,
				ComponentStatuses: componentStatuses,
			},
		},
	}

	select {
	case c.outgoingCh <- msg:
		return nil
	case <-time.After(time.Second):
		return fmt.Errorf("timeout sending heartbeat")
	}
}

func (c *Client) SendComponentStatus(componentName string) error {
	component, err := c.db.GetComponent(componentName)
	if err != nil {
		return fmt.Errorf("failed to get component: %w", err)
	}

	status, err := c.db.GetComponentStatus(componentName)
	if err != nil {
		return fmt.Errorf("failed to get status: %w", err)
	}

	pbStatus := &pb.ComponentStatus{
		Name:         component.Name,
		Status:       status.Status,
		Message:      status.Message,
		Pid:          int32(status.PID),
		RestartCount: int32(status.RestartCount),
	}

	if status.LastStartedAt != nil {
		pbStatus.LastStartedAt = status.LastStartedAt.Unix()
	}

	msg := &pb.AgentMessage{
		Hostname:  c.hostname,
		Timestamp: time.Now().Unix(),
		Message: &pb.AgentMessage_ComponentStatus{
			ComponentStatus: pbStatus,
		},
	}

	select {
	case c.outgoingCh <- msg:
		return nil
	case <-time.After(time.Second):
		return fmt.Errorf("timeout sending component status")
	}
}

func (c *Client) SendHealthCheckResult(componentName, checkType, result, message string) error {
	msg := &pb.AgentMessage{
		Hostname:  c.hostname,
		Timestamp: time.Now().Unix(),
		Message: &pb.AgentMessage_HealthResult{
			HealthResult: &pb.HealthCheckResult{
				ComponentName: componentName,
				CheckType:     checkType,
				Result:        result,
				Message:       message,
				Timestamp:     time.Now().Unix(),
			},
		},
	}

	select {
	case c.outgoingCh <- msg:
		return nil
	case <-time.After(time.Second):
		return fmt.Errorf("timeout sending health check result")
	}
}

func (c *Client) SendDeploymentResult(componentName, operation, result, message string) error {
	msg := &pb.AgentMessage{
		Hostname:  c.hostname,
		Timestamp: time.Now().Unix(),
		Message: &pb.AgentMessage_DeploymentResult{
			DeploymentResult: &pb.DeploymentResult{
				ComponentName: componentName,
				Operation:     operation,
				Result:        result,
				Message:       message,
				Timestamp:     time.Now().Unix(),
			},
		},
	}

	select {
	case c.outgoingCh <- msg:
		return nil
	case <-time.After(time.Second):
		return fmt.Errorf("timeout sending deployment result")
	}
}

func (c *Client) SendLogChunk(componentName, logData string, offset int64) error {
	msg := &pb.AgentMessage{
		Hostname:  c.hostname,
		Timestamp: time.Now().Unix(),
		Message: &pb.AgentMessage_LogChunk{
			LogChunk: &pb.LogChunk{
				ComponentName: componentName,
				LogData:       logData,
				Timestamp:     time.Now().Unix(),
				Offset:        offset,
			},
		},
	}

	select {
	case c.outgoingCh <- msg:
		return nil
	case <-time.After(time.Second):
		return fmt.Errorf("timeout sending log chunk")
	}
}

func (c *Client) ReceiveMessages() <-chan *pb.ControllerMessage {
	return c.incomingCh
}

func (c *Client) IsConnected() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.connected
}

func (c *Client) setConnected(connected bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.connected = connected
}
