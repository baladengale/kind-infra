#!/usr/bin/env bash
#
# One-command bootstrap — `make all`.
#
# Brings up the full stack from scratch, in order:
#
#  1. kind cluster + local registry container     (10-create-cluster.sh)
#  2. AgentGateway + Gateway API + wildcard TLS   (30-gateway.sh)
#  3. port-free registry route + certs.d bypass   (50-registry.sh)
#  4. [SUBSTRATE_ENABLED=true] Agent Substrate
#     platform (ate-system)                        (85-substrate.sh)
#  5. kagent: mirror images to the registry,
#     helm install, UI + MCP route                 (80-kagent.sh deploy)
#  6. personal site: build, kind load,
#     manifests + route                            (90-site.sh)
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

total=6
[[ "$SUBSTRATE_ENABLED" = "true" ]] && total=8
step=0
next() { step=$((step + 1)); say "Step $step/$total: $*"; }

next "cluster + local registry..."
bash "$ROOT_DIR/scripts/10-create-cluster.sh"
next "AgentGateway + TLS..."
bash "$ROOT_DIR/scripts/30-gateway.sh"
next "registry route + containerd wiring..."
bash "$ROOT_DIR/scripts/50-registry.sh"
if [[ "$SUBSTRATE_ENABLED" = "true" ]]; then
  next "Agent Substrate platform (ate-system)..."
  bash "$ROOT_DIR/scripts/85-substrate.sh" install
fi
next "kagent (mirror/build images, helm install, UI + MCP route)..."
# Substrate needs the locally built controller (see scripts/80-kagent.sh).
# The deploy also provisions the agentgateway LLM configs + agw ModelConfigs
# right after kagent-crds, BEFORE the controller/agents start — agents
# reference agw-cheap-model-config as summarizer and won't compile without it.
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
next "personal site (build, load, manifests, route)..."
bash "$ROOT_DIR/scripts/90-site.sh"

echo ""
say "All up:"
ok "kagent UI + MCP    https://kagent.${DOMAIN}"
ok "kagent CLI/TUI API http://kagent-api.${DOMAIN}  (kagent_url in ~/.kagent/config.yaml)"
ok "personal site      https://baladengale.${DOMAIN}"
ok "registry           https://kind-registry.${DOMAIN}  (docker push kind-registry.${DOMAIN}/img:tag)"
if [[ "$SUBSTRATE_ENABLED" = "true" ]]; then
  ok "substrate          ${SUBSTRATE_NS} (kubectl get workerpools -A)"
  ok "sample agent       hello-substrate on substrate (make substrate-validate to test)"
fi

# Hostnames need the dnsmasq zone; until then curl --resolve 127.0.0.1 works.
if [[ -z "$(dig +short "up-check.${DOMAIN}" @127.0.0.1 2>/dev/null)" ]]; then
  warn "DNS not answering on 127.0.0.1 for *.${DOMAIN} — run: make dns-install (one-time, sudo)"
fi
