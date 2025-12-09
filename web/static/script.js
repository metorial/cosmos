// API Base URL
const API_BASE = '/api/v1';

// State
let currentTab = 'overview';
let refreshInterval = null;

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    loadOverview();
    startAutoRefresh();
});

// Auto-refresh every 10 seconds
function startAutoRefresh() {
    refreshInterval = setInterval(() => {
        switch(currentTab) {
            case 'overview':
                loadOverview();
                break;
            case 'nodes':
                loadNodes();
                break;
            case 'components':
                loadComponents();
                break;
            case 'deployments':
                loadDeployments();
                break;
            case 'logs':
                loadComponentLogs();
                break;
        }
    }, 10000);
}

// Tab Switching
function switchTab(tabName) {
    currentTab = tabName;

    // Update tab buttons
    document.querySelectorAll('.tab').forEach(tab => {
        tab.classList.remove('active');
    });
    document.querySelector(`.tab[data-tab="${tabName}"]`).classList.add('active');

    // Update tab content
    document.querySelectorAll('.tab-content').forEach(content => {
        content.classList.remove('active');
    });
    document.getElementById(`${tabName}-tab`).classList.add('active');

    // Load data for the tab
    switch(tabName) {
        case 'overview':
            loadOverview();
            break;
        case 'nodes':
            loadNodes();
            break;
        case 'components':
            loadComponents();
            break;
        case 'deployments':
            loadDeployments();
            break;
        case 'logs':
            loadLogsTab();
            break;
    }
}

// Load Overview
async function loadOverview() {
    try {
        const [nodes, components, deployments] = await Promise.all([
            fetch(`${API_BASE}/nodes`).then(r => r.json()),
            fetch(`${API_BASE}/components`).then(r => r.json()),
            fetch(`${API_BASE}/deployments?limit=10`).then(r => r.json())
        ]);

        // Update stats
        const onlineNodes = nodes.filter(n => n.online).length;
        document.getElementById('total-nodes').textContent = nodes.length;
        document.getElementById('online-nodes').textContent = onlineNodes;
        document.getElementById('total-components').textContent = components.length;
        document.getElementById('recent-deployments').textContent = deployments.length;

        // Update recent deployments list
        const list = document.getElementById('recent-deployments-list');
        if (deployments.length === 0) {
            list.innerHTML = '<div class="empty-state">No deployments yet</div>';
        } else {
            list.innerHTML = deployments.map(d => `
                <div class="deployment-card">
                    <div class="deployment-header">
                        <span class="deployment-id">${d.id}</span>
                        <span class="status status-${d.status}">${d.status}</span>
                    </div>
                    <div class="deployment-meta">
                        Created: ${formatDate(d.created_at)}
                        ${d.completed_at ? `• Completed: ${formatDate(d.completed_at)}` : ''}
                        ${d.error_message ? `<br><span style="color: var(--error-red)">${d.error_message}</span>` : ''}
                    </div>
                </div>
            `).join('');
        }
    } catch (error) {
        console.error('Failed to load overview:', error);
    }
}

// Load Nodes
async function loadNodes() {
    try {
        const nodes = await fetch(`${API_BASE}/nodes`).then(r => r.json());
        const tbody = document.getElementById('nodes-table');

        if (nodes.length === 0) {
            tbody.innerHTML = '<tr><td colspan="6" class="empty-state">No nodes found</td></tr>';
            return;
        }

        tbody.innerHTML = nodes.map(node => `
            <tr>
                <td>${escapeHtml(node.hostname)}</td>
                <td>${escapeHtml(node.ip || '-')}</td>
                <td><span class="status status-${node.online ? 'online' : 'offline'}">${node.online ? 'Online' : 'Offline'}</span></td>
                <td>${node.has_agent ? '✓' : '-'}</td>
                <td>${node.tags ? node.tags.map(t => `<span class="tag">${escapeHtml(t)}</span>`).join('') : '-'}</td>
                <td>${node.last_seen ? formatDate(node.last_seen) : '-'}</td>
            </tr>
        `).join('');
    } catch (error) {
        console.error('Failed to load nodes:', error);
        document.getElementById('nodes-table').innerHTML = '<tr><td colspan="6" class="error-message active">Failed to load nodes</td></tr>';
    }
}

// Load Components
async function loadComponents() {
    try {
        const components = await fetch(`${API_BASE}/components`).then(r => r.json());
        const tbody = document.getElementById('components-table');

        if (components.length === 0) {
            tbody.innerHTML = '<tr><td colspan="6" class="empty-state">No components found</td></tr>';
            return;
        }

        tbody.innerHTML = components.map(comp => `
            <tr>
                <td>${escapeHtml(comp.name)}</td>
                <td>${escapeHtml(comp.type)}</td>
                <td>${escapeHtml(comp.handler)}</td>
                <td>${comp.tags ? comp.tags.map(t => `<span class="tag">${escapeHtml(t)}</span>`).join('') : '-'}</td>
                <td>${comp.managed ? '✓' : '-'}</td>
                <td>${formatDate(comp.updated_at)}</td>
            </tr>
        `).join('');
    } catch (error) {
        console.error('Failed to load components:', error);
        document.getElementById('components-table').innerHTML = '<tr><td colspan="6" class="error-message active">Failed to load components</td></tr>';
    }
}

// Load Deployments
async function loadDeployments() {
    try {
        const deployments = await fetch(`${API_BASE}/deployments?limit=50`).then(r => r.json());
        const tbody = document.getElementById('deployments-table');

        if (deployments.length === 0) {
            tbody.innerHTML = '<tr><td colspan="6" class="empty-state">No deployments found</td></tr>';
            return;
        }

        tbody.innerHTML = deployments.map(d => `
            <tr>
                <td style="font-family: monospace; font-size: 12px;">${d.id.substring(0, 8)}...</td>
                <td><span class="status status-${d.status}">${d.status}</span></td>
                <td>${formatDate(d.created_at)}</td>
                <td>${d.started_at ? formatDate(d.started_at) : '-'}</td>
                <td>${d.completed_at ? formatDate(d.completed_at) : '-'}</td>
                <td><button class="btn btn-small btn-secondary" onclick="showDeploymentDetails('${d.id}')">Details</button></td>
            </tr>
        `).join('');
    } catch (error) {
        console.error('Failed to load deployments:', error);
        document.getElementById('deployments-table').innerHTML = '<tr><td colspan="6" class="error-message active">Failed to load deployments</td></tr>';
    }
}

// Show Deployment Details
async function showDeploymentDetails(deploymentId) {
    try {
        const response = await fetch(`${API_BASE}/deployments/${deploymentId}`);
        const data = await response.json();

        const deployment = data.deployment;
        const logs = data.logs || [];

        let config = {};
        try {
            config = JSON.parse(deployment.configuration);
        } catch (e) {
            config = deployment.configuration;
        }

        // Group logs by node hostname
        const logsByNode = {};
        logs.reverse().forEach(log => {
            const hostname = log.node_hostname || 'controller';
            if (!logsByNode[hostname]) {
                logsByNode[hostname] = [];
            }
            logsByNode[hostname].push(log);
        });

        // Generate logs HTML grouped by node
        let logsHtml = '';
        if (logs.length > 0) {
            const nodeHostnames = Object.keys(logsByNode).sort();
            logsHtml = nodeHostnames.map(hostname => `
                <div class="deployment-log-node-section">
                    <h4 class="deployment-log-node-header">${escapeHtml(hostname)} (${logsByNode[hostname].length} entries)</h4>
                    <div class="deployment-log-entries">
                        ${logsByNode[hostname].map(log => `
                            <div class="log-entry ${log.status === 'success' ? 'success' : log.status === 'failed' ? 'error' : ''}">
                                <div class="log-timestamp">${formatDate(log.created_at)}</div>
                                <div>${escapeHtml(log.operation)} - ${escapeHtml(log.message || '')}</div>
                                ${log.component_name ? `<div style="font-size: 11px; color: var(--text-gray);">Component: ${escapeHtml(log.component_name)}</div>` : ''}
                            </div>
                        `).join('')}
                    </div>
                </div>
            `).join('');
        }

        const detailsHtml = `
            <div class="detail-row">
                <div class="detail-label">ID</div>
                <div class="detail-value" style="font-family: monospace;">${deployment.id}</div>
            </div>
            <div class="detail-row">
                <div class="detail-label">Status</div>
                <div class="detail-value"><span class="status status-${deployment.status}">${deployment.status}</span></div>
            </div>
            <div class="detail-row">
                <div class="detail-label">Created</div>
                <div class="detail-value">${formatDate(deployment.created_at)}</div>
            </div>
            ${deployment.started_at ? `
            <div class="detail-row">
                <div class="detail-label">Started</div>
                <div class="detail-value">${formatDate(deployment.started_at)}</div>
            </div>
            ` : ''}
            ${deployment.completed_at ? `
            <div class="detail-row">
                <div class="detail-label">Completed</div>
                <div class="detail-value">${formatDate(deployment.completed_at)}</div>
            </div>
            ` : ''}
            ${deployment.error_message ? `
            <div class="detail-row">
                <div class="detail-label">Error</div>
                <div class="detail-value" style="color: var(--error-red);">${escapeHtml(deployment.error_message)}</div>
            </div>
            ` : ''}
            <div class="detail-row">
                <div class="detail-label">Configuration</div>
                <div class="detail-value">
                    <div class="config-block">
                        <pre>${JSON.stringify(config, null, 2)}</pre>
                    </div>
                </div>
            </div>
            ${logs.length > 0 ? `
            <div class="detail-row">
                <div class="detail-label">Logs</div>
                <div class="detail-value">
                    ${logsHtml}
                </div>
            </div>
            ` : ''}
        `;

        document.getElementById('deployment-details').innerHTML = detailsHtml;
        document.getElementById('details-modal').classList.add('active');
    } catch (error) {
        console.error('Failed to load deployment details:', error);
        alert('Failed to load deployment details');
    }
}

function closeDetailsModal() {
    document.getElementById('details-modal').classList.remove('active');
}

// Modal Functions
function showDeployModal() {
    document.getElementById('deploy-modal').classList.add('active');
    document.getElementById('config-text').value = '';
    document.getElementById('config-file').value = '';
    document.getElementById('deploy-error').classList.remove('active');
}

function closeDeployModal() {
    document.getElementById('deploy-modal').classList.remove('active');
}

function loadConfigFile() {
    const file = document.getElementById('config-file').files[0];
    if (file) {
        const reader = new FileReader();
        reader.onload = (e) => {
            document.getElementById('config-text').value = e.target.result;
        };
        reader.readAsText(file);
    }
}

async function createDeployment() {
    const configText = document.getElementById('config-text').value.trim();
    const errorDiv = document.getElementById('deploy-error');

    if (!configText) {
        errorDiv.textContent = 'Please provide a configuration';
        errorDiv.classList.add('active');
        return;
    }

    let config;
    try {
        config = JSON.parse(configText);
    } catch (e) {
        errorDiv.textContent = 'Invalid JSON: ' + e.message;
        errorDiv.classList.add('active');
        return;
    }

    try {
        const response = await fetch(`${API_BASE}/deployments`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(config)
        });

        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to create deployment');
        }

        const result = await response.json();
        closeDeployModal();

        // Switch to deployments tab and refresh
        switchTab('deployments');

        // Show success message
        alert(`Deployment ${result.id} created successfully!`);
    } catch (error) {
        errorDiv.textContent = 'Failed to create deployment: ' + error.message;
        errorDiv.classList.add('active');
    }
}

// Utility Functions
function formatDate(dateString) {
    if (!dateString) return '-';
    const date = new Date(dateString);
    return date.toLocaleString();
}

function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Load Logs Tab
async function loadLogsTab() {
    try {
        const components = await fetch(`${API_BASE}/components`).then(r => r.json());
        const select = document.getElementById('log-component-select');

        // Update dropdown with script components only
        const scriptComponents = components.filter(c => c.type === 'script');
        const currentSelection = select.value;

        select.innerHTML = '<option value="">-- Select a component --</option>';
        scriptComponents.forEach(comp => {
            const option = document.createElement('option');
            option.value = comp.name;
            option.textContent = comp.name;
            if (comp.name === currentSelection) {
                option.selected = true;
            }
            select.appendChild(option);
        });

        // Load logs if a component is selected
        if (currentSelection) {
            loadComponentLogs();
        }
    } catch (error) {
        console.error('Failed to load components for logs:', error);
    }
}

// Load Component Logs
async function loadComponentLogs() {
    const componentName = document.getElementById('log-component-select').value;
    const logsContainer = document.getElementById('logs-container');

    if (!componentName) {
        logsContainer.innerHTML = '<div class="no-logs">Select a component to view logs</div>';
        return;
    }

    try {
        const logs = await fetch(`${API_BASE}/logs/${componentName}?limit=1000`).then(r => r.json());

        if (logs.length === 0) {
            logsContainer.innerHTML = '<div class="no-logs">No logs available for this component</div>';
            return;
        }

        // Group logs by node hostname
        const logsByNode = {};
        logs.forEach(log => {
            if (!logsByNode[log.node_hostname]) {
                logsByNode[log.node_hostname] = [];
            }
            logsByNode[log.node_hostname].push(log);
        });

        // Render logs grouped by node
        let html = '';
        Object.keys(logsByNode).sort().forEach(hostname => {
            const nodeLogs = logsByNode[hostname];
            html += `
                <div class="log-node-section">
                    <h3 class="log-node-header">${escapeHtml(hostname)} (${nodeLogs.length} log entries)</h3>
                    <div class="log-entries">
                        ${nodeLogs.map(log => `
                            <div class="log-entry">
                                <span class="log-timestamp">${formatDate(log.timestamp)}</span>
                                <pre class="log-data">${escapeHtml(log.log_data)}</pre>
                            </div>
                        `).join('')}
                    </div>
                </div>
            `;
        });

        logsContainer.innerHTML = html;
    } catch (error) {
        console.error('Failed to load component logs:', error);
        logsContainer.innerHTML = '<div class="error-message active">Failed to load logs</div>';
    }
}

// Close modals when clicking outside
window.onclick = function(event) {
    const deployModal = document.getElementById('deploy-modal');
    const detailsModal = document.getElementById('details-modal');

    if (event.target === deployModal) {
        closeDeployModal();
    }
    if (event.target === detailsModal) {
        closeDetailsModal();
    }
}
