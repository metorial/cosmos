package managers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/metorial/fleet/cosmos/internal/controller/types"
	log "github.com/sirupsen/logrus"
)

type ServiceManager struct {
	nomadAddr  string
	httpClient *http.Client
}

func NewServiceManager(nomadAddr string) *ServiceManager {
	return &ServiceManager{
		nomadAddr:  nomadAddr,
		httpClient: &http.Client{},
	}
}

func (sm *ServiceManager) Deploy(config *types.ComponentConfig) error {
	if sm.nomadAddr == "" {
		return fmt.Errorf("nomad address not configured")
	}

	log.WithField("component", config.Name).Info("Deploying service to Nomad")

	if config.NomadJob == "" {
		return fmt.Errorf("nomad_job specification is required")
	}

	var jobSpec map[string]interface{}
	if err := json.Unmarshal([]byte(config.NomadJob), &jobSpec); err != nil {
		return fmt.Errorf("failed to parse nomad job: %w", err)
	}

	body, err := json.Marshal(map[string]interface{}{
		"Job": jobSpec,
	})
	if err != nil {
		return fmt.Errorf("failed to marshal job: %w", err)
	}

	url := fmt.Sprintf("%s/v1/jobs", sm.nomadAddr)
	resp, err := sm.httpClient.Post(url, "application/json", bytes.NewBuffer(body))
	if err != nil {
		return fmt.Errorf("failed to submit job: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("nomad returned status %d: %s", resp.StatusCode, string(body))
	}

	log.WithField("component", config.Name).Info("Service deployed to Nomad")

	return nil
}

func (sm *ServiceManager) Remove(componentName string) error {
	if sm.nomadAddr == "" {
		return fmt.Errorf("nomad address not configured")
	}

	log.WithField("component", componentName).Info("Removing service from Nomad")

	url := fmt.Sprintf("%s/v1/job/%s", sm.nomadAddr, componentName)
	req, err := http.NewRequest(http.MethodDelete, url, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := sm.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to delete job: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("nomad returned status %d", resp.StatusCode)
	}

	log.WithField("component", componentName).Info("Service removed from Nomad")

	return nil
}
