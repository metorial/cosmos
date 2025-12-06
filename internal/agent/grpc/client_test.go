package grpc

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/metorial/fleet/cosmos/internal/agent/database"
)

func setupTestDB(t *testing.T) (*database.AgentDB, func()) {
	tmpDir, err := os.MkdirTemp("", "grpc-test-*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}

	db, err := database.NewAgentDB(tmpDir)
	if err != nil {
		os.RemoveAll(tmpDir)
		t.Fatalf("Failed to create test database: %v", err)
	}

	cleanup := func() {
		db.Close()
		os.RemoveAll(tmpDir)
	}

	return db, cleanup
}

func TestNewClient(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	config := &ClientConfig{
		ControllerURL:     "localhost:9091",
		Hostname:          "test-agent",
		DB:                db,
		ReconnectInterval: 1 * time.Second,
	}

	client, err := NewClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	if client.hostname != "test-agent" {
		t.Errorf("Expected hostname 'test-agent', got '%s'", client.hostname)
	}

	if client.controllerURL != "localhost:9091" {
		t.Errorf("Expected controller URL 'localhost:9091', got '%s'", client.controllerURL)
	}

	if client.reconnectInterval != 1*time.Second {
		t.Errorf("Expected reconnect interval 1s, got %v", client.reconnectInterval)
	}
}

func TestNewClientDefaultHostname(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	config := &ClientConfig{
		ControllerURL: "localhost:9091",
		DB:            db,
	}

	client, err := NewClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	if client.hostname == "" {
		t.Error("Expected hostname to be set from system hostname")
	}
}

func TestSendHeartbeat(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	component := &database.Component{
		Name:       "test-component",
		Type:       "program",
		Hash:       "test-hash",
		Executable: "/bin/test",
	}

	if err := db.UpsertComponent(component); err != nil {
		t.Fatalf("Failed to insert component: %v", err)
	}

	now := time.Now()
	status := &database.ComponentStatus{
		ComponentName: "test-component",
		Status:        "running",
		Message:       "Running normally",
		PID:           12345,
		LastStartedAt: &now,
		RestartCount:  2,
	}

	if err := db.UpsertComponentStatus(status); err != nil {
		t.Fatalf("Failed to insert status: %v", err)
	}

	config := &ClientConfig{
		ControllerURL: "localhost:9091",
		Hostname:      "test-agent",
		DB:            db,
	}

	client, err := NewClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	if err := client.SendHeartbeat(); err != nil {
		t.Fatalf("SendHeartbeat failed: %v", err)
	}

	select {
	case msg := <-client.outgoingCh:
		if msg.Hostname != "test-agent" {
			t.Errorf("Expected hostname 'test-agent', got '%s'", msg.Hostname)
		}

		heartbeat := msg.GetHeartbeat()
		if heartbeat == nil {
			t.Fatal("Expected heartbeat message, got nil")
		}

		if len(heartbeat.ComponentStatuses) != 1 {
			t.Fatalf("Expected 1 component status, got %d", len(heartbeat.ComponentStatuses))
		}

		compStatus := heartbeat.ComponentStatuses[0]
		if compStatus.Name != "test-component" {
			t.Errorf("Expected component name 'test-component', got '%s'", compStatus.Name)
		}

		if compStatus.Status != "running" {
			t.Errorf("Expected status 'running', got '%s'", compStatus.Status)
		}

		if compStatus.Pid != 12345 {
			t.Errorf("Expected PID 12345, got %d", compStatus.Pid)
		}

		if compStatus.RestartCount != 2 {
			t.Errorf("Expected restart count 2, got %d", compStatus.RestartCount)
		}

	case <-time.After(time.Second):
		t.Fatal("Timeout waiting for heartbeat message")
	}
}

func TestSendComponentStatus(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	component := &database.Component{
		Name:       "test-component",
		Type:       "program",
		Hash:       "test-hash",
		Executable: "/bin/test",
	}

	if err := db.UpsertComponent(component); err != nil {
		t.Fatalf("Failed to insert component: %v", err)
	}

	status := &database.ComponentStatus{
		ComponentName: "test-component",
		Status:        "stopped",
		Message:       "Manually stopped",
		PID:           0,
		RestartCount:  5,
	}

	if err := db.UpsertComponentStatus(status); err != nil {
		t.Fatalf("Failed to insert status: %v", err)
	}

	config := &ClientConfig{
		ControllerURL: "localhost:9091",
		Hostname:      "test-agent",
		DB:            db,
	}

	client, err := NewClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	if err := client.SendComponentStatus("test-component"); err != nil {
		t.Fatalf("SendComponentStatus failed: %v", err)
	}

	select {
	case msg := <-client.outgoingCh:
		compStatus := msg.GetComponentStatus()
		if compStatus == nil {
			t.Fatal("Expected component status message, got nil")
		}

		if compStatus.Name != "test-component" {
			t.Errorf("Expected component name 'test-component', got '%s'", compStatus.Name)
		}

		if compStatus.Status != "stopped" {
			t.Errorf("Expected status 'stopped', got '%s'", compStatus.Status)
		}

		if compStatus.Message != "Manually stopped" {
			t.Errorf("Expected message 'Manually stopped', got '%s'", compStatus.Message)
		}

	case <-time.After(time.Second):
		t.Fatal("Timeout waiting for component status message")
	}
}

func TestSendHealthCheckResult(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	config := &ClientConfig{
		ControllerURL: "localhost:9091",
		Hostname:      "test-agent",
		DB:            db,
	}

	client, err := NewClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	err = client.SendHealthCheckResult("test-component", "http", "success", "200 OK")
	if err != nil {
		t.Fatalf("SendHealthCheckResult failed: %v", err)
	}

	select {
	case msg := <-client.outgoingCh:
		healthResult := msg.GetHealthResult()
		if healthResult == nil {
			t.Fatal("Expected health result message, got nil")
		}

		if healthResult.ComponentName != "test-component" {
			t.Errorf("Expected component name 'test-component', got '%s'", healthResult.ComponentName)
		}

		if healthResult.CheckType != "http" {
			t.Errorf("Expected check type 'http', got '%s'", healthResult.CheckType)
		}

		if healthResult.Result != "success" {
			t.Errorf("Expected result 'success', got '%s'", healthResult.Result)
		}

		if healthResult.Message != "200 OK" {
			t.Errorf("Expected message '200 OK', got '%s'", healthResult.Message)
		}

	case <-time.After(time.Second):
		t.Fatal("Timeout waiting for health check result message")
	}
}

func TestSendDeploymentResult(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	config := &ClientConfig{
		ControllerURL: "localhost:9091",
		Hostname:      "test-agent",
		DB:            db,
	}

	client, err := NewClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	err = client.SendDeploymentResult("test-component", "deploy", "success", "Deployed successfully")
	if err != nil {
		t.Fatalf("SendDeploymentResult failed: %v", err)
	}

	select {
	case msg := <-client.outgoingCh:
		deployResult := msg.GetDeploymentResult()
		if deployResult == nil {
			t.Fatal("Expected deployment result message, got nil")
		}

		if deployResult.ComponentName != "test-component" {
			t.Errorf("Expected component name 'test-component', got '%s'", deployResult.ComponentName)
		}

		if deployResult.Operation != "deploy" {
			t.Errorf("Expected operation 'deploy', got '%s'", deployResult.Operation)
		}

		if deployResult.Result != "success" {
			t.Errorf("Expected result 'success', got '%s'", deployResult.Result)
		}

		if deployResult.Message != "Deployed successfully" {
			t.Errorf("Expected message 'Deployed successfully', got '%s'", deployResult.Message)
		}

	case <-time.After(time.Second):
		t.Fatal("Timeout waiting for deployment result message")
	}
}

func TestIsConnected(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	config := &ClientConfig{
		ControllerURL: "localhost:9091",
		Hostname:      "test-agent",
		DB:            db,
	}

	client, err := NewClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	if client.IsConnected() {
		t.Error("Expected client to not be connected initially")
	}

	client.setConnected(true)

	if !client.IsConnected() {
		t.Error("Expected client to be connected after setConnected(true)")
	}

	client.setConnected(false)

	if client.IsConnected() {
		t.Error("Expected client to not be connected after setConnected(false)")
	}
}

func TestStopClient(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	config := &ClientConfig{
		ControllerURL: "localhost:9091",
		Hostname:      "test-agent",
		DB:            db,
	}

	client, err := NewClient(config)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	done := make(chan struct{})
	go func() {
		if err := client.Stop(); err != nil {
			t.Logf("Stop returned error: %v", err)
		}
		close(done)
	}()

	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("Client stop timeout")
	}
}
