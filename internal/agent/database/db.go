package database

import (
	"encoding/json"
	"fmt"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type AgentDB struct {
	db *gorm.DB
}

type Component struct {
	Name               string `gorm:"primaryKey"`
	Type               string `gorm:"not null"`
	Hash               string `gorm:"not null"`
	ContentURL         string
	ContentURLEncoding string
	Content            string
	Executable         string
	Env                string `gorm:"type:text"` // JSON string
	Args               string `gorm:"type:text"` // JSON string
	Managed            bool   `gorm:"default:false"`
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

type ComponentStatus struct {
	ComponentName string `gorm:"primaryKey"`
	Status        string `gorm:"not null"`
	Message       string
	PID           int
	LastStartedAt *time.Time
	LastCheckedAt time.Time
	RestartCount  int `gorm:"default:0"`
	UpdatedAt     time.Time
}

type HealthCheck struct {
	ComponentName       string `gorm:"primaryKey"`
	Type                string `gorm:"not null"`
	Endpoint            string
	IntervalSeconds     int `gorm:"default:30"`
	TimeoutSeconds      int `gorm:"default:5"`
	Retries             int `gorm:"default:3"`
	LastCheckAt         *time.Time
	LastResult          string
	ConsecutiveFailures int `gorm:"default:0"`
}

type DeploymentLog struct {
	ID            uint `gorm:"primaryKey;autoIncrement"`
	ComponentName string
	Operation     string `gorm:"not null"`
	Status        string `gorm:"not null"`
	Message       string
	Timestamp     time.Time `gorm:"not null"`
}

func NewAgentDB(dataDir string) (*AgentDB, error) {
	dbPath := fmt.Sprintf("%s/agent.db", dataDir)

	db, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	if err := db.AutoMigrate(&Component{}, &ComponentStatus{}, &HealthCheck{}, &DeploymentLog{}); err != nil {
		return nil, fmt.Errorf("failed to migrate database: %w", err)
	}

	return &AgentDB{db: db}, nil
}

func (db *AgentDB) UpsertComponent(comp *Component) error {
	return db.db.Save(comp).Error
}

func (db *AgentDB) GetComponent(name string) (*Component, error) {
	var comp Component
	if err := db.db.First(&comp, "name = ?", name).Error; err != nil {
		return nil, err
	}
	return &comp, nil
}

func (db *AgentDB) GetAllComponents() ([]*Component, error) {
	var comps []*Component
	if err := db.db.Find(&comps).Error; err != nil {
		return nil, err
	}
	return comps, nil
}

func (db *AgentDB) DeleteComponent(name string) error {
	return db.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Delete(&Component{}, "name = ?", name).Error; err != nil {
			return err
		}
		if err := tx.Delete(&ComponentStatus{}, "component_name = ?", name).Error; err != nil {
			return err
		}
		if err := tx.Delete(&HealthCheck{}, "component_name = ?", name).Error; err != nil {
			return err
		}
		return nil
	})
}

func (db *AgentDB) UpsertComponentStatus(status *ComponentStatus) error {
	status.UpdatedAt = time.Now()
	return db.db.Save(status).Error
}

func (db *AgentDB) GetComponentStatus(name string) (*ComponentStatus, error) {
	var status ComponentStatus
	if err := db.db.First(&status, "component_name = ?", name).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return &ComponentStatus{
				ComponentName: name,
				Status:        "unknown",
				LastCheckedAt: time.Now(),
			}, nil
		}
		return nil, err
	}
	return &status, nil
}

func (db *AgentDB) UpsertHealthCheck(check *HealthCheck) error {
	return db.db.Save(check).Error
}

func (db *AgentDB) GetHealthCheck(name string) (*HealthCheck, error) {
	var check HealthCheck
	if err := db.db.First(&check, "component_name = ?", name).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, nil
		}
		return nil, err
	}
	return &check, nil
}

func (db *AgentDB) LogDeployment(log *DeploymentLog) error {
	log.Timestamp = time.Now()
	return db.db.Create(log).Error
}

func (db *AgentDB) GetEnvMap(component *Component) (map[string]string, error) {
	if component.Env == "" {
		return make(map[string]string), nil
	}

	var env map[string]string
	if err := json.Unmarshal([]byte(component.Env), &env); err != nil {
		return nil, err
	}
	return env, nil
}

func (db *AgentDB) GetArgsSlice(component *Component) ([]string, error) {
	if component.Args == "" {
		return []string{}, nil
	}

	var args []string
	if err := json.Unmarshal([]byte(component.Args), &args); err != nil {
		return nil, err
	}
	return args, nil
}

func (db *AgentDB) SetEnvMap(component *Component, env map[string]string) error {
	data, err := json.Marshal(env)
	if err != nil {
		return err
	}
	component.Env = string(data)
	return nil
}

func (db *AgentDB) SetArgsSlice(component *Component, args []string) error {
	data, err := json.Marshal(args)
	if err != nil {
		return err
	}
	component.Args = string(data)
	return nil
}

func (db *AgentDB) Close() error {
	sqlDB, err := db.db.DB()
	if err != nil {
		return err
	}
	return sqlDB.Close()
}
