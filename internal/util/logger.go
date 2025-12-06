package util

import (
	"os"

	log "github.com/sirupsen/logrus"
)

func InitLogger() {
	level := os.Getenv("COSMOS_LOG_LEVEL")
	if level == "" {
		level = "info"
	}

	logLevel, err := log.ParseLevel(level)
	if err != nil {
		logLevel = log.InfoLevel
	}

	log.SetLevel(logLevel)
	log.SetFormatter(&log.JSONFormatter{})
	log.SetOutput(os.Stdout)
}
