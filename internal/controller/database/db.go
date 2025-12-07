package database

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type ControllerDB struct {
	db *gorm.DB
}

type Deployment struct {
	ID            uuid.UUID       `gorm:"type:uuid;primary_key;default:gen_random_uuid()" json:"id"`
	Configuration json.RawMessage `gorm:"type:jsonb;not null" json:"configuration"`
	Status        string          `gorm:"type:varchar(20);not null" json:"status"`
	CreatedAt     time.Time       `gorm:"not null;default:now()" json:"created_at"`
	StartedAt     *time.Time      `json:"started_at,omitempty"`
	CompletedAt   *time.Time      `json:"completed_at,omitempty"`
	CreatedBy     string          `gorm:"type:varchar(255)" json:"created_by,omitempty"`
	ErrorMessage  string          `gorm:"type:text" json:"error_message,omitempty"`
}

type Component struct {
	Name               string          `gorm:"primary_key;type:varchar(255)" json:"name"`
	Type               string          `gorm:"type:varchar(20);not null" json:"type"`
	Handler            string          `gorm:"type:varchar(20);not null" json:"handler"`
	Hash               string          `gorm:"type:varchar(64);not null;index" json:"hash"`
	Tags               pq.StringArray  `gorm:"type:text[];not null" json:"tags"`
	Content            string          `gorm:"type:text" json:"content,omitempty"`
	ContentURL         string          `gorm:"type:text" json:"content_url,omitempty"`
	ContentURLEncoding string          `gorm:"type:varchar(20)" json:"content_url_encoding,omitempty"`
	NomadJob           string          `gorm:"type:text" json:"nomad_job,omitempty"`
	HealthCheck        json.RawMessage `gorm:"type:jsonb" json:"health_check,omitempty"`
	Env                json.RawMessage `gorm:"type:jsonb" json:"env,omitempty"`
	Args               pq.StringArray  `gorm:"type:text[]" json:"args,omitempty"`
	Managed            bool            `gorm:"default:false" json:"managed"`
	ExternalID         string          `gorm:"type:varchar(255)" json:"external_id,omitempty"`
	DeploymentID       *uuid.UUID      `gorm:"type:uuid" json:"deployment_id,omitempty"`
	CreatedAt          time.Time       `gorm:"not null;default:now()" json:"created_at"`
	UpdatedAt          time.Time       `gorm:"not null;default:now()" json:"updated_at"`
}

type ComponentDeployment struct {
	ID              uuid.UUID  `gorm:"type:uuid;primary_key;default:gen_random_uuid()" json:"id"`
	ComponentName   string     `gorm:"type:varchar(255);not null;index" json:"component_name"`
	NodeHostname    string     `gorm:"type:varchar(255);not null;index" json:"node_hostname"`
	DeploymentID    *uuid.UUID `gorm:"type:uuid" json:"deployment_id,omitempty"`
	Status          string     `gorm:"type:varchar(20);not null;index" json:"status"`
	Message         string     `gorm:"type:text" json:"message,omitempty"`
	PID             *int       `json:"pid,omitempty"`
	LastStartedAt   *time.Time `json:"last_started_at,omitempty"`
	LastHealthCheck *time.Time `json:"last_health_check,omitempty"`
	HealthStatus    string     `gorm:"type:varchar(20)" json:"health_status,omitempty"`
	DeployedAt      *time.Time `json:"deployed_at,omitempty"`
	LastUpdated     *time.Time `json:"last_updated,omitempty"`
	CreatedAt       time.Time  `gorm:"not null;default:now()" json:"created_at"`
}

type Agent struct {
	Hostname       string          `gorm:"primary_key;type:varchar(255)" json:"hostname"`
	AgentVersion   string          `gorm:"type:varchar(50)" json:"agent_version"`
	LastHeartbeat  time.Time       `gorm:"not null;index" json:"last_heartbeat"`
	Online         bool            `gorm:"not null;default:true;index" json:"online"`
	ComponentCount int             `gorm:"default:0" json:"component_count"`
	Metadata       json.RawMessage `gorm:"type:jsonb" json:"metadata,omitempty"`
	CreatedAt      time.Time       `gorm:"not null;default:now()" json:"created_at"`
	UpdatedAt      time.Time       `gorm:"not null;default:now()" json:"updated_at"`
}

type DeploymentLog struct {
	ID            uuid.UUID       `gorm:"type:uuid;primary_key;default:gen_random_uuid()" json:"id"`
	DeploymentID  uuid.UUID       `gorm:"type:uuid;not null;index" json:"deployment_id"`
	ComponentName string          `gorm:"type:varchar(255);index" json:"component_name,omitempty"`
	NodeHostname  string          `gorm:"type:varchar(255)" json:"node_hostname,omitempty"`
	Operation     string          `gorm:"type:varchar(20);not null" json:"operation"`
	Status        string          `gorm:"type:varchar(20);not null" json:"status"`
	Message       string          `gorm:"type:text" json:"message,omitempty"`
	Details       json.RawMessage `gorm:"type:jsonb" json:"details,omitempty"`
	CreatedAt     time.Time       `gorm:"not null;default:now();index" json:"created_at"`
}

type Node struct {
	Hostname string          `gorm:"primary_key;type:varchar(255)" json:"hostname"`
	IP       string          `gorm:"type:varchar(45)" json:"ip,omitempty"`
	Tags     pq.StringArray  `gorm:"type:text[];not null;default:'{}'" json:"tags"`
	Online   bool            `gorm:"not null;default:false;index" json:"online"`
	HasAgent bool            `gorm:"not null;default:false;index" json:"has_agent"`
	LastSeen *time.Time      `json:"last_seen,omitempty"`
	Metadata json.RawMessage `gorm:"type:jsonb" json:"metadata,omitempty"`
	SyncedAt time.Time       `gorm:"not null;default:now()" json:"synced_at"`
}

func NewControllerDB(dsn string) (*ControllerDB, error) {
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Warn),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}

	if err := db.AutoMigrate(
		&Deployment{},
		&Component{},
		&ComponentDeployment{},
		&Agent{},
		&DeploymentLog{},
		&Node{},
	); err != nil {
		return nil, fmt.Errorf("failed to migrate database: %w", err)
	}

	return &ControllerDB{db: db}, nil
}

func (d *ControllerDB) Close() error {
	sqlDB, err := d.db.DB()
	if err != nil {
		return err
	}
	return sqlDB.Close()
}

func (d *ControllerDB) CreateDeployment(deployment *Deployment) error {
	return d.db.Create(deployment).Error
}

func (d *ControllerDB) GetDeployment(id uuid.UUID) (*Deployment, error) {
	var deployment Deployment
	if err := d.db.First(&deployment, "id = ?", id).Error; err != nil {
		return nil, err
	}
	return &deployment, nil
}

func (d *ControllerDB) ListDeployments(limit, offset int) ([]Deployment, error) {
	var deployments []Deployment
	err := d.db.Order("created_at DESC").Limit(limit).Offset(offset).Find(&deployments).Error
	return deployments, err
}

func (d *ControllerDB) UpdateDeploymentStatus(id uuid.UUID, status, errorMessage string) error {
	updates := map[string]interface{}{
		"status": status,
	}

	if status == "running" {
		now := time.Now()
		updates["started_at"] = now
	} else if status == "completed" || status == "failed" {
		now := time.Now()
		updates["completed_at"] = now
	}

	if errorMessage != "" {
		updates["error_message"] = errorMessage
	}

	return d.db.Model(&Deployment{}).Where("id = ?", id).Updates(updates).Error
}

func (d *ControllerDB) UpsertComponent(component *Component) error {
	return d.db.Save(component).Error
}

func (d *ControllerDB) GetComponent(name string) (*Component, error) {
	var component Component
	if err := d.db.First(&component, "name = ?", name).Error; err != nil {
		return nil, err
	}
	return &component, nil
}

func (d *ControllerDB) ListComponents() ([]Component, error) {
	var components []Component
	err := d.db.Find(&components).Error
	return components, err
}

func (d *ControllerDB) DeleteComponent(name string) error {
	return d.db.Delete(&Component{}, "name = ?", name).Error
}

func (d *ControllerDB) UpsertComponentDeployment(deployment *ComponentDeployment) error {
	var existing ComponentDeployment
	err := d.db.Where("component_name = ? AND node_hostname = ?",
		deployment.ComponentName, deployment.NodeHostname).First(&existing).Error

	if err == gorm.ErrRecordNotFound {
		return d.db.Create(deployment).Error
	}

	deployment.ID = existing.ID
	deployment.CreatedAt = existing.CreatedAt
	return d.db.Save(deployment).Error
}

func (d *ControllerDB) GetComponentDeployments(componentName string) ([]ComponentDeployment, error) {
	var deployments []ComponentDeployment
	err := d.db.Where("component_name = ?", componentName).Find(&deployments).Error
	return deployments, err
}

func (d *ControllerDB) GetNodeDeployments(nodeHostname string) ([]ComponentDeployment, error) {
	var deployments []ComponentDeployment
	err := d.db.Where("node_hostname = ?", nodeHostname).Find(&deployments).Error
	return deployments, err
}

func (d *ControllerDB) ListComponentDeployments(status string) ([]ComponentDeployment, error) {
	query := d.db
	if status != "" {
		query = query.Where("status = ?", status)
	}
	var deployments []ComponentDeployment
	err := query.Find(&deployments).Error
	return deployments, err
}

func (d *ControllerDB) DeleteComponentDeployments(componentName, nodeHostname string) error {
	return d.db.Where("component_name = ? AND node_hostname = ?",
		componentName, nodeHostname).Delete(&ComponentDeployment{}).Error
}

func (d *ControllerDB) UpsertAgent(agent *Agent) error {
	var existing Agent
	err := d.db.First(&existing, "hostname = ?", agent.Hostname).Error

	if err == gorm.ErrRecordNotFound {
		return d.db.Create(agent).Error
	}

	agent.CreatedAt = existing.CreatedAt
	return d.db.Save(agent).Error
}

func (d *ControllerDB) GetAgent(hostname string) (*Agent, error) {
	var agent Agent
	if err := d.db.First(&agent, "hostname = ?", hostname).Error; err != nil {
		return nil, err
	}
	return &agent, nil
}

func (d *ControllerDB) ListAgents(onlineOnly bool) ([]Agent, error) {
	query := d.db
	if onlineOnly {
		query = query.Where("online = ?", true)
	}
	var agents []Agent
	err := query.Order("hostname").Find(&agents).Error
	return agents, err
}

func (d *ControllerDB) MarkAgentsOffline(beforeTime time.Time) error {
	return d.db.Model(&Agent{}).
		Where("last_heartbeat < ? AND online = ?", beforeTime, true).
		Update("online", false).Error
}

func (d *ControllerDB) LogDeployment(log *DeploymentLog) error {
	return d.db.Create(log).Error
}

func (d *ControllerDB) GetDeploymentLogs(deploymentID uuid.UUID, limit int) ([]DeploymentLog, error) {
	var logs []DeploymentLog
	err := d.db.Where("deployment_id = ?", deploymentID).
		Order("created_at DESC").
		Limit(limit).
		Find(&logs).Error
	return logs, err
}

func (d *ControllerDB) UpsertNode(node *Node) error {
	var existing Node
	err := d.db.First(&existing, "hostname = ?", node.Hostname).Error

	if err == gorm.ErrRecordNotFound {
		return d.db.Create(node).Error
	}

	return d.db.Save(node).Error
}

func (d *ControllerDB) GetNode(hostname string) (*Node, error) {
	var node Node
	if err := d.db.First(&node, "hostname = ?", hostname).Error; err != nil {
		return nil, err
	}
	return &node, nil
}

func (d *ControllerDB) ListNodes(onlineOnly bool) ([]Node, error) {
	query := d.db
	if onlineOnly {
		query = query.Where("online = ?", true)
	}
	var nodes []Node
	err := query.Order("hostname").Find(&nodes).Error
	return nodes, err
}

func (d *ControllerDB) GetNodesByTags(tags []string) ([]Node, error) {
	var nodes []Node
	err := d.db.Where("tags && ?", pq.Array(tags)).Find(&nodes).Error
	return nodes, err
}

func (d *ControllerDB) CleanupOldDeployments(olderThan time.Time) error {
	return d.db.Where("created_at < ? AND status IN (?)", olderThan,
		[]string{"completed", "failed"}).Delete(&Deployment{}).Error
}
