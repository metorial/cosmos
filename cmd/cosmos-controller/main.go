package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/metorial/fleet/cosmos/internal/controller/api"
	"github.com/metorial/fleet/cosmos/internal/controller/database"
	grpcserver "github.com/metorial/fleet/cosmos/internal/controller/grpc"
	"github.com/metorial/fleet/cosmos/internal/controller/jobs"
	"github.com/metorial/fleet/cosmos/internal/controller/managers"
	"github.com/metorial/fleet/cosmos/internal/controller/reconciler"
	"github.com/metorial/fleet/cosmos/internal/util"
	log "github.com/sirupsen/logrus"
)

func main() {
	util.InitLogger()

	log.Info("Starting Cosmos Controller")

	config, err := util.LoadControllerConfig()
	if err != nil {
		log.WithError(err).Fatal("Failed to load configuration")
	}

	db, err := database.NewControllerDB(config.DatabaseURL)
	if err != nil {
		log.WithError(err).Fatal("Failed to connect to database")
	}
	defer db.Close()

	log.Info("Database connected and migrated")

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

	var grpcTLS *util.TLSConfigWrapper
	if tlsConfig != nil {
		grpcTLS = tlsConfig
	}

	grpcServerConfig := &grpcserver.ServerConfig{
		DB:   db,
		Port: config.GRPCPort,
	}

	if grpcTLS != nil {
		grpcServerConfig.TLSConfig = grpcTLS.Config
	}

	grpcServer := grpcserver.NewServer(grpcServerConfig)
	if err := grpcServer.Start(); err != nil {
		log.WithError(err).Fatal("Failed to start gRPC server")
	}
	log.WithField("port", config.GRPCPort).Info("gRPC server started")

	scriptMgr := managers.NewScriptManager(config.CommandCoreURL)
	programMgr := managers.NewProgramManager()
	serviceMgr := managers.NewServiceManager(config.NomadAddr)

	rec := reconciler.NewReconciler(&reconciler.ReconcilerConfig{
		DB:         db,
		GRPCServer: grpcServer,
		ScriptMgr:  scriptMgr,
		ProgramMgr: programMgr,
		ServiceMgr: serviceMgr,
	})

	apiServer := api.NewServer(&api.ServerConfig{
		DB:         db,
		Reconciler: rec,
		Port:       config.HTTPPort,
	})

	if err := apiServer.Start(); err != nil {
		log.WithError(err).Fatal("Failed to start API server")
	}
	log.WithField("port", config.HTTPPort).Info("API server started")

	jobsMgr := jobs.NewJobsManager(db, config.CommandCoreURL)
	jobsMgr.Start()

	log.Info("Cosmos Controller is running")

	waitForShutdown(func() {
		log.Info("Shutting down Cosmos Controller")

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		jobsMgr.Stop()

		if err := apiServer.Stop(); err != nil {
			log.WithError(err).Warn("Error stopping API server")
		}

		if err := grpcServer.Stop(); err != nil {
			log.WithError(err).Warn("Error stopping gRPC server")
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
