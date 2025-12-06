package models

import (
	"database/sql/driver"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

type JSONB map[string]interface{}

func (j JSONB) Value() (driver.Value, error) {
	return json.Marshal(j)
}

func (j *JSONB) Scan(value interface{}) error {
	bytes, ok := value.([]byte)
	if !ok {
		return nil
	}
	return json.Unmarshal(bytes, j)
}

type StringArray []string

func (s StringArray) Value() (driver.Value, error) {
	if len(s) == 0 {
		return "{}", nil
	}
	return json.Marshal(s)
}

func (s *StringArray) Scan(value interface{}) error {
	bytes, ok := value.([]byte)
	if !ok {
		return nil
	}
	return json.Unmarshal(bytes, s)
}

type Deployment struct {
	ID            uuid.UUID `gorm:"type:uuid;primary_key;default:gen_random_uuid()"`
	Configuration JSONB     `gorm:"type:jsonb;not null"`
	Status        string    `gorm:"type:varchar(20);not null;index"`
	CreatedAt     time.Time `gorm:"not null;default:now();index:idx_deployments_created_at"`
	StartedAt     *time.Time
	CompletedAt   *time.Time
	CreatedBy     *string `gorm:"type:varchar(255)"`
	ErrorMessage  *string `gorm:"type:text"`
}

type Component struct {
	Name               string      `gorm:"type:varchar(255);primary_key"`
	Type               string      `gorm:"type:varchar(20);not null;index:idx_components_type"`
	Handler            string      `gorm:"type:varchar(20);not null;index:idx_components_handler"`
	Hash               string      `gorm:"type:varchar(64);not null;index:idx_components_hash"`
	Tags               StringArray `gorm:"type:text[];not null"`
	Content            *string     `gorm:"type:text"`
	ContentURL         *string     `gorm:"type:text"`
	ContentURLEncoding *string     `gorm:"type:varchar(20)"`
	NomadJob           *string     `gorm:"type:text"`
	HealthCheck        JSONB       `gorm:"type:jsonb"`
	Env                JSONB       `gorm:"type:jsonb"`
	Args               StringArray `gorm:"type:text[]"`
	Managed            bool        `gorm:"default:false"`
	ExternalID         *string     `gorm:"type:varchar(255)"`
	DeploymentID       uuid.UUID   `gorm:"type:uuid"`
	CreatedAt          time.Time   `gorm:"not null;default:now()"`
	UpdatedAt          time.Time   `gorm:"not null;default:now()"`
}

type ComponentDeployment struct {
	ID              uuid.UUID `gorm:"type:uuid;primary_key;default:gen_random_uuid()"`
	ComponentName   string    `gorm:"type:varchar(255);not null;index:idx_comp_deployments_component;uniqueIndex:idx_comp_deployments_unique"`
	NodeHostname    string    `gorm:"type:varchar(255);not null;index:idx_comp_deployments_node;uniqueIndex:idx_comp_deployments_unique"`
	DeploymentID    uuid.UUID `gorm:"type:uuid"`
	Status          string    `gorm:"type:varchar(20);not null;index:idx_comp_deployments_status"`
	Message         *string   `gorm:"type:text"`
	PID             *int      `gorm:"type:integer"`
	LastStartedAt   *time.Time
	LastHealthCheck *time.Time
	HealthStatus    *string `gorm:"type:varchar(20)"`
	DeployedAt      *time.Time
	LastUpdated     *time.Time
	CreatedAt       time.Time `gorm:"not null;default:now()"`
}

func (ComponentDeployment) TableName() string {
	return "component_deployments"
}

type Agent struct {
	Hostname       string    `gorm:"type:varchar(255);primary_key"`
	AgentVersion   string    `gorm:"type:varchar(50)"`
	LastHeartbeat  time.Time `gorm:"not null;index:idx_agents_last_heartbeat"`
	Online         bool      `gorm:"not null;default:true;index:idx_agents_online"`
	ComponentCount int       `gorm:"default:0"`
	Metadata       JSONB     `gorm:"type:jsonb"`
	CreatedAt      time.Time `gorm:"not null;default:now()"`
	UpdatedAt      time.Time `gorm:"not null;default:now()"`
}

type DeploymentLog struct {
	ID            uuid.UUID `gorm:"type:uuid;primary_key;default:gen_random_uuid()"`
	DeploymentID  uuid.UUID `gorm:"type:uuid;not null;index:idx_deployment_logs_deployment"`
	ComponentName *string   `gorm:"type:varchar(255);index:idx_deployment_logs_component"`
	NodeHostname  *string   `gorm:"type:varchar(255)"`
	Operation     string    `gorm:"type:varchar(20);not null"`
	Status        string    `gorm:"type:varchar(20);not null"`
	Message       *string   `gorm:"type:text"`
	Details       JSONB     `gorm:"type:jsonb"`
	CreatedAt     time.Time `gorm:"not null;default:now();index:idx_deployment_logs_created_at"`
}

func (DeploymentLog) TableName() string {
	return "deployment_logs"
}

type Node struct {
	Hostname string      `gorm:"type:varchar(255);primary_key"`
	IP       *string     `gorm:"type:varchar(45)"`
	Tags     StringArray `gorm:"type:text[];not null;default:'{}'"`
	Online   bool        `gorm:"not null;default:false;index:idx_nodes_online"`
	HasAgent bool        `gorm:"not null;default:false;index:idx_nodes_has_agent"`
	LastSeen *time.Time
	Metadata JSONB     `gorm:"type:jsonb"`
	SyncedAt time.Time `gorm:"not null;default:now()"`
}

func AutoMigrate(db *gorm.DB) error {
	return db.AutoMigrate(
		&Deployment{},
		&Component{},
		&ComponentDeployment{},
		&Agent{},
		&DeploymentLog{},
		&Node{},
	)
}

type Configuration struct {
	Components []ComponentSpec `json:"components"`
}

type ComponentSpec struct {
	Type               string            `json:"type"`
	Name               string            `json:"name"`
	Hash               string            `json:"hash"`
	Tags               []string          `json:"tags"`
	Handler            string            `json:"handler,omitempty"`
	Content            *string           `json:"content,omitempty"`
	ContentURL         *string           `json:"content_url,omitempty"`
	ContentURLEncoding *string           `json:"content_url_encoding,omitempty"`
	NomadJob           *string           `json:"nomad_job,omitempty"`
	Managed            bool              `json:"managed,omitempty"`
	HealthCheck        *HealthCheckSpec  `json:"health_check,omitempty"`
	Env                map[string]string `json:"env,omitempty"`
	Args               []string          `json:"args,omitempty"`
}

type HealthCheckSpec struct {
	Type            string `json:"type"`
	Endpoint        string `json:"endpoint,omitempty"`
	IntervalSeconds int    `json:"interval_seconds"`
	TimeoutSeconds  int    `json:"timeout_seconds"`
	Retries         int    `json:"retries"`
}

type DeploymentStatus struct {
	ID              uuid.UUID         `json:"id"`
	Status          string            `json:"status"`
	CreatedAt       time.Time         `json:"created_at"`
	StartedAt       *time.Time        `json:"started_at,omitempty"`
	CompletedAt     *time.Time        `json:"completed_at,omitempty"`
	ComponentStatus []ComponentStatus `json:"component_status"`
	Summary         DeploymentSummary `json:"summary"`
}

type ComponentStatus struct {
	ComponentName string     `json:"component_name"`
	NodeHostname  string     `json:"node_hostname"`
	Status        string     `json:"status"`
	Message       *string    `json:"message,omitempty"`
	DeployedAt    *time.Time `json:"deployed_at,omitempty"`
}

type DeploymentSummary struct {
	TotalComponents int `json:"total_components"`
	TotalNodes      int `json:"total_nodes"`
	Deployed        int `json:"deployed"`
	Failed          int `json:"failed"`
	Pending         int `json:"pending"`
}
