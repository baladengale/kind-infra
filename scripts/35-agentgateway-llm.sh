#!/usr/bin/env bash
#
# AgentGateway LLM router + kagent ModelConfigs.
#
# Configures AgentGateway as an LLM provider gateway with two backends
# (Z.AI and DeepSeek), creates the PreRouting model-extraction policy and
# HTTPRoute for model-based routing, and provisions the kagent ModelConfig
# resources (default-model-config, agw-model-config).
#
# Reads from the repo .env:
#   ANTHROPIC_API_KEY         DeepSeek API key (required)
#   ANTHROPIC_ZAI_AUTH_TOKEN  Z.AI API key (falls back to ~/.balarc_zai)
#
# Can be run standalone after kagent is deployed, or is wired into the full
# bootstrap via scripts/00-up.sh (`make all`).
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl

# ---------------------------------------------------------------------------
# 1. Read API keys
# ---------------------------------------------------------------------------
[[ -f "$ROOT_DIR/.env" ]] \
  || die "Missing $ROOT_DIR/.env — copy kagent/env.example to .env and fill in ANTHROPIC_API_KEY (see README)."
set -a; . "$ROOT_DIR/.env"; set +a
[[ -n "${ANTHROPIC_API_KEY:-}" ]] \
  || die "ANTHROPIC_API_KEY not set in $ROOT_DIR/.env — fill it in (see README)."

# Z.AI token: .env first, then the Claude-Code rc (~/.balarc_zai) — same key
# that ANTHROPIC_AUTH_TOKEN uses there.
ZAI_TOKEN="${ANTHROPIC_ZAI_AUTH_TOKEN:-}"
if [[ -z "$ZAI_TOKEN" && -f "$HOME/.balarc_zai" ]]; then
  # Strip an optional = assignment and any surrounding quotes from the rc line.
  ZAI_TOKEN="$(sed -n 's/^export ANTHROPIC_AUTH_TOKEN=//p' "$HOME/.balarc_zai" | head -1 | tr -d "\"'")"
fi
[[ -n "$ZAI_TOKEN" ]] \
  || die "Z.AI token not found — set ANTHROPIC_ZAI_AUTH_TOKEN in $ROOT_DIR/.env (or export ANTHROPIC_AUTH_TOKEN in ~/.balarc_zai)."

# ---------------------------------------------------------------------------
# 2. Verify prerequisites
# ---------------------------------------------------------------------------
say "Checking prerequisites..."
kctl -n "$GW_NS" get gateway "$GW_NAME" >/dev/null 2>&1 \
  || die "Gateway '${GW_NAME}' not found — run 'make create' first (or scripts/30-gateway.sh)."
kctl -n "$KAGENT_NS" get crd modelconfigs.kagent.dev >/dev/null 2>&1 \
  || die "kagent CRDs not found — deploy kagent first (make kagent-deploy or scripts/80-kagent.sh deploy)."

# ModelConfig apiVersion — upstream churns it (v1alpha2 was dropped in the v2
# rewrite), so read the storage version off the installed CRD and normalize
# every manifest to it instead of hardcoding.
MC_API_VERSION="$(kctl get crd modelconfigs.kagent.dev \
  -o jsonpath='{.spec.versions[?(@.storage==true)].name}')"
[[ -n "$MC_API_VERSION" ]] \
  || die "could not read the storage version of modelconfigs.kagent.dev"

apply_modelconfigs() { # <manifest> — apply with the CRD's storage apiVersion
  sed "s|apiVersion: kagent.dev/v1alpha[0-9]*|apiVersion: kagent.dev/${MC_API_VERSION}|" \
    "$ROOT_DIR/manifests/$1" | kctl apply -f - >/dev/null
}

# ---------------------------------------------------------------------------
# 3. Create secrets for AgentGateway backends
# ---------------------------------------------------------------------------
say "Creating AgentGateway backend secrets..."

# DeepSeek secret (always)
kctl -n "$GW_NS" delete secret agw-deepseek-secret --ignore-not-found >/dev/null 2>&1
kubectl create secret generic agw-deepseek-secret \
  --namespace "$GW_NS" \
  --context "$KUBE_CONTEXT" \
  --from-literal=Authorization="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kctl apply -f - >/dev/null
ok "DeepSeek secret ready"

# Z.AI secret (primary for both tiers)
kctl -n "$GW_NS" delete secret agw-zai-secret --ignore-not-found >/dev/null 2>&1
kubectl create secret generic agw-zai-secret \
  --namespace "$GW_NS" \
  --context "$KUBE_CONTEXT" \
  --from-literal=Authorization="${ZAI_TOKEN}" \
  --dry-run=client -o yaml | kctl apply -f - >/dev/null
ok "Z.AI secret ready"

# Ark is retired — remove its secrets so nothing lingers half-wired.
kctl -n "$GW_NS" delete secret agw-ark-secret --ignore-not-found >/dev/null 2>&1
kctl -n "$KAGENT_NS" delete secret kagent-anthropic-ark --ignore-not-found >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 4. Create kagent ModelConfig secrets
# ---------------------------------------------------------------------------
say "Creating kagent ModelConfig secrets..."

# Placeholder key for the controller's client through the gateway — the real
# per-backend keys live in the gateway secrets above.
kubectl create secret generic kagent-anthropic \
  --namespace "$KAGENT_NS" \
  --context "$KUBE_CONTEXT" \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kctl apply -f - >/dev/null
ok "kagent-anthropic secret updated"

# ---------------------------------------------------------------------------
# 5. Apply AgentGateway LLM manifests
# ---------------------------------------------------------------------------
say "Applying AgentGateway LLM routing configuration..."
apply_manifest agentgateway-llm.yaml
ok "AgentGateway LLM routing applied"

# Wait for the HTTPRoute to be accepted
for _ in $(seq 1 15); do
  st="$(kctl -n "$GW_NS" get httproute agw-llm-routing -o json \
    | python3 -c "import sys,json; d=json.load(sys.stdin); cs=d.get('status',{}).get('parents',[{}])[0].get('conditions',[]); print([c['status'] for c in cs if c['type']=='Accepted'][0])" 2>/dev/null || echo "waiting")"
  if [ "$st" = "True" ]; then
    ok "HTTPRoute agw-llm-routing accepted by gateway"
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# 6. Apply kagent ModelConfig manifests
# ---------------------------------------------------------------------------
say "Applying kagent ModelConfigs..."
apply_modelconfigs kagent-model-configs.yaml

# Removed configs — delete the stale ones so nothing lingers half-wired.
kctl -n "$KAGENT_NS" delete modelconfig ark-model-config --ignore-not-found >/dev/null 2>&1
kctl -n "$KAGENT_NS" delete modelconfig agw-cheap-model-config --ignore-not-found >/dev/null 2>&1

# Wait for ModelConfigs to be accepted
for mc in default-model-config agw-model-config; do
  if kctl -n "$KAGENT_NS" get modelconfig "$mc" >/dev/null 2>&1; then
    for _ in $(seq 1 10); do
      st="$(kctl -n "$KAGENT_NS" get modelconfig "$mc" -o json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); cs=d.get('status',{}).get('conditions',[]); print([c['status'] for c in cs if c['type']=='Accepted'][0])" 2>/dev/null || echo "waiting")"
      if [ "$st" = "True" ]; then
        ok "ModelConfig $mc accepted"
        break
      fi
      sleep 2
    done
  fi
done

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo ""
say "AgentGateway LLM routing setup complete!"
ok "ModelConfigs available:"
kctl get modelconfig -n "$KAGENT_NS" 2>/dev/null | head -10
echo ""
ok "AgentGateway backends:"
kctl get agentgatewaybackends -n "$GW_NS" 2>/dev/null | head -10
echo ""
say "To use a different model config, update the agent:"
echo "  kubectl patch agent k8s-agent -n kagent --type merge \\"
echo "    -p '{\"spec\":{\"declarative\":{\"modelConfig\":\"agw-model-config\"}}}'"
echo ""
