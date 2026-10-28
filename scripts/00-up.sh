#!/usr/bin/env bash
#
# One-command bootstrap — `make all`.
#
# Brings up the full stack from scratch, in order — fast pieces first, the
# slow substrate + kagent build tail last (so the quick routes are usable
# while it runs):
#
#  1. kind cluster + local registry container      (10-create-cluster.sh)
#  2. AgentGateway + Gateway API + wildcard TLS    (30-gateway.sh)
#  3. port-free registry route + certs.d bypass    (50-registry.sh)
#  4. personal site: build, kind load,
#     manifests + route                            (90-site.sh)
#  5. OIE Hub route (Mac host bridge)              (95-hub.sh)
#  6. Strata model-service route (Mac host bridge) (96-strata.sh)
#  7. [SUBSTRATE_ENABLED=true] Agent Substrate
#     platform (ate-system)                        (85-substrate.sh)
#  8. kagent: mirror/build images, helm install,
#     UI + MCP route                               (80-kagent.sh)
#  9. AgentGateway LLM router re-apply             (35-agentgateway-llm.sh)
# 10. [SUBSTRATE_ENABLED=true] sample agent        (87-kagent-samples.sh)
#
# Every step is idempotent — re-run to converge after a change. DNS
# (`make dns-install`) is one-time machine-level setup with sudo and is NOT
# run here; this script probes it at the end and points to it if missing.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Fail fast, before the multi-minute cluster create, on a missing API key.
# (80-kagent.sh re-checks; this is just an early exit with a clear message.)
[[ -f "$ROOT_DIR/.env" ]] \
  || die "Missing $ROOT_DIR/.env — copy kagent/env.example to .env and fill in ANTHROPIC_API_KEY (see README)."
set -a; . "$ROOT_DIR/.env"; set +a
[[ -n "${ANTHROPIC_API_KEY:-}" ]] \
  || die "ANTHROPIC_API_KEY not set in $ROOT_DIR/.env — fill it in (see README)."

total=8
[[ "$SUBSTRATE_ENABLED" = "true" ]] && total=10
step=0
next() { step=$((step + 1)); say "Step $step/$total: $*"; }

next "cluster + local registry..."
bash "$ROOT_DIR/scripts/10-create-cluster.sh"
next "AgentGateway + TLS..."
bash "$ROOT_DIR/scripts/30-gateway.sh"
next "registry route + containerd wiring..."
bash "$ROOT_DIR/scripts/50-registry.sh"

# Fast, independent routes next — seconds each, and usable while the slow
# substrate + kagent tail below is still building.
next "personal site (build, load, manifests, route)..."
bash "$ROOT_DIR/scripts/90-site.sh"
next "OIE Hub route (Mac-hosted Hub via host bridge)..."
bash "$ROOT_DIR/scripts/95-hub.sh"
next "Strata model-service route (Mac-hosted engine via host bridge)..."
bash "$ROOT_DIR/scripts/96-strata.sh"

# The slow tail: substrate first (the kagent controller dials ate-api at
# startup), then kagent, then the LLM ModelConfigs (also provisioned inside
# the deploy right after kagent-crds, before the controller starts). Strata's
# ModelConfig is applied by 35-agentgateway-llm.sh — 96-strata.sh above
# self-skips it while the CRD doesn't exist yet.
if [[ "$SUBSTRATE_ENABLED" = "true" ]]; then
  next "Agent Substrate platform (ate-system)..."
  bash "$ROOT_DIR/scripts/85-substrate.sh" install
fi
next "kagent (mirror/build images, helm install, UI + MCP route)..."
# Substrate needs the locally built controller (see scripts/80-kagent.sh).
# The deploy also provisions the agentgateway LLM configs + agw ModelConfigs
# right after kagent-crds, BEFORE the controller/agents start — agents
# reference default-model-config and won't compile without it.
if [[ "$SUBSTRATE_ENABLED" = "true" ]]; then
  bash "$ROOT_DIR/scripts/80-kagent.sh" build-deploy
else
  bash "$ROOT_DIR/scripts/80-kagent.sh" deploy
fi
next "AgentGateway LLM router re-apply + acceptance check..."
bash "$ROOT_DIR/scripts/35-agentgateway-llm.sh"
if [[ "$SUBSTRATE_ENABLED" = "true" ]]; then
  next "sample agent on substrate (harness + template + instance)..."
  bash "$ROOT_DIR/scripts/87-kagent-samples.sh" install
fi

echo ""
say "All up:"
ok "kagent UI + MCP    https://kagent.${DOMAIN}"
ok "kagent CLI/TUI API http://kagent-api.${DOMAIN}  (kagent_url in ~/.kagent/config.yaml)"
ok "personal site      https://baladengale.${DOMAIN}"
ok "OIE Hub            http://hub.${DOMAIN}  (Mac LaunchAgent via host bridge)"
ok "Strata model       https://strata.${DOMAIN}/v1  (Mac engine via host bridge; Anthropic apps: https://strata.${DOMAIN})"
ok "registry           https://kind-registry.${DOMAIN}  (docker push kind-registry.${DOMAIN}/img:tag)"
if [[ "$SUBSTRATE_ENABLED" = "true" ]]; then
  ok "substrate          ${SUBSTRATE_NS} (kubectl get workerpools -A)"
  ok "sample agent       hello-substrate on substrate (make substrate-validate to test)"
fi

# Hostnames need the dnsmasq zone; until then curl --resolve 127.0.0.1 works.
if [[ -z "$(dig +short "up-check.${DOMAIN}" @127.0.0.1 2>/dev/null)" ]]; then
  warn "DNS not answering on 127.0.0.1 for *.${DOMAIN} — run: make dns-install (one-time, sudo)"
fi
