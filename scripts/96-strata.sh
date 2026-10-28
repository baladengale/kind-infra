#!/usr/bin/env bash
#
# Strata model-service bridge — expose the Mac-hosted Strata engine at
# https://strata.internal.
#
# The engine does NOT run in the cluster: Strata serves on this Mac
# (`strata launch`, 127.0.0.1:8080 — the Metal GPU cannot move into a
# container). This script wires the gateway the same way as the Hub bridge:
#
#   1. apply the annotated bridge Service           (manifests/strata-bridge.yaml)
#   2. write the EndpointSlice with the Mac's IP    (host-gateway, dynamic —
#      discovered from the node's host.docker.internal, same split as the
#      Hub and registry bridges)
#   3. register the hostname via the annotation     (60-register.sh sync)
#   4. acceptance-check through the gateway         (http + https)
#
# Consumable as a standard model service from anywhere on this Mac:
#   OpenAI-compatible apps:    https://strata.internal/v1  (base URL)
#   Anthropic-compatible apps: https://strata.internal     (ANTHROPIC_BASE_URL)
#
# The engine refuses unknown Host headers (DNS-rebinding protection) until
# "allowed_hosts" in the run config (strata-q2_0.json) names strata.internal
# — the check below names the exact fix if that is still missing.
#
# Idempotent — re-run to converge. If the engine is down the bridge still
# applies; the route serves the moment `strata launch` is up again.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STRATA_NS=${STRATA_NS:-$GW_NS}
STRATA_SVC=${STRATA_SVC:-strata-bridge}
STRATA_PORT=${STRATA_PORT:-8080}
# Docker Desktop's internal host-gateway — stable, but discover it from the
# node instead of hardcoding (falls back to the well-known address).
STRATA_HOST_IP=${STRATA_HOST_IP:-$(docker exec "${KIND_CLUSTER_NAME}-control-plane" \
  getent hosts host.docker.internal 2>/dev/null | awk '{print $1}' | head -1)}
STRATA_HOST_IP=${STRATA_HOST_IP:-192.168.65.254}

say "Strata model-service bridge (strata.$DOMAIN -> host ${STRATA_HOST_IP}:${STRATA_PORT})"

# ── 1. bridge Service (annotation-driven registration) ────────────────
say "Applying bridge Service ${STRATA_NS}/${STRATA_SVC}..."
apply_manifest strata-bridge.yaml

# ── 2. EndpointSlice with the Mac's IP (update only when changed) ─────
have_ip="$(kctl -n "$STRATA_NS" get endpointslice -l \
  "kubernetes.io/service-name=${STRATA_SVC}" \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || true)"
if [[ "$have_ip" != "$STRATA_HOST_IP" ]]; then
  say "Writing EndpointSlice endpoint ${have_ip:-<none>} -> ${STRATA_HOST_IP}..."
  kctl -n "$STRATA_NS" apply -f - >/dev/null <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${STRATA_SVC}
  namespace: ${STRATA_NS}
  labels:
    kubernetes.io/service-name: ${STRATA_SVC}
    app.kubernetes.io/managed-by: kind-infra
addressType: IPv4
endpoints:
  - addresses:
      - ${STRATA_HOST_IP}
ports:
  - name: http
    port: ${STRATA_PORT}
    protocol: TCP
EOF
else
  say "EndpointSlice already points at ${STRATA_HOST_IP} — unchanged."
fi

# ── 3. hostname registration (annotation -> HTTPRoute + TLS SAN) ──────
say "Registering strata.$DOMAIN (60-register.sh sync)..."
bash "$ROOT_DIR/scripts/60-register.sh" sync >/dev/null
refresh_gateway_cert

# ── 3b. kagent ModelConfig (agents in the cluster can opt into the model) ─
if kctl get ns kagent >/dev/null 2>&1 && kctl get crd modelconfigs.api.kagent.dev >/dev/null 2>&1; then
  say "Applying kagent ModelConfig strata-model-config..."
  kctl apply -f "$ROOT_DIR/manifests/strata-model-config.yaml" >/dev/null
fi

# ── 4. acceptance check through the gateway ───────────────────────────
sleep 2
engine_up="$(curl -s -m 5 "http://127.0.0.1:${STRATA_PORT}/health" 2>/dev/null || true)"
if [[ "$engine_up" != *ok* ]]; then
  warn "The Strata engine is not answering on 127.0.0.1:${STRATA_PORT} — route applied anyway;"
  warn "start it with: strata launch --model q2_0 --yes --no-tui"
fi
health="$(curl -s -m 8 "http://strata.${DOMAIN}/health" 2>/dev/null || true)"
case "$health" in
  *ok*)
    tls_code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 "https://strata.${DOMAIN}/health" 2>/dev/null || true)"
    ok "Strata model     http(s)://strata.${DOMAIN}  (host bridge -> ${STRATA_HOST_IP}:${STRATA_PORT})"
    [[ "$tls_code" == "200" ]] || warn "https health returned HTTP ${tls_code:-none} (http works)"
    ;;
  *"not allowed"*)
    die "strata.$DOMAIN reached the engine but it refused the Host header — add \"allowed_hosts\": [\"strata.internal\"] to ~/workspace/Strata/strata-q2_0.json and restart: strata launch --stop && strata launch --model q2_0 --yes --no-tui"
    ;;
  *)
    die "strata.$DOMAIN health check failed (${health:-no answer}) — engine up? kubectl -n ${STRATA_NS} get httproute,endpointslice"
    ;;
esac
