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

# Stateless streamable-HTTP MCP: every call is a plain POST returning SSE.
mcp_post() {
  local payload="$1"
  curl -s --cacert "$CERT_PATH" --max-time 180 \
    -X POST "$MCP_ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "$payload" | grep '^data:' | sed 's/^data: //'
}

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
response=$(mcp_post '{"jsonrpc":"2.0","method":"tools/list","id":1}')
echo "   Tools found:"
echo "$response" | jq -r '.result.tools[].name' | sed 's/^/     - /'

for tool in list_agent_instances invoke_agent_instance; do
  if echo "$response" | jq -e --arg t "$tool" '.result.tools[]? | select(.name == $t)' > /dev/null; then
    echo "   ✅ $tool tool found"
  else
    echo "   ❌ $tool tool not found"
    exit 1
  fi
done
echo ""

# Test list_agent_instances tool
echo "3️⃣ Testing list_agent_instances tool call..."
response=$(mcp_post '{"jsonrpc":"2.0","method":"tools/call","id":2,"params":{"name":"list_agent_instances","arguments":{}}}')

if echo "$response" | jq -e '.result' > /dev/null; then
  echo "   ✅ list_agent_instances call successful"
  echo "   Ready instances (id — template via harness):"
  echo "$response" | jq -r '.result.content[]?.text' | sed 's/^/     /'
else
  echo "   ❌ list_agent_instances call failed"
  exit 1
fi
echo ""

echo "🎉 MCP endpoint validation complete!"
echo ""
cat <<EOF
📝 Invoke an instance end to end (writes to the instance's history —
   prefer a self-test instance over real agents):

   instance_id="<id from the list above>"
   curl -s --cacert "$CERT_PATH" -X POST "$MCP_ENDPOINT" \\
     -H 'Content-Type: application/json' \\
     -H 'Accept: application/json, text/event-stream' \\
     -d "{\\"jsonrpc\\":\\"2.0\\",\\"method\\":\\"tools/call\\",\\"id\\":3,\\"params\\":{\\"name\\":\\"invoke_agent_instance\\",\\"arguments\\":{\\"agent_instance_id\\":\\"\$instance_id\\",\\"message\\":\\"Say hi\\"}}}"

📝 Configure your MCP client:
   Claude Code:  claude mcp add --transport http kagent-mcp $MCP_ENDPOINT
   Cursor IDE:    Add to MCP settings: {"url": "$MCP_ENDPOINT"}
EOF
echo ""
