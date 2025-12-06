package health

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/metorial/fleet/cosmos/internal/agent/database"
)

func setupTestDB(t *testing.T) (*database.AgentDB, func()) {
	tmpDir, err := os.MkdirTemp("", "health-test-*")
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

func TestHTTPHealthCheck(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	tests := []struct {
		name           string
		statusCode     int
		shouldFail     bool
		expectedResult string
	}{
		{
			name:           "Success with 200",
			statusCode:     200,
			shouldFail:     false,
			expectedResult: "success",
		},
		{
			name:           "Success with 204",
			statusCode:     204,
			shouldFail:     false,
			expectedResult: "success",
		},
		{
			name:           "Failure with 500",
			statusCode:     500,
			shouldFail:     true,
			expectedResult: "failure",
		},
		{
			name:           "Failure with 404",
			statusCode:     404,
			shouldFail:     true,
			expectedResult: "failure",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tt.statusCode)
			}))
			defer server.Close()

			mockProcessCheck := func(pid int) bool { return true }
			checker := NewChecker(db, mockProcessCheck)

			check := &database.HealthCheck{
				ComponentName:   "test-http-component",
				Type:            "http",
				Endpoint:        server.URL,
				IntervalSeconds: 30,
				TimeoutSeconds:  5,
				Retries:         3,
			}

			if err := db.UpsertHealthCheck(check); err != nil {
				t.Fatalf("Failed to insert health check: %v", err)
			}

			err := checker.RunHealthCheck(context.Background(), "test-http-component")

			if tt.shouldFail && err == nil {
				t.Error("Expected health check to fail, but it succeeded")
			}

			if !tt.shouldFail && err != nil {
				t.Errorf("Expected health check to succeed, but it failed: %v", err)
			}

			updatedCheck, err := db.GetHealthCheck("test-http-component")
			if err != nil {
				t.Fatalf("Failed to get updated health check: %v", err)
			}

			if updatedCheck.LastResult != tt.expectedResult {
				t.Errorf("Expected LastResult to be %s, got %s", tt.expectedResult, updatedCheck.LastResult)
			}

			if tt.shouldFail && updatedCheck.ConsecutiveFailures != 1 {
				t.Errorf("Expected ConsecutiveFailures to be 1, got %d", updatedCheck.ConsecutiveFailures)
			}

			if !tt.shouldFail && updatedCheck.ConsecutiveFailures != 0 {
				t.Errorf("Expected ConsecutiveFailures to be 0, got %d", updatedCheck.ConsecutiveFailures)
			}
		})
	}
}

func TestTCPHealthCheck(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer server.Close()

	mockProcessCheck := func(pid int) bool { return true }
	checker := NewChecker(db, mockProcessCheck)

	check := &database.HealthCheck{
		ComponentName:   "test-tcp-component",
		Type:            "tcp",
		Endpoint:        server.Listener.Addr().String(),
		IntervalSeconds: 30,
		TimeoutSeconds:  5,
		Retries:         3,
	}

	if err := db.UpsertHealthCheck(check); err != nil {
		t.Fatalf("Failed to insert health check: %v", err)
	}

	err := checker.RunHealthCheck(context.Background(), "test-tcp-component")
	if err != nil {
		t.Errorf("TCP health check failed: %v", err)
	}

	updatedCheck, err := db.GetHealthCheck("test-tcp-component")
	if err != nil {
		t.Fatalf("Failed to get updated health check: %v", err)
	}

	if updatedCheck.LastResult != "success" {
		t.Errorf("Expected LastResult to be success, got %s", updatedCheck.LastResult)
	}

	if updatedCheck.ConsecutiveFailures != 0 {
		t.Errorf("Expected ConsecutiveFailures to be 0, got %d", updatedCheck.ConsecutiveFailures)
	}
}

func TestTCPHealthCheckFailure(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	mockProcessCheck := func(pid int) bool { return true }
	checker := NewChecker(db, mockProcessCheck)

	check := &database.HealthCheck{
		ComponentName:   "test-tcp-failure",
		Type:            "tcp",
		Endpoint:        "localhost:99999",
		IntervalSeconds: 30,
		TimeoutSeconds:  1,
		Retries:         3,
	}

	if err := db.UpsertHealthCheck(check); err != nil {
		t.Fatalf("Failed to insert health check: %v", err)
	}

	err := checker.RunHealthCheck(context.Background(), "test-tcp-failure")
	if err == nil {
		t.Error("Expected TCP health check to fail, but it succeeded")
	}

	updatedCheck, err := db.GetHealthCheck("test-tcp-failure")
	if err != nil {
		t.Fatalf("Failed to get updated health check: %v", err)
	}

	if updatedCheck.LastResult != "failure" {
		t.Errorf("Expected LastResult to be failure, got %s", updatedCheck.LastResult)
	}

	if updatedCheck.ConsecutiveFailures != 1 {
		t.Errorf("Expected ConsecutiveFailures to be 1, got %d", updatedCheck.ConsecutiveFailures)
	}
}

func TestProcessHealthCheck(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	component := &database.Component{
		Name:       "test-process-component",
		Type:       "program",
		Hash:       "test-hash",
		Executable: "/bin/test",
	}

	if err := db.UpsertComponent(component); err != nil {
		t.Fatalf("Failed to insert component: %v", err)
	}

	status := &database.ComponentStatus{
		ComponentName: "test-process-component",
		Status:        "running",
		PID:           12345,
		LastCheckedAt: time.Now(),
	}

	if err := db.UpsertComponentStatus(status); err != nil {
		t.Fatalf("Failed to insert component status: %v", err)
	}

	tests := []struct {
		name           string
		processRunning bool
		shouldFail     bool
	}{
		{
			name:           "Process running",
			processRunning: true,
			shouldFail:     false,
		},
		{
			name:           "Process not running",
			processRunning: false,
			shouldFail:     true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockProcessCheck := func(pid int) bool { return tt.processRunning }
			checker := NewChecker(db, mockProcessCheck)

			check := &database.HealthCheck{
				ComponentName:   "test-process-component",
				Type:            "process",
				IntervalSeconds: 30,
				TimeoutSeconds:  5,
				Retries:         3,
			}

			if err := db.UpsertHealthCheck(check); err != nil {
				t.Fatalf("Failed to insert health check: %v", err)
			}

			err := checker.RunHealthCheck(context.Background(), "test-process-component")

			if tt.shouldFail && err == nil {
				t.Error("Expected process health check to fail, but it succeeded")
			}

			if !tt.shouldFail && err != nil {
				t.Errorf("Expected process health check to succeed, but it failed: %v", err)
			}
		})
	}
}

func TestConsecutiveFailures(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	mockProcessCheck := func(pid int) bool { return true }
	checker := NewChecker(db, mockProcessCheck)

	check := &database.HealthCheck{
		ComponentName:   "test-consecutive",
		Type:            "tcp",
		Endpoint:        "localhost:99999",
		IntervalSeconds: 1,
		TimeoutSeconds:  1,
		Retries:         3,
	}

	if err := db.UpsertHealthCheck(check); err != nil {
		t.Fatalf("Failed to insert health check: %v", err)
	}

	for i := 1; i <= 5; i++ {
		checker.RunHealthCheck(context.Background(), "test-consecutive")

		updatedCheck, err := db.GetHealthCheck("test-consecutive")
		if err != nil {
			t.Fatalf("Failed to get updated health check: %v", err)
		}

		if updatedCheck.ConsecutiveFailures != i {
			t.Errorf("After %d failures, expected ConsecutiveFailures to be %d, got %d", i, i, updatedCheck.ConsecutiveFailures)
		}
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer server.Close()

	check.Type = "tcp"
	check.Endpoint = server.Listener.Addr().String()
	db.UpsertHealthCheck(check)

	checker.RunHealthCheck(context.Background(), "test-consecutive")

	updatedCheck, err := db.GetHealthCheck("test-consecutive")
	if err != nil {
		t.Fatalf("Failed to get updated health check: %v", err)
	}

	if updatedCheck.ConsecutiveFailures != 0 {
		t.Errorf("After successful check, expected ConsecutiveFailures to be 0, got %d", updatedCheck.ConsecutiveFailures)
	}
}

func TestGetFailedComponents(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	mockProcessCheck := func(pid int) bool { return true }
	checker := NewChecker(db, mockProcessCheck)

	check1 := &database.HealthCheck{
		ComponentName:       "failed-component-1",
		Type:                "tcp",
		Endpoint:            "localhost:99999",
		IntervalSeconds:     30,
		TimeoutSeconds:      1,
		Retries:             3,
		ConsecutiveFailures: 5,
		LastResult:          "failure",
	}

	check2 := &database.HealthCheck{
		ComponentName:       "healthy-component",
		Type:                "tcp",
		Endpoint:            "localhost:8080",
		IntervalSeconds:     30,
		TimeoutSeconds:      5,
		Retries:             3,
		ConsecutiveFailures: 0,
		LastResult:          "success",
	}

	check3 := &database.HealthCheck{
		ComponentName:       "failed-component-2",
		Type:                "tcp",
		Endpoint:            "localhost:99998",
		IntervalSeconds:     30,
		TimeoutSeconds:      1,
		Retries:             2,
		ConsecutiveFailures: 3,
		LastResult:          "failure",
	}

	for _, component := range []string{"failed-component-1", "healthy-component", "failed-component-2"} {
		comp := &database.Component{
			Name:       component,
			Type:       "program",
			Hash:       "test-hash",
			Executable: "/bin/test",
		}
		if err := db.UpsertComponent(comp); err != nil {
			t.Fatalf("Failed to insert component: %v", err)
		}
	}

	if err := db.UpsertHealthCheck(check1); err != nil {
		t.Fatalf("Failed to insert health check: %v", err)
	}
	if err := db.UpsertHealthCheck(check2); err != nil {
		t.Fatalf("Failed to insert health check: %v", err)
	}
	if err := db.UpsertHealthCheck(check3); err != nil {
		t.Fatalf("Failed to insert health check: %v", err)
	}

	failed, err := checker.GetFailedComponents()
	if err != nil {
		t.Fatalf("GetFailedComponents failed: %v", err)
	}

	if len(failed) != 2 {
		t.Errorf("Expected 2 failed components, got %d", len(failed))
	}

	foundNames := make(map[string]bool)
	for _, check := range failed {
		foundNames[check.ComponentName] = true
	}

	if !foundNames["failed-component-1"] {
		t.Error("Expected to find failed-component-1 in failed components")
	}
	if !foundNames["failed-component-2"] {
		t.Error("Expected to find failed-component-2 in failed components")
	}
	if foundNames["healthy-component"] {
		t.Error("Did not expect to find healthy-component in failed components")
	}
}

func TestResetFailureCount(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	mockProcessCheck := func(pid int) bool { return true }
	checker := NewChecker(db, mockProcessCheck)

	check := &database.HealthCheck{
		ComponentName:       "test-reset",
		Type:                "tcp",
		Endpoint:            "localhost:99999",
		IntervalSeconds:     30,
		TimeoutSeconds:      1,
		Retries:             3,
		ConsecutiveFailures: 5,
		LastResult:          "failure",
	}

	if err := db.UpsertHealthCheck(check); err != nil {
		t.Fatalf("Failed to insert health check: %v", err)
	}

	if err := checker.ResetFailureCount("test-reset"); err != nil {
		t.Fatalf("ResetFailureCount failed: %v", err)
	}

	updatedCheck, err := db.GetHealthCheck("test-reset")
	if err != nil {
		t.Fatalf("Failed to get updated health check: %v", err)
	}

	if updatedCheck.ConsecutiveFailures != 0 {
		t.Errorf("Expected ConsecutiveFailures to be 0 after reset, got %d", updatedCheck.ConsecutiveFailures)
	}

	if updatedCheck.LastResult != "reset" {
		t.Errorf("Expected LastResult to be 'reset', got %s", updatedCheck.LastResult)
	}
}

func TestShouldRunCheck(t *testing.T) {
	db, cleanup := setupTestDB(t)
	defer cleanup()

	mockProcessCheck := func(pid int) bool { return true }
	checker := NewChecker(db, mockProcessCheck)

	now := time.Now()
	past := now.Add(-1 * time.Minute)
	future := now.Add(1 * time.Minute)

	tests := []struct {
		name         string
		lastCheckAt  *time.Time
		intervalSecs int
		shouldRun    bool
	}{
		{
			name:         "Never checked",
			lastCheckAt:  nil,
			intervalSecs: 30,
			shouldRun:    true,
		},
		{
			name:         "Checked recently",
			lastCheckAt:  &now,
			intervalSecs: 60,
			shouldRun:    false,
		},
		{
			name:         "Time to check again",
			lastCheckAt:  &past,
			intervalSecs: 30,
			shouldRun:    true,
		},
		{
			name:         "Not time yet",
			lastCheckAt:  &future,
			intervalSecs: 30,
			shouldRun:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			check := &database.HealthCheck{
				ComponentName:   "test-timing",
				Type:            "tcp",
				Endpoint:        "localhost:8080",
				IntervalSeconds: tt.intervalSecs,
				LastCheckAt:     tt.lastCheckAt,
			}

			result := checker.shouldRunCheck(check)
			if result != tt.shouldRun {
				t.Errorf("Expected shouldRunCheck to be %v, got %v", tt.shouldRun, result)
			}
		})
	}
}
