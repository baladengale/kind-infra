# kagent MCP Client Configuration

This guide shows how to configure various MCP clients to connect with your kagent MCP server exposed through AgentGateway.

## Prerequisites

1. **kagent deployed** in your kind cluster
2. **MCP endpoint exposed** via gateway: `make kagent-mcp-expose`
3. **DNS working** for `*.internal` domain
4. **TLS certificate trusted** (mkcert CA in your keychain)

## Quick Setup

```bash
# 1. Deploy kagent (MCP endpoint automatically included)
make kagent-deploy

# 2. Test MCP endpoint availability
make kagent-mcp-test

# 3. Verify endpoint responds
curl -k https://kagent.internal/mcp
```

## MCP Client Configurations

### Claude Code (Desktop)

**Add kagent as MCP server:**
```bash
claude mcp add --transport http kagent https://kagent.internal/mcp
```

**Project-specific configuration:**
```bash
claude mcp add --transport http --scope project kagent https://kagent.internal/mcp
```

**Verify connection:**
```bash
claude mcp list
```

**Available tools:**
- `list_agents` - Discover all available kagent agents
- `invoke_agent` - Execute specific agent with input

### Cursor IDE

**Edit MCP settings:**

**Option 1: Settings UI**
1. Open Cursor Settings
2. Navigate to "MCP Servers"
3. Add new server:
   - Name: `kagent-agents`
   - URL: `https://kagent.internal/mcp`

**Option 2: Configuration file**

Add to your Cursor MCP settings (`~/.cursor/mcp.json` or workspace settings):
```json
{
  "mcpServers": {
    "kagent-agents": {
      "url": "https://kagent.internal/mcp"
    }
  }
}
```

**Restart Cursor** to load the new MCP server configuration.

### Cline (VS Code Extension)

**Add to VS Code settings.json:**
```json
{
  "cline.mcpServers": {
    "kagent-agents": {
      "transport": {
        "type": "http",
        "url": "https://kagent-mcp.internal/mcp"
      }
    }
  }
}
```

### Custom MCP Client

**HTTP Request Format:**
```bash
curl -k https://kagent.internal/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/list",
    "id": 1
  }'
```

**List available agents:**
```bash
curl -k https://kagent.internal/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": 2,
    "params": {
      "name": "list_agents",
      "arguments": {}
    }
  }'
```

**Invoke an agent:**
```bash
curl -k https://kagent.internal/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": 3,
    "params": {
      "name": "invoke_agent",
      "arguments": {
        "agent_name": "your-agent-name",
        "input": "your prompt here",
        "sessionID": "optional-session-id"
      }
    }
  }'
```

## Available MCP Tools

### list_agents
**Description**: Discover all available kagent agents

**Parameters**: None (empty object)

**Response**: JSON array of available agents with their descriptions

**Example**:
```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "id": 1,
  "params": {
    "name": "list_agents",
    "arguments": {}
  }
}
```

### invoke_agent
**Description**: Execute a specific kagent agent

**Parameters**:
- `agent_name` (string, required): Name of the agent to invoke
- `input` (string, required): Input prompt for the agent
- `sessionID` (string, optional): Session ID for conversation continuity

**Example**:
```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "id": 2,
  "params": {
    "name": "invoke_agent",
    "arguments": {
      "agent_name": "my-agent",
      "input": "Help me analyze this data",
      "sessionID": "session-123"
    }
  }
}
```

## Troubleshooting

### MCP endpoint not accessible

**Check if kagent is running:**
```bash
kubectl get pods -n kagent -l app.kubernetes.io/component=controller
```

**Check if MCP route exists (part of kagent route):**
```bash
kubectl get httproute -n kagent kagent
```

**Verify gateway status:**
```bash
kubectl get gateway -n agentgateway-system kind-infra
```

### TLS certificate errors

**Reinstall mkcert CA:**
```bash
mkcert -install
```

**Restart Docker Desktop** to sync the CA into the VM.

### DNS resolution issues

**Flush DNS cache:**
```bash
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

**Test DNS resolution:**
```bash
dig kagent.internal @127.0.0.1
```

### MCP tools not available

**Test MCP endpoint manually:**
```bash
make kagent-mcp-test
```

**Check kagent controller logs:**
```bash
kubectl logs -n kagent -l app.kubernetes.io/component=controller --tail=50
```

## Testing

### Manual Testing
```bash
# Test endpoint availability
curl -k https://kagent-mcp.internal/mcp

# Test MCP tools
make kagent-mcp-test
```

### Automated Testing
```bash
# Run chainsaw tests
make test

# Run only MCP tests
chainsaw test --config .chainsaw.yml tests/kagent-mcp/
```

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   MCP Client    │    │   AgentGateway   │    │  kagent-controller  │
│ (Cursor/Claude) │◄──►│   (Gateway API)  │◄──►│   (MCP Server)      │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
     HTTP/MCP                /mcp route              port 8083
```

**Flow:**
1. MCP client sends HTTP request to `https://kagent-mcp.internal/mcp`
2. AgentGateway routes `/mcp` path to kagent-controller:8083
3. kagent-controller processes MCP protocol requests
4. Response returned through same path

## Security Notes

- **TLS**: All communication encrypted with mkcert certificates
- **Local only**: Exposed only on local machine via 127.0.0.1
- **No external access**: Gateway only binds to localhost
- **API keys**: Stored in kagent configuration, not exposed via MCP

## Performance Considerations

- **Latency**: ~10-50ms additional latency via gateway routing
- **Bandwidth**: Minimal overhead for JSON-RPC messages
- **Scalability**: Limited by local kagent controller capacity

## Advanced Configuration

### Custom MCP endpoint path

Modify the HTTPRoute to use a different path:
```yaml
spec:
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/mcp  # Custom path
```

### Multiple MCP servers

Create additional HTTPRoutes for different kagent instances or namespaces.

### Port-forwarding alternative

If gateway routing doesn't work, use port-forwarding:
```bash
kubectl port-forward -n kagent svc/kagent-controller 8083:8083
# Then use: http://localhost:8083/mcp
```

## Next Steps

1. **Deploy kagent**: `make kagent-deploy`
2. **Expose MCP**: `make kagent-mcp-expose`
3. **Configure client**: See instructions above
4. **Test connection**: `make kagent-mcp-test`
5. **Use agents**: Invoke via MCP client tools

For more information, see:
- [kagent MCP Documentation](https://kagent.dev/docs/kagent/examples/agents-mcp/)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)