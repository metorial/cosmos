package reconciler

import (
	"encoding/json"
	"fmt"

	"github.com/google/uuid"
	"github.com/metorial/fleet/cosmos/internal/controller/database"
	grpcserver "github.com/metorial/fleet/cosmos/internal/controller/grpc"
	"github.com/metorial/fleet/cosmos/internal/controller/managers"
	"github.com/metorial/fleet/cosmos/internal/controller/types"
	pb "github.com/metorial/fleet/cosmos/internal/proto"
	log "github.com/sirupsen/logrus"
)

type Reconciler struct {
	db         *database.ControllerDB
	grpcServer *grpcserver.Server
	scriptMgr  *managers.ScriptManager
	programMgr *managers.ProgramManager
	serviceMgr *managers.ServiceManager
}

type ReconcilerConfig struct {
	DB         *database.ControllerDB
	GRPCServer *grpcserver.Server
	ScriptMgr  *managers.ScriptManager
	ProgramMgr *managers.ProgramManager
	ServiceMgr *managers.ServiceManager
}

func NewReconciler(config *ReconcilerConfig) *Reconciler {
	return &Reconciler{
		db:         config.DB,
		grpcServer: config.GRPCServer,
		scriptMgr:  config.ScriptMgr,
		programMgr: config.ProgramMgr,
		serviceMgr: config.ServiceMgr,
	}
}

func (r *Reconciler) ProcessDeployment(deploymentID uuid.UUID, config types.ConfigurationRequest) error {
	log.WithField("deployment_id", deploymentID).Info("Processing deployment")

	r.db.UpdateDeploymentStatus(deploymentID, "running", "")

	currentComponents, err := r.db.ListComponents()
	if err != nil {
		return fmt.Errorf("failed to list current components: %w", err)
	}

	currentMap := make(map[string]*database.Component)
	for i := range currentComponents {
		currentMap[currentComponents[i].Name] = &currentComponents[i]
	}

	newMap := make(map[string]*types.ComponentConfig)
	for i := range config.Components {
		newMap[config.Components[i].Name] = &config.Components[i]
	}

	var toAdd []types.ComponentConfig
	var toUpdate []types.ComponentConfig
	var toRemove []database.Component

	for name, newComp := range newMap {
		if curr, exists := currentMap[name]; exists {
			if curr.Hash != newComp.Hash {
				toUpdate = append(toUpdate, *newComp)
			}
		} else {
			toAdd = append(toAdd, *newComp)
		}
	}

	for name, curr := range currentMap {
		if _, exists := newMap[name]; !exists {
			toRemove = append(toRemove, *curr)
		}
	}

	log.WithFields(log.Fields{
		"deployment_id": deploymentID,
		"to_add":        len(toAdd),
		"to_update":     len(toUpdate),
		"to_remove":     len(toRemove),
	}).Info("Deployment plan calculated")

	for _, comp := range toRemove {
		if err := r.removeComponent(deploymentID, &comp); err != nil {
			log.WithError(err).WithField("component", comp.Name).Error("Failed to remove component")
			r.logDeployment(deploymentID, comp.Name, "", "remove", "failure", err.Error())
		}
	}

	for _, comp := range toUpdate {
		if err := r.deployComponent(deploymentID, &comp, false); err != nil {
			log.WithError(err).WithField("component", comp.Name).Error("Failed to update component")
		}
	}

	for _, comp := range toAdd {
		if err := r.deployComponent(deploymentID, &comp, true); err != nil {
			log.WithError(err).WithField("component", comp.Name).Error("Failed to add component")
		}
	}

	log.WithField("deployment_id", deploymentID).Info("Deployment processing completed")

	return nil
}

func (r *Reconciler) deployComponent(deploymentID uuid.UUID, config *types.ComponentConfig, isNew bool) error {
	handler := config.Handler
	if handler == "" {
		handler = r.determineHandler(config)
	}

	component := &database.Component{
		Name:               config.Name,
		Type:               config.Type,
		Handler:            handler,
		Hash:               config.Hash,
		Tags:               config.Tags,
		Content:            config.Content,
		ContentURL:         config.ContentURL,
		ContentURLEncoding: config.ContentURLEncoding,
		NomadJob:           config.NomadJob,
		Managed:            config.Managed,
		DeploymentID:       &deploymentID,
	}

	if config.HealthCheck != nil {
		hc, _ := json.Marshal(config.HealthCheck)
		component.HealthCheck = hc
	}

	if config.Env != nil {
		env, _ := json.Marshal(config.Env)
		component.Env = env
	}

	component.Args = config.Args

	if err := r.db.UpsertComponent(component); err != nil {
		return fmt.Errorf("failed to save component: %w", err)
	}

	nodes, err := r.resolveTargetNodes(config.Tags)
	if err != nil {
		return fmt.Errorf("failed to resolve target nodes: %w", err)
	}

	log.WithFields(log.Fields{
		"component":    config.Name,
		"type":         config.Type,
		"handler":      handler,
		"target_nodes": len(nodes),
	}).Info("Deploying component")

	switch handler {
	case "agent":
		return r.deployViaAgent(deploymentID, config, nodes)
	case "command-core":
		return r.deployViaCommandCore(deploymentID, config, nodes)
	case "nomad":
		return r.deployViaNomad(deploymentID, config)
	default:
		return fmt.Errorf("unknown handler: %s", handler)
	}
}

func (r *Reconciler) removeComponent(deploymentID uuid.UUID, component *database.Component) error {
	log.WithField("component", component.Name).Info("Removing component")

	switch component.Handler {
	case "agent":
		return r.removeViaAgent(deploymentID, component)
	case "nomad":
		return r.removeViaNomad(deploymentID, component)
	case "command-core":
		r.db.DeleteComponent(component.Name)
		return nil
	default:
		return fmt.Errorf("unknown handler: %s", component.Handler)
	}
}

func (r *Reconciler) deployViaAgent(deploymentID uuid.UUID, config *types.ComponentConfig, nodes []database.Node) error {
	log.WithFields(log.Fields{
		"deployment_id": deploymentID,
		"component":     config.Name,
		"nodes_count":   len(nodes),
	}).Info("Starting agent-based deployment")

	deployment := &pb.ComponentDeployment{
		ComponentName:      config.Name,
		ComponentType:      config.Type,
		Hash:               config.Hash,
		ContentUrl:         config.ContentURL,
		ContentUrlEncoding: config.ContentURLEncoding,
		Content:            config.Content,
		Managed:            config.Managed,
	}

	if config.Env != nil {
		deployment.Env = config.Env
	}

	if config.Args != nil {
		deployment.Args = config.Args
	}

	if config.HealthCheck != nil {
		deployment.HealthCheck = &pb.HealthCheckConfig{
			ComponentName:   config.Name,
			Type:            config.HealthCheck.Type,
			Endpoint:        config.HealthCheck.Endpoint,
			IntervalSeconds: config.HealthCheck.IntervalSeconds,
			TimeoutSeconds:  config.HealthCheck.TimeoutSeconds,
			Retries:         config.HealthCheck.Retries,
		}
	}

	targetNodes := make([]string, 0, len(nodes))
	for _, node := range nodes {
		if node.HasAgent {
			targetNodes = append(targetNodes, node.Hostname)
		}
	}

	log.WithFields(log.Fields{
		"target_nodes": targetNodes,
		"component":    config.Name,
	}).Info("Resolved target nodes for deployment")

	if len(targetNodes) == 0 {
		return fmt.Errorf("no agents available on target nodes")
	}

	log.WithFields(log.Fields{
		"component":    config.Name,
		"target_nodes": targetNodes,
		"node_count":   len(targetNodes),
	}).Info("Broadcasting deployment to agents")

	// Create "deploying" records BEFORE broadcasting to avoid race condition
	for _, node := range targetNodes {
		componentDep := &database.ComponentDeployment{
			ComponentName: config.Name,
			NodeHostname:  node,
			DeploymentID:  &deploymentID,
			Status:        "deploying",
			Message:       "Deployment command sent to agent",
		}
		r.db.UpsertComponentDeployment(componentDep)

		r.logDeployment(deploymentID, config.Name, node, "deploy", "initiated", "Sent to agent")
	}

	errors := r.grpcServer.BroadcastDeployment(deployment, targetNodes)

	if len(errors) > 0 {
		log.WithField("errors", len(errors)).Warn("Some deployments failed to send")
		for _, err := range errors {
			log.WithError(err).Warn("Deployment send error")
		}
	}

	return nil
}

func (r *Reconciler) deployViaCommandCore(deploymentID uuid.UUID, config *types.ComponentConfig, nodes []database.Node) error {
	if config.Type != "script" {
		return fmt.Errorf("command-core handler only supports scripts")
	}

	targetNodes := make([]string, 0, len(nodes))
	for _, node := range nodes {
		targetNodes = append(targetNodes, node.Hostname)
	}

	if len(targetNodes) == 0 {
		return fmt.Errorf("no target nodes found")
	}

	if err := r.scriptMgr.DeployViaCommandCore(config, targetNodes); err != nil {
		return err
	}

	for _, node := range targetNodes {
		r.logDeployment(deploymentID, config.Name, node, "deploy", "success", "Deployed via command-core")
	}

	return nil
}

func (r *Reconciler) deployViaNomad(deploymentID uuid.UUID, config *types.ComponentConfig) error {
	if config.Type != "service" {
		return fmt.Errorf("nomad handler only supports services")
	}

	if err := r.serviceMgr.Deploy(config); err != nil {
		r.logDeployment(deploymentID, config.Name, "", "deploy", "failure", err.Error())
		return err
	}

	r.logDeployment(deploymentID, config.Name, "", "deploy", "success", "Deployed to Nomad")

	return nil
}

func (r *Reconciler) removeViaAgent(deploymentID uuid.UUID, component *database.Component) error {
	deployments, err := r.db.GetComponentDeployments(component.Name)
	if err != nil {
		return err
	}

	targetNodes := make([]string, 0, len(deployments))
	for _, dep := range deployments {
		targetNodes = append(targetNodes, dep.NodeHostname)
	}

	if len(targetNodes) == 0 {
		r.db.DeleteComponent(component.Name)
		return nil
	}

	errors := r.grpcServer.BroadcastRemoval(component.Name, targetNodes)

	for _, node := range targetNodes {
		r.db.DeleteComponentDeployments(component.Name, node)
		r.logDeployment(deploymentID, component.Name, node, "remove", "initiated", "Sent to agent")
	}

	r.db.DeleteComponent(component.Name)

	if len(errors) > 0 {
		log.WithField("errors", len(errors)).Warn("Some removals failed to send")
		return fmt.Errorf("%d removals failed to send", len(errors))
	}

	return nil
}

func (r *Reconciler) removeViaNomad(deploymentID uuid.UUID, component *database.Component) error {
	if err := r.serviceMgr.Remove(component.Name); err != nil {
		r.logDeployment(deploymentID, component.Name, "", "remove", "failure", err.Error())
		return err
	}

	r.db.DeleteComponent(component.Name)
	r.logDeployment(deploymentID, component.Name, "", "remove", "success", "Removed from Nomad")

	return nil
}

func (r *Reconciler) resolveTargetNodes(tags []string) ([]database.Node, error) {
	if len(tags) == 0 {
		return r.db.ListNodes(true)
	}

	nodes, err := r.db.GetNodesByTags(tags)
	if err != nil {
		return nil, err
	}

	onlineNodes := make([]database.Node, 0, len(nodes))
	for _, node := range nodes {
		if node.Online {
			onlineNodes = append(onlineNodes, node)
		}
	}

	return onlineNodes, nil
}

func (r *Reconciler) determineHandler(config *types.ComponentConfig) string {
	switch config.Type {
	case "script":
		if config.Managed {
			return "agent"
		}
		return "command-core"
	case "program":
		return "agent"
	case "service":
		return "nomad"
	default:
		return "agent"
	}
}

func (r *Reconciler) logDeployment(deploymentID uuid.UUID, componentName, nodeHostname, operation, status, message string) {
	log := &database.DeploymentLog{
		DeploymentID:  deploymentID,
		ComponentName: componentName,
		NodeHostname:  nodeHostname,
		Operation:     operation,
		Status:        status,
		Message:       message,
	}

	r.db.LogDeployment(log)
}
