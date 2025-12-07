package e2e

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var (
	client *Client
)

func TestMain(m *testing.M) {
	controllerURL := os.Getenv("COSMOS_CONTROLLER_URL")
	if controllerURL == "" {
		controllerURL = "http://localhost:8090"
	}

	client = NewClient(controllerURL)

	fmt.Println("Waiting for controller to be healthy...")
	if err := client.WaitForHealth(); err != nil {
		fmt.Printf("Controller health check failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("Controller is healthy")

	fmt.Println("Waiting for agents to connect...")
	if err := client.WaitForAgents(3, 60*time.Second); err != nil {
		fmt.Printf("Agents did not connect: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("All agents connected")

	os.Exit(m.Run())
}

func TestHealthCheck(t *testing.T) {
	agents, err := client.ListAgents()
	require.NoError(t, err)

	assert.GreaterOrEqual(t, len(agents), 3, "Should have at least 3 agents")

	for _, agent := range agents {
		assert.True(t, agent.Online, "Agent %s should be online", agent.Hostname)
		assert.NotEmpty(t, agent.AgentVersion, "Agent should have version")
		assert.WithinDuration(t, time.Now(), agent.LastHeartbeat, 30*time.Second, "Agent heartbeat should be recent")
	}
}

func TestSimpleScriptDeployment(t *testing.T) {
	script := `#!/bin/bash
echo "Hello from Cosmos test script"
date
sleep 30
`
	scriptHash := hashString(script)

	config := ConfigurationRequest{
		Components: []ComponentConfig{
			{
				Type:    "script",
				Name:    "test-script",
				Hash:    scriptHash,
				Tags:    []string{"all"},
				Handler: "agent",
				Content: script,
				Managed: true,
			},
		},
	}

	deployment, err := client.CreateDeployment(config)
	require.NoError(t, err)
	assert.NotNil(t, deployment)
	assert.Equal(t, "pending", deployment.Status)

	err = client.WaitForDeploymentComplete(deployment.ID, 60*time.Second)
	require.NoError(t, err)

	err = client.WaitForComponentDeployments("test-script", 3, "running", 60*time.Second)
	require.NoError(t, err)

	deployments, err := client.GetComponentDeployments("test-script")
	require.NoError(t, err)
	assert.Len(t, deployments, 3, "Script should be deployed to 3 agents")

	for _, dep := range deployments {
		assert.Equal(t, "running", dep.Status, "Component should be running on %s", dep.NodeHostname)
		assert.NotNil(t, dep.PID, "Should have PID")
	}
}

func TestComponentUpdate(t *testing.T) {
	scriptV1 := `#!/bin/bash
echo "Version 1"
sleep 60
`
	hashV1 := hashString(scriptV1)

	configV1 := ConfigurationRequest{
		Components: []ComponentConfig{
			{
				Type:    "script",
				Name:    "test-update-script",
				Hash:    hashV1,
				Tags:    []string{"all"},
				Handler: "agent",
				Content: scriptV1,
				Managed: true,
			},
		},
	}

	deployment1, err := client.CreateDeployment(configV1)
	require.NoError(t, err)

	err = client.WaitForDeploymentComplete(deployment1.ID, 60*time.Second)
	require.NoError(t, err)

	err = client.WaitForComponentDeployments("test-update-script", 3, "running", 60*time.Second)
	require.NoError(t, err)

	scriptV2 := `#!/bin/bash
echo "Version 2 - Updated!"
sleep 60
`
	hashV2 := hashString(scriptV2)

	configV2 := ConfigurationRequest{
		Components: []ComponentConfig{
			{
				Type:    "script",
				Name:    "test-update-script",
				Hash:    hashV2,
				Tags:    []string{"all"},
				Handler: "agent",
				Content: scriptV2,
				Managed: true,
			},
		},
	}

	deployment2, err := client.CreateDeployment(configV2)
	require.NoError(t, err)

	err = client.WaitForDeploymentComplete(deployment2.ID, 60*time.Second)
	require.NoError(t, err)

	err = client.WaitForComponentDeployments("test-update-script", 3, "running", 60*time.Second)
	require.NoError(t, err)

	components, err := client.ListComponents()
	require.NoError(t, err)

	var testComponent *Component
	for _, comp := range components {
		if comp.Name == "test-update-script" {
			testComponent = &comp
			break
		}
	}

	require.NotNil(t, testComponent, "Component should exist")
	assert.Equal(t, hashV2, testComponent.Hash, "Component should have updated hash")
}

func TestComponentRemoval(t *testing.T) {
	script := `#!/bin/bash
echo "This will be removed"
sleep 300
`
	scriptHash := hashString(script)

	configWithComponent := ConfigurationRequest{
		Components: []ComponentConfig{
			{
				Type:    "script",
				Name:    "test-removal-script",
				Hash:    scriptHash,
				Tags:    []string{"all"},
				Handler: "agent",
				Content: script,
				Managed: true,
			},
		},
	}

	deployment1, err := client.CreateDeployment(configWithComponent)
	require.NoError(t, err)

	err = client.WaitForDeploymentComplete(deployment1.ID, 60*time.Second)
	require.NoError(t, err)

	err = client.WaitForComponentDeployments("test-removal-script", 3, "running", 60*time.Second)
	require.NoError(t, err)

	configWithoutComponent := ConfigurationRequest{
		Components: []ComponentConfig{},
	}

	deployment2, err := client.CreateDeployment(configWithoutComponent)
	require.NoError(t, err)

	err = client.WaitForDeploymentComplete(deployment2.ID, 60*time.Second)
	require.NoError(t, err)

	time.Sleep(10 * time.Second)

	components, err := client.ListComponents()
	require.NoError(t, err)

	for _, comp := range components {
		assert.NotEqual(t, "test-removal-script", comp.Name, "Removed component should not be in list")
	}
}

func TestMultipleComponents(t *testing.T) {
	script1 := `#!/bin/bash
echo "Script 1"
sleep 120
`
	script2 := `#!/bin/bash
echo "Script 2"
sleep 120
`
	script3 := `#!/bin/bash
echo "Script 3"
sleep 120
`

	config := ConfigurationRequest{
		Components: []ComponentConfig{
			{
				Type:    "script",
				Name:    "multi-test-1",
				Hash:    hashString(script1),
				Tags:    []string{"all"},
				Handler: "agent",
				Content: script1,
				Managed: true,
			},
			{
				Type:    "script",
				Name:    "multi-test-2",
				Hash:    hashString(script2),
				Tags:    []string{"all"},
				Handler: "agent",
				Content: script2,
				Managed: true,
			},
			{
				Type:    "script",
				Name:    "multi-test-3",
				Hash:    hashString(script3),
				Tags:    []string{"all"},
				Handler: "agent",
				Content: script3,
				Managed: true,
			},
		},
	}

	deployment, err := client.CreateDeployment(config)
	require.NoError(t, err)

	err = client.WaitForDeploymentComplete(deployment.ID, 90*time.Second)
	require.NoError(t, err)

	for _, compName := range []string{"multi-test-1", "multi-test-2", "multi-test-3"} {
		err = client.WaitForComponentDeployments(compName, 3, "running", 60*time.Second)
		assert.NoError(t, err, "Component %s should be running on all agents", compName)
	}

	components, err := client.ListComponents()
	require.NoError(t, err)
	assert.GreaterOrEqual(t, len(components), 3, "Should have at least 3 components")
}

func TestConcurrentDeployments(t *testing.T) {
	script1 := `#!/bin/bash
echo "Concurrent 1"
sleep 90
`
	script2 := `#!/bin/bash
echo "Concurrent 2"
sleep 90
`

	config1 := ConfigurationRequest{
		Components: []ComponentConfig{
			{
				Type:    "script",
				Name:    "concurrent-1",
				Hash:    hashString(script1),
				Tags:    []string{"all"},
				Handler: "agent",
				Content: script1,
				Managed: true,
			},
		},
	}

	config2 := ConfigurationRequest{
		Components: []ComponentConfig{
			{
				Type:    "script",
				Name:    "concurrent-2",
				Hash:    hashString(script2),
				Tags:    []string{"all"},
				Handler: "agent",
				Content: script2,
				Managed: true,
			},
		},
	}

	deployment1, err := client.CreateDeployment(config1)
	require.NoError(t, err)

	deployment2, err := client.CreateDeployment(config2)
	require.NoError(t, err)

	err = client.WaitForDeploymentComplete(deployment1.ID, 60*time.Second)
	assert.NoError(t, err)

	err = client.WaitForDeploymentComplete(deployment2.ID, 60*time.Second)
	assert.NoError(t, err)

	err = client.WaitForComponentDeployments("concurrent-1", 3, "running", 60*time.Second)
	assert.NoError(t, err)

	err = client.WaitForComponentDeployments("concurrent-2", 3, "running", 60*time.Second)
	assert.NoError(t, err)
}

func hashString(s string) string {
	h := sha256.New()
	h.Write([]byte(s))
	return hex.EncodeToString(h.Sum(nil))
}
