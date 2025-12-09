package reconciler

import (
	"context"
	"fmt"
	"time"

	"github.com/metorial/fleet/cosmos/internal/agent/component"
	"github.com/metorial/fleet/cosmos/internal/agent/database"
	agentgrpc "github.com/metorial/fleet/cosmos/internal/agent/grpc"
	"github.com/metorial/fleet/cosmos/internal/agent/health"
	pb "github.com/metorial/fleet/cosmos/internal/proto"
	log "github.com/sirupsen/logrus"
)

type Reconciler struct {
	db                *database.AgentDB
	componentMgr      *component.Manager
	healthChecker     *health.Checker
	grpcClient        *agentgrpc.Client
	interval          time.Duration
	heartbeatInterval time.Duration

	ctx    context.Context
	cancel context.CancelFunc
}

type ReconcilerConfig struct {
	DB                *database.AgentDB
	ComponentManager  *component.Manager
	HealthChecker     *health.Checker
	GRPCClient        *agentgrpc.Client
	ReconcileInterval time.Duration
	HeartbeatInterval time.Duration
}

func NewReconciler(config *ReconcilerConfig) *Reconciler {
	ctx, cancel := context.WithCancel(context.Background())

	interval := config.ReconcileInterval
	if interval == 0 {
		interval = 30 * time.Second
	}

	heartbeatInterval := config.HeartbeatInterval
	if heartbeatInterval == 0 {
		heartbeatInterval = 30 * time.Second
	}

	r := &Reconciler{
		db:                config.DB,
		componentMgr:      config.ComponentManager,
		healthChecker:     config.HealthChecker,
		grpcClient:        config.GRPCClient,
		interval:          interval,
		heartbeatInterval: heartbeatInterval,
		ctx:               ctx,
		cancel:            cancel,
	}

	// Set the reconciler as the progress reporter for the component manager
	config.ComponentManager.SetProgressReporter(r)

	return r
}

// ReportProgress implements the ProgressReporter interface
func (r *Reconciler) ReportProgress(componentName, status, message string) {
	r.grpcClient.SendDeploymentResult(
		componentName,
		"deploy",
		status,
		message,
	)
}

func (r *Reconciler) Start() error {
	log.WithFields(log.Fields{
		"reconcile_interval": r.interval,
		"heartbeat_interval": r.heartbeatInterval,
	}).Info("Starting reconciler")

	go r.reconcileLoop()
	go r.heartbeatLoop()
	go r.processControllerMessages()

	return nil
}

func (r *Reconciler) Stop() error {
	log.Info("Stopping reconciler")
	r.cancel()
	return nil
}

func (r *Reconciler) reconcileLoop() {
	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()

	r.reconcile()

	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			r.reconcile()
		}
	}
}

func (r *Reconciler) heartbeatLoop() {
	ticker := time.NewTicker(r.heartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			if err := r.grpcClient.SendHeartbeat(); err != nil {
				log.WithError(err).Debug("Failed to send heartbeat")
			}
		}
	}
}

func (r *Reconciler) reconcile() {
	log.Debug("Running reconciliation")

	r.checkComponentHealth()

	r.restartFailedComponents()

	r.runHealthChecks()
}

func (r *Reconciler) checkComponentHealth() {
	components, err := r.db.GetAllComponents()
	if err != nil {
		log.WithError(err).Warn("Failed to get components for health check")
		return
	}

	for _, comp := range components {
		if !comp.Managed {
			continue
		}

		status, err := r.db.GetComponentStatus(comp.Name)
		if err != nil {
			log.WithError(err).WithField("component", comp.Name).Warn("Failed to get component status")
			continue
		}

		if status.Status == "running" && status.PID > 0 {
			if !r.componentMgr.IsProcessRunning(status.PID) {
				log.WithFields(log.Fields{
					"component": comp.Name,
					"pid":       status.PID,
				}).Warn("Process no longer running, updating status")

				status.Status = "stopped"
				status.Message = "Process died unexpectedly"
				r.db.UpsertComponentStatus(status)

				r.grpcClient.SendComponentStatus(comp.Name)
			}
		}
	}
}

func (r *Reconciler) restartFailedComponents() {
	components, err := r.db.GetAllComponents()
	if err != nil {
		log.WithError(err).Warn("Failed to get components for restart check")
		return
	}

	for _, comp := range components {
		if !comp.Managed {
			continue
		}

		status, err := r.db.GetComponentStatus(comp.Name)
		if err != nil {
			log.WithError(err).WithField("component", comp.Name).Warn("Failed to get component status")
			continue
		}

		if status.Status == "stopped" || status.Status == "failed" {
			log.WithField("component", comp.Name).Info("Restarting failed component")

			if err := r.componentMgr.RestartComponent(comp.Name); err != nil {
				log.WithError(err).WithField("component", comp.Name).Error("Failed to restart component")

				r.grpcClient.SendDeploymentResult(
					comp.Name,
					"restart",
					"failure",
					fmt.Sprintf("Failed to restart: %v", err),
				)
			} else {
				log.WithField("component", comp.Name).Info("Component restarted successfully")

				r.grpcClient.SendDeploymentResult(
					comp.Name,
					"restart",
					"success",
					"Component restarted successfully",
				)
			}
		}
	}
}

func (r *Reconciler) runHealthChecks() {
	if r.healthChecker == nil {
		return
	}

	if err := r.healthChecker.CheckAllComponents(r.ctx); err != nil {
		log.WithError(err).Debug("Health check error")
	}

	failed, err := r.healthChecker.GetFailedComponents()
	if err != nil {
		log.WithError(err).Warn("Failed to get failed components")
		return
	}

	for _, check := range failed {
		log.WithFields(log.Fields{
			"component":            check.ComponentName,
			"consecutive_failures": check.ConsecutiveFailures,
		}).Warn("Component failing health checks")

		r.grpcClient.SendHealthCheckResult(
			check.ComponentName,
			check.Type,
			"failure",
			fmt.Sprintf("Failed %d consecutive health checks", check.ConsecutiveFailures),
		)
	}
}

func (r *Reconciler) processControllerMessages() {
	msgChan := r.grpcClient.ReceiveMessages()

	log.Info("Started processing controller messages from channel")

	for {
		select {
		case <-r.ctx.Done():
			log.Info("Context done, stopping message processor")
			return
		case msg, ok := <-msgChan:
			if !ok {
				log.Warn("Message channel closed, stopping processor")
				return
			}

			log.WithField("message_type", fmt.Sprintf("%T", msg.Message)).Info("Received message from controller")
			r.handleControllerMessage(msg)
		}
	}
}

func (r *Reconciler) handleControllerMessage(msg *pb.ControllerMessage) {
	switch m := msg.Message.(type) {
	case *pb.ControllerMessage_Deployment:
		r.handleDeployment(m.Deployment)
	case *pb.ControllerMessage_Removal:
		r.handleRemoval(m.Removal)
	case *pb.ControllerMessage_HealthConfig:
		r.handleHealthConfig(m.HealthConfig)
	case *pb.ControllerMessage_Ack:
		log.WithField("message", m.Ack.Message).Debug("Received acknowledgment")
	default:
		log.Warn("Received unknown message type from controller")
	}
}

func (r *Reconciler) handleDeployment(deployment *pb.ComponentDeployment) {
	log.WithFields(log.Fields{
		"component": deployment.ComponentName,
		"type":      deployment.ComponentType,
		"hash":      deployment.Hash,
	}).Info("Received deployment request")

	// Send "received" status
	r.grpcClient.SendDeploymentResult(
		deployment.ComponentName,
		"deploy",
		"received",
		"Deployment request received by agent",
	)

	comp := &database.Component{
		Name:               deployment.ComponentName,
		Type:               deployment.ComponentType,
		Hash:               deployment.Hash,
		ContentURL:         deployment.ContentUrl,
		ContentURLEncoding: deployment.ContentUrlEncoding,
		Content:            deployment.Content,
		Managed:            deployment.Managed,
	}

	if len(deployment.Env) > 0 {
		r.db.SetEnvMap(comp, deployment.Env)
	}

	if len(deployment.Args) > 0 {
		r.db.SetArgsSlice(comp, deployment.Args)
	}

	var err error
	var operation string

	// Send "started" status
	r.grpcClient.SendDeploymentResult(
		deployment.ComponentName,
		"deploy",
		"started",
		"Starting deployment execution",
	)

	switch deployment.ComponentType {
	case "program":
		operation = "deploy-program"
		err = r.componentMgr.DeployProgram(comp)
	case "script":
		operation = "deploy-script"
		err = r.componentMgr.DeployScript(comp)
	default:
		operation = "deploy"
		err = fmt.Errorf("unsupported component type: %s", deployment.ComponentType)
	}

	if err != nil {
		log.WithError(err).WithField("component", deployment.ComponentName).Error("Deployment failed")

		r.grpcClient.SendDeploymentResult(
			deployment.ComponentName,
			operation,
			"failure",
			fmt.Sprintf("Deployment failed: %v", err),
		)

		r.db.LogDeployment(&database.DeploymentLog{
			ComponentName: deployment.ComponentName,
			Operation:     operation,
			Status:        "failure",
			Message:       err.Error(),
		})
	} else {
		log.WithField("component", deployment.ComponentName).Info("Deployment successful")

		r.grpcClient.SendDeploymentResult(
			deployment.ComponentName,
			operation,
			"success",
			"Deployment completed successfully",
		)

		// Send immediate component status update to report PID
		r.grpcClient.SendComponentStatus(deployment.ComponentName)

		r.db.LogDeployment(&database.DeploymentLog{
			ComponentName: deployment.ComponentName,
			Operation:     operation,
			Status:        "success",
			Message:       "Deployment completed successfully",
		})

		if deployment.HealthCheck != nil {
			r.handleHealthConfig(deployment.HealthCheck)
		}
	}
}

func (r *Reconciler) handleRemoval(removal *pb.ComponentRemoval) {
	log.WithField("component", removal.ComponentName).Info("Received removal request")

	if err := r.componentMgr.RemoveComponent(removal.ComponentName); err != nil {
		log.WithError(err).WithField("component", removal.ComponentName).Error("Removal failed")

		r.grpcClient.SendDeploymentResult(
			removal.ComponentName,
			"remove",
			"failure",
			fmt.Sprintf("Removal failed: %v", err),
		)

		r.db.LogDeployment(&database.DeploymentLog{
			ComponentName: removal.ComponentName,
			Operation:     "remove",
			Status:        "failure",
			Message:       err.Error(),
		})
	} else {
		log.WithField("component", removal.ComponentName).Info("Removal successful")

		r.grpcClient.SendDeploymentResult(
			removal.ComponentName,
			"remove",
			"success",
			"Component removed successfully",
		)

		r.db.LogDeployment(&database.DeploymentLog{
			ComponentName: removal.ComponentName,
			Operation:     "remove",
			Status:        "success",
			Message:       "Component removed successfully",
		})
	}
}

func (r *Reconciler) handleHealthConfig(config *pb.HealthCheckConfig) {
	if config == nil {
		return
	}

	log.WithFields(log.Fields{
		"component": config.ComponentName,
		"type":      config.Type,
		"endpoint":  config.Endpoint,
	}).Debug("Updating health check configuration")

	check := &database.HealthCheck{
		ComponentName:   config.ComponentName,
		Type:            config.Type,
		Endpoint:        config.Endpoint,
		IntervalSeconds: int(config.IntervalSeconds),
		TimeoutSeconds:  int(config.TimeoutSeconds),
		Retries:         int(config.Retries),
	}

	if err := r.db.UpsertHealthCheck(check); err != nil {
		log.WithError(err).Warn("Failed to update health check configuration")
	}
}
