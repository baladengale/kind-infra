# MCP Gateway Configuration Plan

## Overview
Expose kagent-controller as an MCP server through AgentGateway with `/mcp` endpoint, enable local MCP client configuration, and implement comprehensive chainsaw testing.

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   MCP Client    │    │   AgentGateway   │    │  kagent-controller  │
│ (Cursor/Claude) │◄──►│   (Gateway API)  │◄──►│   (MCP Server)      │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
     HTTP/MCP                /mcp route              port 8083
```

## Phase 1: Gateway Configuration

### 1.1 HTTPRoute for MCP Endpoint

**File**: `manifests/kagent-mcp-route.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kagent-mcp
  namespace: kagent
  labels:
    app.kubernetes.io/managed-by: kind-infra
spec:
  parentRefs:
    - name: kind-infra
      namespace: agentgateway-system
  hostnames:
    - "kagent-mcp.${DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - name: kagent-controller
          port: 8083
```

### 1.2 Alternative: Gateway-Level Configuration

**File**: Update `manifests/gateway.yaml` to include MCP-specific listener

```yaml
# Add to existing Gateway spec
  - name: mcp
    port: 8083
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            kagent.dev/mcp: "true"
```

## Phase 2: Local MCP Configuration

### 2.1 Claude Code Configuration

```bash
# Add kagent as MCP server
claude mcp add --transport http kagent-mcp https://kagent-mcp.internal/mcp

# Or project-specific
claude mcp add --transport http --scope project kagent-mcp https://kagent-mcp.internal/mcp
```

### 2.2 Cursor IDE Configuration

**File**: `~/.cursor/mcp.json` or Cursor settings

```json
{
  "mcpServers": {
    "kagent-agents": {
      "url": "https://kagent-mcp.internal/mcp"
    }
  }
}
```

### 2.3 MCP Client Tools Available

- **list_agents**: Discover all available kagent agents
- **invoke_agent**: Execute specific agent with input and sessionID

## Phase 3: Chainsaw Test Suite

### 3.1 Test Structure

**Directory**: `tests/kagent-mcp/`

```
tests/kagent-mcp/
├── chainsaw-test.yaml
├── agent-test.yaml
└── mcp-validation/
    ├── list-agents-test.yaml
    ├── invoke-agent-test.yaml
    └── endpoint-availability-test.yaml
```

### 3.2 Main Test File

**File**: `tests/kagent-mcp/chainsaw-test.yaml`

```yaml
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata:
  name: kagent-mcp-gateway
spec:
  description: >-
    End-to-end MCP server validation: HTTPRoute creation, gateway routing,
    MCP endpoint availability, and tool invocation (list_agents, invoke_agent)
  steps:
    - name: verify-kagent-running
      description: Ensure kagent controller is deployed and ready
      try:
        - script:
            content: |
                kubectl get pods -n kagent -l app.kubernetes.io/component=controller
                kubectl wait --for=condition=Ready pod -n kagent -l app.kubernetes.io/component=controller --timeout=60s

    - name: create-mcp-http-route
      description: Deploy HTTPRoute for /mcp endpoint through gateway
      try:
        - apply:
            file: mcp-validation/mcp-route.yaml
        - assert:
            resource:
              apiVersion: gateway.networking.k8s.io/v1
              kind: HTTPRoute
              metadata:
                namespace: kagent
                name: kagent-mcp

    - name: verify-route-accepted
      description: Ensure HTTPRoute is accepted by gateway
      try:
        - script:
            content: |
                for _ in $(seq 1 30); do
                  st="$(kubectl -n kagent get httproute kagent-mcp -o json \
                    | jq -r '.status.parents[]?.conditions[]?
                        | select(.type == "Accepted" and .status == "True") | .status' | head -1)"
                  [ "$st" = "True" ] && exit 0
                  sleep 2
                done
                echo "httproute kagent-mcp never became Accepted"; exit 1

    - name: create-test-agent
      description: Deploy test agent for MCP invocation
      try:
        - apply:
            file: agent-test.yaml
        - assert:
            resource:
              apiVersion: v1alpha3
              kind: Agent
              metadata:
                namespace: kagent
                name: test-mcp-agent

    - name: verify-mcp-endpoint-availability
      description: Test MCP endpoint responds correctly
      try:
        - script:
            content: |
                for _ in $(seq 1 30); do
                  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    --cacert "${REPO_ROOT}/certs/rootCA.pem" \
                    "https://kagent-mcp.${DOMAIN}/mcp" || true)"
                  [ "$code" = "200" ] || [ "$code" = "405" ] && exit 0
                  sleep 2
                done
                echo "MCP endpoint at https://kagent-mcp.${DOMAIN}/mcp not available (last: ${code})"
                exit 1

    - name: test-list-agents-tool
      description: Validate list_agents MCP tool availability
      try:
        - script:
            content: |
                # Test MCP tools/list_agents endpoint
                response=$(curl -s --cacert "${REPO_ROOT}/certs/rootCA.pem" \
                  -X POST "https://kagent-mcp.${DOMAIN}/mcp" \
                  -H "Content-Type: application/json" \
                  -d '{
                    "jsonrpc": "2.0",
                    "method": "tools/list",
                    "id": 1
                  }')
                
                echo "MCP Tools Response: $response"
                
                # Validate response contains list_agents
                if echo "$response" | jq -e '.result.tools[]? | select(.name == "list_agents")' > /dev/null; then
                  echo "✅ list_agents tool available"
                  exit 0
                else
                  echo "❌ list_agents tool not found"
                  exit 1
                fi

    - name: test-invoke-agent-tool
      description: Validate invoke_agent MCP tool availability  
      try:
        - script:
            content: |
                # Test invoke_agent tool exists
                response=$(curl -s --cacert "${REPO_ROOT}/certs/rootCA.pem" \
                  -X POST "https://kagent-mcp.${DOMAIN}/mcp" \
                  -H "Content-Type: application/json" \
                  -d '{
                    "jsonrpc": "2.0",
                    "method": "tools/list",
                    "id": 2
                  }')
                
                if echo "$response" | jq -e '.result.tools[]? | select(.name == "invoke_agent")' > /dev/null; then
                  echo "✅ invoke_agent tool available"
                  exit 0
                else
                  echo "❌ invoke_agent tool not found"
                  exit 1
                fi

    - name: test-mcp-agent-discovery
      description: Test list_agents returns our test agent
      try:
        - script:
            content: |
                # Call list_agents tool
                response=$(curl -s --cacert "${REPO_ROOT}/certs/rootCA.pem" \
                  -X POST "https://kagent-mcp.${DOMAIN}/mcp" \
                  -H "Content-Type: application/json" \
                  -d '{
                    "jsonrpc": "2.0",
                    "method": "tools/call",
                    "id": 3,
                    "params": {
                      "name": "list_agents",
                      "arguments": {}
                    }
                  }')
                
                echo "list_agents response: $response"
                
                # Validate test-mcp-agent is in response
                if echo "$response" | jq -e '.result.content[]? | select(.text | contains("test-mcp-agent"))' > /dev/null; then
                  echo "✅ test-mcp-agent discovered via MCP"
                  exit 0
                else
                  echo "❌ test-mcp-agent not found in list_agents"
                  exit 1
                fi

    - name: cleanup-test-resources
      description: Remove test agent and HTTPRoute (optional for dev, good for CI)
      try:
        - script:
            content: |
                kubectl delete -n kagent httproute kagent-mcp --ignore-not-found
                kubectl delete -n kagent agent test-mcp-agent --ignore-not-found
```

### 3.3 Supporting Files

**File**: `tests/kagent-mcp/mcp-validation/mcp-route.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kagent-mcp
  namespace: kagent
  labels:
    app.kubernetes.io/managed-by: kind-infra
    kagent.dev/mcp: "true"
spec:
  parentRefs:
    - name: kind-infra
      namespace: agentgateway-system
  hostnames:
    - "kagent-mcp.${DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - name: kagent-controller
          port: 8083
```

**File**: `tests/kagent-mcp/agent-test.yaml`

```yaml
apiVersion: v1alpha3
kind: Agent
metadata:
  name: test-mcp-agent
  namespace: kagent
spec:
  description: "Test agent for MCP validation"
  instructions: "You are a helpful test agent. Respond with 'MCP test successful' when asked."
  tools:
    - type: builtin
      name: weather
      description: "Get weather information"
```

## Phase 4: Integration with kind-infra

### 4.1 Update Makefile

```makefile
# Add new targets
.PHONY: kagent-mcp-expose kagent-mcp-unexpose

kagent-mcp-expose: ## Expose kagent MCP server via gateway
	@bash scripts/60-register.sh expose "kagent-mcp" "kagent" "kagent-controller" "8083"

kagent-mcp-unexpose: ## Remove kagent MCP route
	@bash scripts/60-register.sh remove "kagent-mcp"
```

### 4.2 Script Integration

Update `scripts/60-register.sh` to handle MCP-specific configurations if needed.

## Phase 5: Validation and Testing

### 5.1 Manual Testing Steps

```bash
# 1. Ensure kagent is deployed
make kagent-deploy

# 2. Expose MCP endpoint
make kagent-mcp-expose

# 3. Test endpoint availability
curl -k https://kagent-mcp.internal/mcp

# 4. Configure MCP client (Claude Code)
claude mcp add --transport http kagent-mcp https://kagent-mcp.internal/mcp

# 5. Test MCP connection
claude mcp list

# 6. Run chainsaw tests
make test
```

### 5.2 Automated Testing

```bash
# Run all tests including MCP validation
make test

# Run only MCP tests
chainsaw test --config .chainsaw.yml tests/kagent-mcp/
```

## Phase 6: Documentation

### 6.1 Update README

Add MCP configuration section to existing documentation.

### 6.2 Configuration Examples

Create examples for different MCP clients (Cursor, Claude Code, custom).

## Implementation Order

1. ✅ **Create plan document** (current phase)
2. **Create HTTPRoute manifests** for MCP routing
3. **Create chainsaw test suite** for validation
4. **Update Makefile** with MCP targets  
5. **Test endpoint availability** manually
6. **Configure local MCP client** and validate
7. **Run automated chainsaw tests**
8. **Document configuration** process

## Success Criteria

- ✅ MCP endpoint accessible at `https://kagent-mcp.internal/mcp`
- ✅ HTTPRoute properly configured and accepted by gateway
- ✅ Both MCP tools (`list_agents`, `invoke_agent`) available
- ✅ Agent discovery and invocation working via MCP
- ✅ Chainsaw tests passing consistently
- ✅ Local MCP client can successfully connect and interact
- ✅ Documentation complete with examples

## Technical Considerations

### Gateway Configuration
- Use path-based routing (`/mcp`) rather than hostname-only for clarity
- Leverage existing TLS termination at AgentGateway
- Ensure proper backend port mapping (8083 for controller)

### MCP Protocol
- Uses Streamable HTTP transport (not SSE)
- Follows Model Context Protocol specification
- JSON-RPC 2.0 message format

### Testing Strategy  
- Test both endpoint availability and functionality
- Validate MCP protocol compliance
- Test actual agent discovery and invocation
- Cleanup resources after testing

### Local Development
- Support both hostname and port-forwarding access
- Provide examples for multiple MCP clients
- Clear troubleshooting steps

## Next Steps

1. **Review and approve this plan**
2. **Begin implementation** starting with Phase 1 (Gateway Configuration)
3. **Create chainsaw tests** in parallel with configuration
4. **Test and validate** each phase before proceeding
5. **Document findings** and update plan as needed

---

*Plan created based on kagent.dev MCP documentation and existing kind-infra patterns.*