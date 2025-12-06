package managers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/metorial/fleet/cosmos/internal/controller/types"
	log "github.com/sirupsen/logrus"
)

type ScriptManager struct {
	commandCoreURL string
	httpClient     *http.Client
}

func NewScriptManager(commandCoreURL string) *ScriptManager {
	return &ScriptManager{
		commandCoreURL: commandCoreURL,
		httpClient:     &http.Client{},
	}
}

type CommandCoreScriptRequest struct {
	Content string   `json:"content"`
	Targets []string `json:"targets"`
	Hash    string   `json:"hash"`
}

func (sm *ScriptManager) DeployViaCommandCore(config *types.ComponentConfig, targetNodes []string) error {
	if sm.commandCoreURL == "" {
		return fmt.Errorf("command-core URL not configured")
	}

	log.WithFields(log.Fields{
		"component": config.Name,
		"nodes":     len(targetNodes),
	}).Info("Deploying script via command-core")

	req := CommandCoreScriptRequest{
		Content: config.Content,
		Targets: targetNodes,
		Hash:    config.Hash,
	}

	body, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("failed to marshal request: %w", err)
	}

	resp, err := sm.httpClient.Post(
		fmt.Sprintf("%s/api/v1/scripts", sm.commandCoreURL),
		"application/json",
		bytes.NewBuffer(body),
	)
	if err != nil {
		return fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return fmt.Errorf("command-core returned status %d", resp.StatusCode)
	}

	log.WithField("component", config.Name).Info("Script deployment submitted to command-core")

	return nil
}
