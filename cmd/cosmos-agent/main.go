package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/metorial/fleet/cosmos/internal/agent/component"
	"github.com/metorial/fleet/cosmos/internal/agent/database"
	agentgrpc "github.com/metorial/fleet/cosmos/internal/agent/grpc"
	"github.com/metorial/fleet/cosmos/internal/agent/health"
	"github.com/metorial/fleet/cosmos/internal/agent/reconciler"
	"github.com/metorial/fleet/cosmos/internal/util"
	log "github.com/sirupsen/logrus"
)

func main() {
	util.InitLogger()

	log.Info("Starting Cosmos Agent")

	config, err := util.LoadAgentConfig()
	if err != nil {
		log.WithError(err).Fatal("Failed to load configuration")
	}

	if err := os.MkdirAll(config.DataDir, 0755); err != nil {
		log.WithError(err).Fatal("Failed to create data directory")
	}

	db, err := database.NewAgentDB(config.DataDir)
	if err != nil {
		log.WithError(err).Fatal("Failed to initialize database")
	}
	defer db.Close()

	log.Info("Database initialized")

	var tlsConfig *util.TLSConfigWrapper
	if config.TLSEnabled {
		if config.VaultEnabled {
			log.Info("Initializing Vault certificate manager")

			certMgr, err := util.NewVaultCertManager(&util.VaultCertConfig{
				VaultAddr:  config.VaultAddr,
				VaultToken: config.VaultToken,
				PKIPath:    config.VaultPKIPath,
				Role:       config.VaultPKIRole,
				CertPath:   config.TLSCertPath,
				KeyPath:    config.TLSKeyPath,
				CAPath:     config.TLSCAPath,
				TTL:        config.CertTTL,
			})
			if err != nil {
				log.WithError(err).Fatal("Failed to create Vault certificate manager")
			}

			shouldRenew, err := certMgr.ShouldRenew(config.CertRenewBefore)
			if err != nil || shouldRenew {
				log.Info("Obtaining certificate from Vault")
				if err := certMgr.ObtainCertificate(); err != nil {
					log.WithError(err).Fatal("Failed to obtain certificate")
				}
			}

			tlsCfg, err := certMgr.LoadTLSConfig()
			if err != nil {
				log.WithError(err).Fatal("Failed to load TLS configuration")
			}

			tlsConfig = &util.TLSConfigWrapper{
				Config:    tlsCfg,
				CertMgr:   certMgr,
				RenewTime: config.CertRenewBefore,
			}

			go renewCertificatePeriodically(certMgr, config.CertRenewBefore)

		} else {
			log.Info("Loading TLS certificates from files")

			tlsCfg, err := util.LoadTLSConfigFromFiles(config.TLSCertPath, config.TLSKeyPath, config.TLSCAPath)
			if err != nil {
				log.WithError(err).Fatal("Failed to load TLS configuration")
			}

			tlsConfig = &util.TLSConfigWrapper{
				Config: tlsCfg,
			}
		}
	}

	componentMgr := component.NewManager(db, config.DataDir)
	log.Info("Component manager initialized")

	healthChecker := health.NewChecker(db, componentMgr.IsProcessRunning)
	log.Info("Health checker initialized")

	var grpcTLS *util.TLSConfigWrapper
	if tlsConfig != nil {
		grpcTLS = tlsConfig
	}

	grpcConfig := &agentgrpc.ClientConfig{
		ControllerURL:     config.ControllerURL,
		Tags:              config.Tags,
		DB:                db,
		ReconnectInterval: 5 * time.Second,
	}

	if grpcTLS != nil {
		grpcConfig.TLSConfig = grpcTLS.Config
	}

	grpcClient, err := agentgrpc.NewClient(grpcConfig)
	if err != nil {
		log.WithError(err).Fatal("Failed to create gRPC client")
	}

	if err := grpcClient.Start(); err != nil {
		log.WithError(err).Fatal("Failed to start gRPC client")
	}
	log.WithField("controller", config.ControllerURL).Info("gRPC client started")

	reconcilerConfig := &reconciler.ReconcilerConfig{
		DB:                db,
		ComponentManager:  componentMgr,
		HealthChecker:     healthChecker,
		GRPCClient:        grpcClient,
		ReconcileInterval: config.ReconcileInterval,
		HeartbeatInterval: config.HeartbeatInterval,
	}

	rec := reconciler.NewReconciler(reconcilerConfig)
	if err := rec.Start(); err != nil {
		log.WithError(err).Fatal("Failed to start reconciler")
	}
	log.Info("Reconciler started")

	log.Info("Cosmos Agent is running")

	waitForShutdown(func() {
		log.Info("Shutting down Cosmos Agent")

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if err := rec.Stop(); err != nil {
			log.WithError(err).Warn("Error stopping reconciler")
		}

		if err := grpcClient.Stop(); err != nil {
			log.WithError(err).Warn("Error stopping gRPC client")
		}

		if err := db.Close(); err != nil {
			log.WithError(err).Warn("Error closing database")
		}

		<-ctx.Done()
		log.Info("Shutdown complete")
	})
}

func waitForShutdown(cleanup func()) {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	sig := <-sigCh
	log.WithField("signal", sig).Info("Received shutdown signal")

	cleanup()
}

func renewCertificatePeriodically(certMgr *util.VaultCertManager, renewBefore time.Duration) {
	ticker := time.NewTicker(24 * time.Hour)
	defer ticker.Stop()

	for range ticker.C {
		shouldRenew, err := certMgr.ShouldRenew(renewBefore)
		if err != nil {
			log.WithError(err).Warn("Failed to check if certificate needs renewal")
			continue
		}

		if shouldRenew {
			log.Info("Renewing certificate from Vault")
			if err := certMgr.RenewCertificate(); err != nil {
				log.WithError(err).Error("Failed to renew certificate")
			} else {
				log.Info("Certificate renewed successfully")
			}
		}
	}
}
