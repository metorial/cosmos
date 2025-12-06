package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/google/uuid"
)

type Client struct {
	baseURL    string
	httpClient *http.Client
}

func NewClient(baseURL string) *Client {
	return &Client{
		baseURL: baseURL,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

type ConfigurationRequest struct {
	Components []ComponentConfig `json:"components"`
}

type ComponentConfig struct {
	Type               string             `json:"type"`
	Name               string             `json:"name"`
	Hash               string             `json:"hash"`
	Tags               []string           `json:"tags"`
	Handler            string             `json:"handler,omitempty"`
	Content            string             `json:"content,omitempty"`
	ContentURL         string             `json:"content_url,omitempty"`
	ContentURLEncoding string             `json:"content_url_encoding,omitempty"`
	Managed            bool               `json:"managed,omitempty"`
	HealthCheck        *HealthCheckConfig `json:"health_check,omitempty"`
	Env                map[string]string  `json:"env,omitempty"`
	Args               []string           `json:"args,omitempty"`
}

type HealthCheckConfig struct {
	Type            string `json:"type"`
	Endpoint        string `json:"endpoint,omitempty"`
	IntervalSeconds int32  `json:"interval_seconds"`
	TimeoutSeconds  int32  `json:"timeout_seconds"`
	Retries         int32  `json:"retries"`
}

type DeploymentResponse struct {
	ID      uuid.UUID `json:"id"`
	Status  string    `json:"status"`
	Message string    `json:"message"`
}

type Deployment struct {
	ID            uuid.UUID       `json:"id"`
	Configuration json.RawMessage `json:"configuration"`
	Status        string          `json:"status"`
	CreatedAt     time.Time       `json:"created_at"`
	StartedAt     *time.Time      `json:"started_at,omitempty"`
	CompletedAt   *time.Time      `json:"completed_at,omitempty"`
	ErrorMessage  string          `json:"error_message,omitempty"`
}

type Component struct {
	Name      string    `json:"name"`
	Type      string    `json:"type"`
	Handler   string    `json:"handler"`
	Hash      string    `json:"hash"`
	Tags      []string  `json:"tags"`
	CreatedAt time.Time `json:"created_at"`
}

type ComponentDeployment struct {
	ID              uuid.UUID  `json:"id"`
	ComponentName   string     `json:"component_name"`
	NodeHostname    string     `json:"node_hostname"`
	Status          string     `json:"status"`
	Message         string     `json:"message,omitempty"`
	PID             *int       `json:"pid,omitempty"`
	HealthStatus    string     `json:"health_status,omitempty"`
	LastHealthCheck *time.Time `json:"last_health_check,omitempty"`
	DeployedAt      *time.Time `json:"deployed_at,omitempty"`
}

type Agent struct {
	Hostname       string    `json:"hostname"`
	AgentVersion   string    `json:"agent_version"`
	LastHeartbeat  time.Time `json:"last_heartbeat"`
	Online         bool      `json:"online"`
	ComponentCount int       `json:"component_count"`
}

func (c *Client) CreateDeployment(config ConfigurationRequest) (*DeploymentResponse, error) {
	body, err := json.Marshal(config)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal config: %w", err)
	}

	resp, err := c.httpClient.Post(
		fmt.Sprintf("%s/api/v1/deployments", c.baseURL),
		"application/json",
		bytes.NewBuffer(body),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("unexpected status %d: %s", resp.StatusCode, string(body))
	}

	var result DeploymentResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return &result, nil
}

func (c *Client) GetDeployment(id uuid.UUID) (*Deployment, error) {
	resp, err := c.httpClient.Get(fmt.Sprintf("%s/api/v1/deployments/%s", c.baseURL, id))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %d", resp.StatusCode)
	}

	var result struct {
		Deployment Deployment `json:"deployment"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	return &result.Deployment, nil
}

func (c *Client) ListComponents() ([]Component, error) {
	resp, err := c.httpClient.Get(fmt.Sprintf("%s/api/v1/components", c.baseURL))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var components []Component
	if err := json.NewDecoder(resp.Body).Decode(&components); err != nil {
		return nil, err
	}

	return components, nil
}

func (c *Client) GetComponentDeployments(name string) ([]ComponentDeployment, error) {
	resp, err := c.httpClient.Get(fmt.Sprintf("%s/api/v1/components/%s/deployments", c.baseURL, name))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var deployments []ComponentDeployment
	if err := json.NewDecoder(resp.Body).Decode(&deployments); err != nil {
		return nil, err
	}

	return deployments, nil
}

func (c *Client) ListAgents() ([]Agent, error) {
	resp, err := c.httpClient.Get(fmt.Sprintf("%s/api/v1/agents", c.baseURL))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var agents []Agent
	if err := json.NewDecoder(resp.Body).Decode(&agents); err != nil {
		return nil, err
	}

	return agents, nil
}

func (c *Client) WaitForHealth() error {
	for i := 0; i < 30; i++ {
		resp, err := c.httpClient.Get(fmt.Sprintf("%s/api/v1/health", c.baseURL))
		if err == nil && resp.StatusCode == http.StatusOK {
			resp.Body.Close()
			return nil
		}
		if resp != nil {
			resp.Body.Close()
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("controller did not become healthy")
}

func (c *Client) WaitForAgents(count int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		agents, err := c.ListAgents()
		if err == nil {
			onlineCount := 0
			for _, agent := range agents {
				if agent.Online {
					onlineCount++
				}
			}
			if onlineCount >= count {
				return nil
			}
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("expected %d agents, timeout reached", count)
}

func (c *Client) WaitForDeploymentComplete(id uuid.UUID, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		deployment, err := c.GetDeployment(id)
		if err != nil {
			time.Sleep(2 * time.Second)
			continue
		}

		if deployment.Status == "completed" {
			return nil
		}

		if deployment.Status == "failed" {
			return fmt.Errorf("deployment failed: %s", deployment.ErrorMessage)
		}

		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("deployment did not complete within timeout")
}

func (c *Client) WaitForComponentDeployments(componentName string, expectedCount int, expectedStatus string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		deployments, err := c.GetComponentDeployments(componentName)
		if err != nil {
			time.Sleep(2 * time.Second)
			continue
		}

		matchingCount := 0
		for _, dep := range deployments {
			if dep.Status == expectedStatus {
				matchingCount++
			}
		}

		if matchingCount >= expectedCount {
			return nil
		}

		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("expected %d deployments with status %s, timeout reached", expectedCount, expectedStatus)
}
