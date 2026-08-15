#!/usr/bin/env bash
#
# Port-free registry access: kind-registry.internal (443, TLS) through the
# Gateway — no :5001 needed from the machine.
#
# Pieces:
#   1. Service + manual Endpoints pointing at the kind-registry container's
#      IP on the kind network, so the Gateway can proxy it like any backend
#   2. HTTPRoute kind-registry.${DOMAIN} -> that Service
#   3. containerd certs.d entry on every node for kind-registry.${DOMAIN},
#      pulling straight from the internal endpoint (nodes never pay the
#      TLS/Gateway hop) — same trick as the localhost:${REG_PORT} wiring
#
# `docker push kind-registry.internal/img:tag` works because the mkcert CA
# lives in the macOS keychain and Docker Desktop syncs host roots into its
# VM. If pushes fail with x509 errors, restart Docker Desktop once.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl "$CONTAINER_RUNTIME"
cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."
kctl -n "$GW_NS" get gateway "$GW_NAME" >/dev/null 2>&1 \
  || die "Gateway '${GW_NAME}' not found — run 'bash scripts/30-gateway.sh' first."

CERT_DIR="$ROOT_DIR/certs"
[[ -f "$CERT_DIR/rootCA.pem" ]] || die "Missing $CERT_DIR/rootCA.pem — run 'bash scripts/30-gateway.sh' first."

# ---------------------------------------------------------------------------
# 1. Registry container IP on the kind network -> Service + Endpoints
# ---------------------------------------------------------------------------
reg_ip="$("$CONTAINER_RUNTIME" inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$REG_NAME" 2>/dev/null || true)"
[[ -n "$reg_ip" ]] || die "Could not read the kind-network IP of container '${REG_NAME}' — is it running?"

say "Exposing registry ${reg_ip}:5000 as Service default/kind-registry (manifests/registry-service.yaml)..."
REG_IP="$reg_ip" apply_manifest registry-service.yaml

# ---------------------------------------------------------------------------
# 2. Route kind-registry.${DOMAIN} (443/80) through the Gateway
# ---------------------------------------------------------------------------
say "Routing kind-registry.${DOMAIN} -> default/kind-registry:5000 (manifests/registry-route.yaml)..."
apply_manifest registry-route.yaml

# ---------------------------------------------------------------------------
# 3. containerd on the nodes: pull kind-registry.${DOMAIN}/... directly from
#    the internal registry endpoint (no TLS/Gateway hop)
# ---------------------------------------------------------------------------
say "Wiring containerd for kind-registry.${DOMAIN} on every node..."
REGISTRY_DIR="/etc/containerd/certs.d/kind-registry.${DOMAIN}"
for node in $(kind get nodes --name "$KIND_CLUSTER_NAME"); do
  "$CONTAINER_RUNTIME" exec "$node" mkdir -p "$REGISTRY_DIR"
  cat <<EOF | "$CONTAINER_RUNTIME" exec -i "$node" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
server = "https://kind-registry.${DOMAIN}"

[host."${REG_SCHEME}://${REG_NAME}:${REG_INTERNAL_PORT}"]
  skip_verify = true
EOF
done

# Explicit SAN for the new hostname (strict clients need it; the wildcard
# *.${DOMAIN} alone is not matched by macOS curl/LibreSSL).
refresh_gateway_cert

# ---------------------------------------------------------------------------
# 4. Verify over real TLS (works regardless of DNS state via --resolve)
# ---------------------------------------------------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  --resolve "kind-registry.${DOMAIN}:443:127.0.0.1" \
  --cacert "$CERT_DIR/rootCA.pem" \
  "https://kind-registry.${DOMAIN}/v2/" || true)"
case "$code" in
  200) ok "https://kind-registry.${DOMAIN}/v2/ answered 200 — registry is live on 443" ;;
  000) warn "No response from kind-registry.${DOMAIN}:443 — check the Gateway proxy pods" ;;
  *)   warn "Unexpected HTTP ${code} from the registry — check: kubectl -n ${GW_NS} get pods" ;;
esac

cat <<EOF
Push/pull without ports:
  docker push kind-registry.${DOMAIN}/myimage:tag
Nodes pull the same names directly (certs.d bypass).
EOF
