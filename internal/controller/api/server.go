package api

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/metorial/fleet/cosmos/internal/controller/database"
	"github.com/metorial/fleet/cosmos/internal/controller/types"
	log "github.com/sirupsen/logrus"
)

//go:embed static/*
var staticFiles embed.FS

type ReconcilerInterface interface {
	ProcessDeployment(deploymentID uuid.UUID, config types.ConfigurationRequest) error
}

type Server struct {
	db         *database.ControllerDB
	reconciler ReconcilerInterface
	port       int
	server     *http.Server
}

type ServerConfig struct {
	DB         *database.ControllerDB
	Reconciler ReconcilerInterface
	Port       int
}

type DeploymentResponse struct {
	ID      uuid.UUID `json:"id"`
	Status  string    `json:"status"`
	Message string    `json:"message,omitempty"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

func NewServer(config *ServerConfig) *Server {
	return &Server{
		db:         config.DB,
		reconciler: config.Reconciler,
		port:       config.Port,
	}
}

func (s *Server) Start() error {
	router := mux.NewRouter()

	api := router.PathPrefix("/api/v1").Subrouter()

	api.HandleFunc("/health", s.handleHealth).Methods("GET")
	api.HandleFunc("/deployments", s.handleCreateDeployment).Methods("POST")
	api.HandleFunc("/deployments", s.handleListDeployments).Methods("GET")
	api.HandleFunc("/deployments/{id}", s.handleGetDeployment).Methods("GET")
	api.HandleFunc("/components", s.handleListComponents).Methods("GET")
	api.HandleFunc("/components/{name}", s.handleGetComponent).Methods("GET")
	api.HandleFunc("/components/{name}/deployments", s.handleGetComponentDeployments).Methods("GET")
	api.HandleFunc("/nodes", s.handleListNodes).Methods("GET")
	api.HandleFunc("/nodes/{hostname}", s.handleGetNode).Methods("GET")
	api.HandleFunc("/nodes/{hostname}/components", s.handleGetNodeComponents).Methods("GET")
	api.HandleFunc("/agents", s.handleListAgents).Methods("GET")
	api.HandleFunc("/agents/{hostname}", s.handleGetAgent).Methods("GET")

	// Serve static files from embedded filesystem
	staticFS, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.WithError(err).Fatal("Failed to load embedded static files")
	}
	router.PathPrefix("/static/").Handler(http.StripPrefix("/static/", http.FileServer(http.FS(staticFS))))
	router.HandleFunc("/", s.handleIndex).Methods("GET")

	router.Use(loggingMiddleware)
	router.Use(corsMiddleware)

	s.server = &http.Server{
		Addr:    fmt.Sprintf(":%d", s.port),
		Handler: router,
	}

	log.WithField("port", s.port).Info("Starting HTTP API server")

	go func() {
		if err := s.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.WithError(err).Error("HTTP server error")
		}
	}()

	return nil
}

func (s *Server) Stop() error {
	log.Info("Stopping HTTP API server")

	if s.server != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return s.server.Shutdown(ctx)
	}

	return nil
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	data, err := staticFiles.ReadFile("static/index.html")
	if err != nil {
		log.WithError(err).Error("Failed to read index.html")
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	respondJSON(w, http.StatusOK, map[string]string{
		"status": "healthy",
	})
}

func (s *Server) handleCreateDeployment(w http.ResponseWriter, r *http.Request) {
	var req types.ConfigurationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondError(w, http.StatusBadRequest, fmt.Sprintf("Invalid request body: %v", err))
		return
	}

	// Allow empty components array - it means remove all components

	configJSON, err := json.Marshal(req)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "Failed to serialize configuration")
		return
	}

	deployment := &database.Deployment{
		ID:            uuid.New(),
		Configuration: configJSON,
		Status:        "pending",
		CreatedAt:     time.Now(),
	}

	if err := s.db.CreateDeployment(deployment); err != nil {
		log.WithError(err).Error("Failed to create deployment")
		respondError(w, http.StatusInternalServerError, "Failed to create deployment")
		return
	}

	go func() {
		if err := s.reconciler.ProcessDeployment(deployment.ID, req); err != nil {
			log.WithError(err).WithField("deployment_id", deployment.ID).Error("Deployment failed")
			s.db.UpdateDeploymentStatus(deployment.ID, "failed", err.Error())
		} else {
			s.db.UpdateDeploymentStatus(deployment.ID, "completed", "")
		}
	}()

	respondJSON(w, http.StatusCreated, DeploymentResponse{
		ID:      deployment.ID,
		Status:  "pending",
		Message: "Deployment queued for processing",
	})
}

func (s *Server) handleListDeployments(w http.ResponseWriter, r *http.Request) {
	limitStr := r.URL.Query().Get("limit")
	offsetStr := r.URL.Query().Get("offset")

	limit := 50
	offset := 0

	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	if offsetStr != "" {
		if o, err := strconv.Atoi(offsetStr); err == nil && o >= 0 {
			offset = o
		}
	}

	deployments, err := s.db.ListDeployments(limit, offset)
	if err != nil {
		log.WithError(err).Error("Failed to list deployments")
		respondError(w, http.StatusInternalServerError, "Failed to list deployments")
		return
	}

	respondJSON(w, http.StatusOK, deployments)
}

func (s *Server) handleGetDeployment(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	idStr := vars["id"]

	id, err := uuid.Parse(idStr)
	if err != nil {
		respondError(w, http.StatusBadRequest, "Invalid deployment ID")
		return
	}

	deployment, err := s.db.GetDeployment(id)
	if err != nil {
		respondError(w, http.StatusNotFound, "Deployment not found")
		return
	}

	logs, _ := s.db.GetDeploymentLogs(id, 100)

	response := map[string]interface{}{
		"deployment": deployment,
		"logs":       logs,
	}

	respondJSON(w, http.StatusOK, response)
}

func (s *Server) handleListComponents(w http.ResponseWriter, r *http.Request) {
	components, err := s.db.ListComponents()
	if err != nil {
		log.WithError(err).Error("Failed to list components")
		respondError(w, http.StatusInternalServerError, "Failed to list components")
		return
	}

	respondJSON(w, http.StatusOK, components)
}

func (s *Server) handleGetComponent(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	name := vars["name"]

	component, err := s.db.GetComponent(name)
	if err != nil {
		respondError(w, http.StatusNotFound, "Component not found")
		return
	}

	respondJSON(w, http.StatusOK, component)
}

func (s *Server) handleGetComponentDeployments(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	name := vars["name"]

	deployments, err := s.db.GetComponentDeployments(name)
	if err != nil {
		log.WithError(err).Error("Failed to get component deployments")
		respondError(w, http.StatusInternalServerError, "Failed to get component deployments")
		return
	}

	respondJSON(w, http.StatusOK, deployments)
}

func (s *Server) handleListNodes(w http.ResponseWriter, r *http.Request) {
	onlineOnly := r.URL.Query().Get("online") == "true"

	nodes, err := s.db.ListNodes(onlineOnly)
	if err != nil {
		log.WithError(err).Error("Failed to list nodes")
		respondError(w, http.StatusInternalServerError, "Failed to list nodes")
		return
	}

	respondJSON(w, http.StatusOK, nodes)
}

func (s *Server) handleGetNode(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	hostname := vars["hostname"]

	node, err := s.db.GetNode(hostname)
	if err != nil {
		respondError(w, http.StatusNotFound, "Node not found")
		return
	}

	respondJSON(w, http.StatusOK, node)
}

func (s *Server) handleGetNodeComponents(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	hostname := vars["hostname"]

	deployments, err := s.db.GetNodeDeployments(hostname)
	if err != nil {
		log.WithError(err).Error("Failed to get node components")
		respondError(w, http.StatusInternalServerError, "Failed to get node components")
		return
	}

	respondJSON(w, http.StatusOK, deployments)
}

func (s *Server) handleListAgents(w http.ResponseWriter, r *http.Request) {
	onlineOnly := r.URL.Query().Get("online") == "true"

	agents, err := s.db.ListAgents(onlineOnly)
	if err != nil {
		log.WithError(err).Error("Failed to list agents")
		respondError(w, http.StatusInternalServerError, "Failed to list agents")
		return
	}

	respondJSON(w, http.StatusOK, agents)
}

func (s *Server) handleGetAgent(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	hostname := vars["hostname"]

	agent, err := s.db.GetAgent(hostname)
	if err != nil {
		respondError(w, http.StatusNotFound, "Agent not found")
		return
	}

	respondJSON(w, http.StatusOK, agent)
}

func respondJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func respondError(w http.ResponseWriter, status int, message string) {
	respondJSON(w, status, ErrorResponse{Error: message})
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		wrapped := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		next.ServeHTTP(wrapped, r)

		log.WithFields(log.Fields{
			"method":      r.Method,
			"path":        r.URL.Path,
			"status":      wrapped.statusCode,
			"duration":    time.Since(start),
			"remote_addr": r.RemoteAddr,
		}).Info("HTTP request")
	})
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}
