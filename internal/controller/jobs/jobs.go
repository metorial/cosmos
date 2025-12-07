package jobs

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/metorial/fleet/cosmos/internal/controller/database"
	log "github.com/sirupsen/logrus"
)

type JobsManager struct {
	db             *database.ControllerDB
	commandCoreURL string
	httpClient     *http.Client
	ctx            context.Context
	cancel         context.CancelFunc
}

func NewJobsManager(db *database.ControllerDB, commandCoreURL string) *JobsManager {
	ctx, cancel := context.WithCancel(context.Background())

	return &JobsManager{
		db:             db,
		commandCoreURL: commandCoreURL,
		httpClient:     &http.Client{Timeout: 10 * time.Second},
		ctx:            ctx,
		cancel:         cancel,
	}
}

func (jm *JobsManager) Start() {
	log.Info("Starting background jobs")

	go jm.markOfflineAgents()
	go jm.syncNodesFromCommandCore()
	go jm.cleanupOldDeployments()
}

func (jm *JobsManager) Stop() {
	log.Info("Stopping background jobs")
	jm.cancel()
}

func (jm *JobsManager) markOfflineAgents() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-jm.ctx.Done():
			return
		case <-ticker.C:
			threshold := time.Now().Add(-2 * time.Minute)

			if err := jm.db.MarkAgentsOffline(threshold); err != nil {
				log.WithError(err).Warn("Failed to mark agents offline")
			} else {
				log.Debug("Checked for offline agents")
			}
		}
	}
}

func (jm *JobsManager) syncNodesFromCommandCore() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	jm.performNodeSync()

	for {
		select {
		case <-jm.ctx.Done():
			return
		case <-ticker.C:
			jm.performNodeSync()
		}
	}
}

func (jm *JobsManager) performNodeSync() {
	if jm.commandCoreURL == "" {
		log.Debug("Command-core URL not configured, skipping node sync")
		return
	}

	log.Debug("Syncing nodes from command-core")

	type CommandCoreHost struct {
		Hostname string                 `json:"hostname"`
		IP       string                 `json:"ip"`
		Tags     []string               `json:"tags"`
		Online   bool                   `json:"online"`
		LastSeen time.Time              `json:"last_seen"`
		Metadata map[string]interface{} `json:"metadata"`
	}

	resp, err := jm.httpClient.Get(fmt.Sprintf("%s/api/v1/hosts", jm.commandCoreURL))
	if err != nil {
		log.WithError(err).Warn("Failed to fetch nodes from command-core")
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.WithField("status", resp.StatusCode).Warn("Command-core returned error status")
		return
	}

	var hosts []CommandCoreHost
	if err := json.NewDecoder(resp.Body).Decode(&hosts); err != nil {
		log.WithError(err).Warn("Failed to decode command-core response")
		return
	}

	log.WithField("count", len(hosts)).Info("Syncing nodes from command-core")

	agents, err := jm.db.ListAgents(false)
	if err != nil {
		log.WithError(err).Warn("Failed to list agents")
		return
	}

	agentMap := make(map[string]bool)
	for _, agent := range agents {
		agentMap[agent.Hostname] = agent.Online
	}

	for _, host := range hosts {
		hasAgent := agentMap[host.Hostname]

		metadata, _ := json.Marshal(host.Metadata)

		node := &database.Node{
			Hostname: host.Hostname,
			IP:       host.IP,
			Tags:     host.Tags,
			Online:   host.Online,
			HasAgent: hasAgent,
			LastSeen: &host.LastSeen,
			Metadata: metadata,
			SyncedAt: time.Now(),
		}

		if err := jm.db.UpsertNode(node); err != nil {
			log.WithError(err).WithField("hostname", host.Hostname).Warn("Failed to upsert node")
		}
	}

	log.WithField("count", len(hosts)).Info("Node sync completed")
}

func (jm *JobsManager) cleanupOldDeployments() {
	ticker := time.NewTicker(24 * time.Hour)
	defer ticker.Stop()

	for {
		select {
		case <-jm.ctx.Done():
			return
		case <-ticker.C:
			threshold := time.Now().Add(-30 * 24 * time.Hour)

			if err := jm.db.CleanupOldDeployments(threshold); err != nil {
				log.WithError(err).Warn("Failed to cleanup old deployments")
			} else {
				log.Info("Cleaned up old deployments")
			}
		}
	}
}
