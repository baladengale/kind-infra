#!/usr/bin/env bash
#
# Manual MCP endpoint testing script
# Tests kagent MCP server availability and functionality
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DOMAIN="${DOMAIN:-internal}"
MCP_ENDPOINT="https://kagent.${DOMAIN}/mcp"
CERT_PATH="$ROOT_DIR/certs/rootCA.pem"

echo "🧪 Testing kagent MCP endpoint: $MCP_ENDPOINT"
echo ""

# Check if endpoint is accessible
echo "1️⃣ Testing endpoint availability..."
for i in {1..30}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    --cacert "$CERT_PATH" "$MCP_ENDPOINT" || echo "000")
  if [ "$code" = "200" ] || [ "$code" = "405" ]; then
    echo "   ✅ Endpoint available (HTTP $code)"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "   ❌ Endpoint not available (HTTP $code)"
    echo "   Run 'make kagent-mcp-expose' first"
    exit 1
  fi
  sleep 2
done
echo ""

# Test MCP tools/list
echo "2️⃣ Testing MCP tools/list..."
response=$(curl -s --cacert "$CERT_PATH" \
  -X POST "$MCP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/list",
    "id": 1
  }')

echo "   Response: $response"

if echo "$response" | jq -e '.result.tools[]? | select(.name == "list_agents")' > /dev/null; then
  echo "   ✅ list_agents tool found"
else
  echo "   ❌ list_agents tool not found"
  exit 1
fi

if echo "$response" | jq -e '.result.tools[]? | select(.name == "invoke_agent")' > /dev/null; then
  echo "   ✅ invoke_agent tool found"
else
  echo "   ❌ invoke_agent tool not found"
  exit 1
fi
echo ""

# Test list_agents tool
echo "3️⃣ Testing list_agents tool call..."
response=$(curl -s --cacert "$CERT_PATH" \
  -X POST "$MCP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "id": 2,
    "params": {
      "name": "list_agents",
      "arguments": {}
    }
  }')

echo "   Response: $response"

if echo "$response" | jq -e '.result' > /dev/null; then
  echo "   ✅ list_agents call successful"
  echo "   Available agents:"
  echo "$response" | jq -r '.result.content[]?.text' 2>/dev/null || echo "   (No agents found)"
else
  echo "   ❌ list_agents call failed"
  exit 1
fi
echo ""

echo "🎉 MCP endpoint validation complete!"
echo ""
echo "📝 Configure your MCP client:"
echo "   Claude Code:  claude mcp add --transport http kagent-mcp $MCP_ENDPOINT"
echo "   Cursor IDE:    Add to MCP settings: {\"url\": \"$MCP_ENDPOINT\"}"
echo ""