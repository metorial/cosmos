package util

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type AgentConfig struct {
	ControllerURL string
	AgentPort     string
	DataDir       string
	LogLevel      string

	TLSEnabled  bool
	TLSCertPath string
	TLSKeyPath  string
	TLSCAPath   string

	VaultEnabled    bool
	VaultAddr       string
	VaultToken      string
	VaultPKIPath    string
	VaultPKIRole    string
	CertTTL         string
	CertRenewBefore time.Duration

	ReconcileInterval time.Duration
	HeartbeatInterval time.Duration
}

type ControllerConfig struct {
	HTTPPort    int
	GRPCPort    int
	DatabaseURL string
	LogLevel    string

	TLSEnabled  bool
	TLSCertPath string
	TLSKeyPath  string
	TLSCAPath   string

	VaultEnabled    bool
	VaultAddr       string
	VaultToken      string
	VaultPKIPath    string
	VaultPKIRole    string
	CertTTL         string
	CertRenewBefore time.Duration

	CommandCoreURL string
	NomadAddr      string
	ConsulAddr     string

	AgentTimeout        time.Duration
	NodeSyncInterval    time.Duration
	CleanupInterval     time.Duration
	DeploymentRetention time.Duration
}

func LoadAgentConfig() (*AgentConfig, error) {
	config := &AgentConfig{
		ControllerURL: getEnv("COSMOS_CONTROLLER_URL", "controller:9091"),
		AgentPort:     getEnv("COSMOS_AGENT_PORT", "9092"),
		DataDir:       getEnv("COSMOS_DATA_DIR", "/var/lib/cosmos/agent"),
		LogLevel:      getEnv("COSMOS_LOG_LEVEL", "info"),

		TLSEnabled:  getEnvBool("COSMOS_TLS_ENABLED", true),
		TLSCertPath: getEnv("COSMOS_TLS_CERT", "/etc/cosmos/agent/agent.crt"),
		TLSKeyPath:  getEnv("COSMOS_TLS_KEY", "/etc/cosmos/agent/agent.key"),
		TLSCAPath:   getEnv("COSMOS_TLS_CA", "/etc/cosmos/agent/ca.crt"),

		VaultEnabled:    getEnvBool("VAULT_ENABLED", true),
		VaultAddr:       os.Getenv("VAULT_ADDR"),
		VaultToken:      os.Getenv("VAULT_TOKEN"),
		VaultPKIPath:    getEnv("COSMOS_VAULT_PKI_PATH", "cosmos-pki"),
		VaultPKIRole:    getEnv("COSMOS_VAULT_PKI_ROLE", "agent"),
		CertTTL:         getEnv("COSMOS_CERT_TTL", "72h"),
		CertRenewBefore: getEnvDuration("COSMOS_CERT_RENEW_BEFORE", 24*time.Hour),

		ReconcileInterval: getEnvDuration("COSMOS_AGENT_RECONCILE_INTERVAL", 30*time.Second),
		HeartbeatInterval: getEnvDuration("COSMOS_AGENT_HEARTBEAT_INTERVAL", 30*time.Second),
	}

	if config.VaultEnabled && (config.VaultAddr == "" || config.VaultToken == "") {
		return nil, fmt.Errorf("vault enabled but VAULT_ADDR or VAULT_TOKEN not set")
	}

	return config, nil
}

func LoadControllerConfig() (*ControllerConfig, error) {
	config := &ControllerConfig{
		HTTPPort:    getEnvInt("COSMOS_HTTP_PORT", 8090),
		GRPCPort:    getEnvInt("COSMOS_GRPC_PORT", 9091),
		DatabaseURL: os.Getenv("COSMOS_DB_URL"),
		LogLevel:    getEnv("COSMOS_LOG_LEVEL", "info"),

		TLSEnabled:  getEnvBool("COSMOS_TLS_ENABLED", true),
		TLSCertPath: getEnv("COSMOS_TLS_CERT", "/etc/cosmos/controller/controller.crt"),
		TLSKeyPath:  getEnv("COSMOS_TLS_KEY", "/etc/cosmos/controller/controller.key"),
		TLSCAPath:   getEnv("COSMOS_TLS_CA", "/etc/cosmos/controller/ca.crt"),

		VaultEnabled:    getEnvBool("VAULT_ENABLED", true),
		VaultAddr:       os.Getenv("VAULT_ADDR"),
		VaultToken:      os.Getenv("VAULT_TOKEN"),
		VaultPKIPath:    getEnv("COSMOS_VAULT_PKI_PATH", "cosmos-pki"),
		VaultPKIRole:    getEnv("COSMOS_VAULT_PKI_ROLE", "controller"),
		CertTTL:         getEnv("COSMOS_CERT_TTL", "8760h"),
		CertRenewBefore: getEnvDuration("COSMOS_CERT_RENEW_BEFORE", 720*time.Hour),

		NomadAddr: getEnv("NOMAD_ADDR", "http://nomad.service.consul:4646"),

		AgentTimeout:        getEnvDuration("COSMOS_CONTROLLER_AGENT_TIMEOUT", 90*time.Second),
		NodeSyncInterval:    getEnvDuration("COSMOS_CONTROLLER_NODE_SYNC_INTERVAL", 5*time.Minute),
		CleanupInterval:     getEnvDuration("COSMOS_CONTROLLER_CLEANUP_INTERVAL", 24*time.Hour),
		DeploymentRetention: getEnvDuration("COSMOS_CONTROLLER_DEPLOYMENT_RETENTION", 720*time.Hour),
	}

	if config.DatabaseURL == "" {
		return nil, fmt.Errorf("COSMOS_DB_URL is required")
	}

	if config.VaultEnabled && (config.VaultAddr == "" || config.VaultToken == "") {
		return nil, fmt.Errorf("vault enabled but VAULT_ADDR or VAULT_TOKEN not set")
	}

	return config, nil
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvBool(key string, defaultValue bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}

	boolVal, err := strconv.ParseBool(value)
	if err != nil {
		return defaultValue
	}
	return boolVal
}

func getEnvDuration(key string, defaultValue time.Duration) time.Duration {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}

	duration, err := time.ParseDuration(value)
	if err != nil {
		return defaultValue
	}
	return duration
}

func getEnvInt(key string, defaultValue int) int {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}

	intVal, err := strconv.Atoi(value)
	if err != nil {
		return defaultValue
	}
	return intVal
}
