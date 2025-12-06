package health

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"time"

	"github.com/metorial/fleet/cosmos/internal/agent/database"
	log "github.com/sirupsen/logrus"
)

type Checker struct {
	db             *database.AgentDB
	httpClient     *http.Client
	checkProcessFn func(int) bool
}

func NewChecker(db *database.AgentDB, checkProcessFn func(int) bool) *Checker {
	return &Checker{
		db: db,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		checkProcessFn: checkProcessFn,
	}
}

func (c *Checker) RunHealthCheck(ctx context.Context, componentName string) error {
	check, err := c.db.GetHealthCheck(componentName)
	if err != nil {
		return fmt.Errorf("failed to get health check: %w", err)
	}

	if check == nil {
		return nil
	}

	var result string
	var checkErr error

	switch check.Type {
	case "http":
		checkErr = c.performHTTPCheck(ctx, check.Endpoint, check.TimeoutSeconds)
	case "tcp":
		checkErr = c.performTCPCheck(ctx, check.Endpoint, check.TimeoutSeconds)
	case "process":
		checkErr = c.performProcessCheck(componentName)
	default:
		return fmt.Errorf("unsupported health check type: %s", check.Type)
	}

	now := time.Now()
	check.LastCheckAt = &now

	if checkErr != nil {
		check.LastResult = "failure"
		check.ConsecutiveFailures++
		result = fmt.Sprintf("Health check failed: %v", checkErr)
		log.WithFields(log.Fields{
			"component":            componentName,
			"type":                 check.Type,
			"consecutive_failures": check.ConsecutiveFailures,
		}).Warn(result)
	} else {
		check.LastResult = "success"
		check.ConsecutiveFailures = 0
		result = "Health check passed"
		log.WithFields(log.Fields{
			"component": componentName,
			"type":      check.Type,
		}).Debug(result)
	}

	if err := c.db.UpsertHealthCheck(check); err != nil {
		return fmt.Errorf("failed to update health check: %w", err)
	}

	return checkErr
}

func (c *Checker) performHTTPCheck(ctx context.Context, endpoint string, timeoutSeconds int) error {
	if timeoutSeconds > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(timeoutSeconds)*time.Second)
		defer cancel()
	}

	req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("unhealthy status code: %d", resp.StatusCode)
	}

	return nil
}

func (c *Checker) performTCPCheck(ctx context.Context, endpoint string, timeoutSeconds int) error {
	timeout := time.Duration(timeoutSeconds) * time.Second
	if timeoutSeconds <= 0 {
		timeout = 5 * time.Second
	}

	dialer := &net.Dialer{
		Timeout: timeout,
	}

	conn, err := dialer.DialContext(ctx, "tcp", endpoint)
	if err != nil {
		return fmt.Errorf("connection failed: %w", err)
	}
	defer conn.Close()

	return nil
}

func (c *Checker) performProcessCheck(componentName string) error {
	status, err := c.db.GetComponentStatus(componentName)
	if err != nil {
		return fmt.Errorf("failed to get component status: %w", err)
	}

	if status.Status != "running" {
		return fmt.Errorf("component is not running (status: %s)", status.Status)
	}

	if status.PID <= 0 {
		return fmt.Errorf("invalid PID: %d", status.PID)
	}

	if !c.checkProcessFn(status.PID) {
		return fmt.Errorf("process %d is not running", status.PID)
	}

	return nil
}

func (c *Checker) CheckAllComponents(ctx context.Context) error {
	components, err := c.db.GetAllComponents()
	if err != nil {
		return fmt.Errorf("failed to get components: %w", err)
	}

	for _, component := range components {
		check, err := c.db.GetHealthCheck(component.Name)
		if err != nil {
			log.WithError(err).WithField("component", component.Name).Warn("Failed to get health check")
			continue
		}

		if check == nil {
			continue
		}

		if !c.shouldRunCheck(check) {
			continue
		}

		if err := c.RunHealthCheck(ctx, component.Name); err != nil {
			log.WithError(err).WithField("component", component.Name).Debug("Health check failed")
		}
	}

	return nil
}

func (c *Checker) shouldRunCheck(check *database.HealthCheck) bool {
	if check.LastCheckAt == nil {
		return true
	}

	interval := time.Duration(check.IntervalSeconds) * time.Second
	nextCheck := check.LastCheckAt.Add(interval)
	return time.Now().After(nextCheck)
}

func (c *Checker) GetFailedComponents() ([]*database.HealthCheck, error) {
	components, err := c.db.GetAllComponents()
	if err != nil {
		return nil, fmt.Errorf("failed to get components: %w", err)
	}

	var failed []*database.HealthCheck

	for _, component := range components {
		check, err := c.db.GetHealthCheck(component.Name)
		if err != nil {
			log.WithError(err).WithField("component", component.Name).Warn("Failed to get health check")
			continue
		}

		if check == nil {
			continue
		}

		if check.ConsecutiveFailures >= check.Retries && check.Retries > 0 {
			failed = append(failed, check)
		}
	}

	return failed, nil
}

func (c *Checker) ResetFailureCount(componentName string) error {
	check, err := c.db.GetHealthCheck(componentName)
	if err != nil {
		return fmt.Errorf("failed to get health check: %w", err)
	}

	if check == nil {
		return nil
	}

	check.ConsecutiveFailures = 0
	check.LastResult = "reset"

	return c.db.UpsertHealthCheck(check)
}
