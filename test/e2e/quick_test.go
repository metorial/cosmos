package e2e

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestQuickDeployment(t *testing.T) {
	// Wait for agents to connect
	t.Log("Waiting for agents to connect...")
	err := client.WaitForAgents(3, 30*time.Second)
	require.NoError(t, err, "Agents should connect within 30 seconds")

	// Create a simple script deployment
	script := `#!/bin/bash
echo "Quick test script"
date
sleep 30
`
	scriptHash := hashString(script)

	config := ConfigurationRequest{
		Components: []ComponentConfig{
			{
				Type:    "script",
				Name:    "quick-test",
				Hash:    scriptHash,
				Tags:    []string{"all"},
				Handler: "agent",
				Content: script,
				Managed: true,
			},
		},
	}

	t.Log("Creating deployment...")
	deployment, err := client.CreateDeployment(config)
	require.NoError(t, err)
	require.NotNil(t, deployment)
	t.Logf("Deployment created: %s", deployment.ID)

	// Wait for deployment to complete
	t.Log("Waiting for deployment to complete...")
	err = client.WaitForDeploymentComplete(deployment.ID, 2*time.Minute)
	require.NoError(t, err, "Deployment should complete")

	// Wait for component deployments to reach running state
	t.Log("Waiting for component deployments to reach running state...")
	err = client.WaitForComponentDeployments("quick-test", 3, "running", 2*time.Minute)
	require.NoError(t, err, "Component should be deployed to 3 agents")

	t.Log("Quick test passed! Deployments are working.")
}
