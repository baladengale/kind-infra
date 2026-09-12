#!/usr/bin/env bash
#
# AgentGateway LLM router + additional kagent ModelConfigs.
#
# Configures AgentGateway as an LLM provider gateway with two backends
# (DeepSeek and Ark), creates the PreRouting model-extraction policy and
# HTTPRoute for model-based routing, and provisions the additional kagent
# ModelConfig resources (ark-model-config, agw-model-config).
#
# Reads from the repo .env:
#   ANTHROPIC_API_KEY       DeepSeek API key (required)
#   ANTHROPIC_ARK_AUTH_TOKEN  Ark API key (optional — skips ark resources if empty)
#
# Can be run standalone after kagent is deployed, or is wired into the full
# bootstrap via scripts/00-up.sh (`make all`).
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl

# ---------------------------------------------------------------------------
# 1. Read API keys from .env
# ---------------------------------------------------------------------------
[[ -f "$ROOT_DIR/.env" ]] \
  || die "Missing $ROOT_DIR/.env — copy kagent/env.example to .env and fill in ANTHROPIC_API_KEY (see README)."
set -a; . "$ROOT_DIR/.env"; set +a
[[ -n "${ANTHROPIC_API_KEY:-}" ]] \
  || die "ANTHROPIC_API_KEY not set in $ROOT_DIR/.env — fill it in (see README)."

# Support both ANTHROPIC_ARK_AUTH_TOKEN (.env) and ANTHROPIC_AUTH_TOKEN (.balarc_ark)
ARK_TOKEN="${ANTHROPIC_ARK_AUTH_TOKEN:-${ANTHROPIC_AUTH_TOKEN:-}}"

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

# Ark secret (only if token is provided)
if [[ -n "$ARK_TOKEN" ]]; then
  kctl -n "$GW_NS" delete secret agw-ark-secret --ignore-not-found >/dev/null 2>&1
  kubectl create secret generic agw-ark-secret \
    --namespace "$GW_NS" \
    --context "$KUBE_CONTEXT" \
    --from-literal=Authorization="${ARK_TOKEN}" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
  ok "Ark secret ready"
else
  warn "ANTHROPIC_ARK_AUTH_TOKEN not set — skipping Ark backend (ark-model-config, agw-ark)."
fi

# ---------------------------------------------------------------------------
# 4. Create kagent ModelConfig secrets
# ---------------------------------------------------------------------------
say "Creating kagent ModelConfig secrets..."

# Update the existing kagent-anthropic secret with the correct DeepSeek key
kubectl create secret generic kagent-anthropic \
  --namespace "$KAGENT_NS" \
  --context "$KUBE_CONTEXT" \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kctl apply -f - >/dev/null
ok "kagent-anthropic secret updated"

# Ark key for kagent (only if token is provided)
if [[ -n "$ARK_TOKEN" ]]; then
  kctl -n "$KAGENT_NS" delete secret kagent-anthropic-ark --ignore-not-found >/dev/null 2>&1
  kubectl create secret generic kagent-anthropic-ark \
    --namespace "$KAGENT_NS" \
    --context "$KUBE_CONTEXT" \
    --from-literal=ANTHROPIC_API_KEY="${ARK_TOKEN}" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
  ok "kagent-anthropic-ark secret created"
fi

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
say "Applying additional kagent ModelConfigs..."
if [[ -n "$ARK_TOKEN" ]]; then
  # Apply all model configs (including ark)
  apply_modelconfigs kagent-model-configs.yaml
else
  # Apply only the agw model config (skip ark)
  kctl apply -f - >/dev/null <<EOF
apiVersion: kagent.dev/${MC_API_VERSION}
kind: ModelConfig
metadata:
  name: agw-model-config
  namespace: kagent
spec:
  provider: Anthropic
  model: deepseek-chat
  apiKeySecret: kagent-anthropic
  apiKeySecretKey: ANTHROPIC_API_KEY
  anthropic:
    baseUrl: http://kind-infra.agentgateway-system.svc.cluster.local:8080
EOF
fi

# Wait for ModelConfigs to be accepted
for mc in ark-model-config agw-model-config; do
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
echo "    -p '{\"spec\":{\"declarative\":{\"modelConfig\":\"ark-model-config\"}}}'"
echo ""
