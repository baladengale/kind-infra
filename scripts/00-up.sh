#!/usr/bin/env bash
#
# One-command bootstrap — `make all`.
#
# Brings up the full stack from scratch, in order:
#
#   1. kind cluster + local registry container     (10-create-cluster.sh)
#   2. AgentGateway + Gateway API + wildcard TLS   (30-gateway.sh)
#   3. port-free registry route + certs.d bypass   (50-registry.sh)
#   4. kagent: mirror images to the registry,
#      helm install, UI + MCP route                (80-kagent.sh deploy)
#   5. personal site: build, kind load,
#      manifests + route                           (90-site.sh)
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

say "Step 1/5: cluster + local registry..."
bash "$ROOT_DIR/scripts/10-create-cluster.sh"
say "Step 2/5: AgentGateway + TLS..."
bash "$ROOT_DIR/scripts/30-gateway.sh"
say "Step 3/5: registry route + containerd wiring..."
bash "$ROOT_DIR/scripts/50-registry.sh"
say "Step 4/5: kagent (mirror images, helm install, UI + MCP route)..."
bash "$ROOT_DIR/scripts/80-kagent.sh" deploy
say "Step 5/5: personal site (build, load, manifests, route)..."
bash "$ROOT_DIR/scripts/90-site.sh"

echo ""
say "All up:"
ok "kagent UI + MCP    https://kagent.${DOMAIN}"
ok "personal site      https://baladengale.${DOMAIN}"
ok "registry           https://kind-registry.${DOMAIN}  (docker push kind-registry.${DOMAIN}/img:tag)"

# Hostnames need the dnsmasq zone; until then curl --resolve 127.0.0.1 works.
if [[ -z "$(dig +short "up-check.${DOMAIN}" @127.0.0.1 2>/dev/null)" ]]; then
  warn "DNS not answering on 127.0.0.1 for *.${DOMAIN} — run: make dns-install (one-time, sudo)"
fi
