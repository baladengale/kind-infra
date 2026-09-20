#!/usr/bin/env bash
#
# OIE Hub route — expose the Mac-hosted Hub at https://hub.internal.
#
# The Hub does NOT run in the cluster: it is a LaunchAgent on this Mac
# (com.oie.hub, 127.0.0.1:8765 — repo ~/workspace/options, see
# deploy/hub/install.sh). This script therefore only wires the gateway:
#
#   1. apply the annotated bridge Service           (manifests/hub-bridge.yaml)
#   2. write the EndpointSlice with the Mac's IP    (host-gateway, dynamic —
#      discovered from the node's host.docker.internal, same split as the
#      registry bridge in 50-registry.sh)
#   3. register the hostname via the annotation     (60-register.sh sync)
#   4. acceptance-check through the gateway         (http + https)
#
# Idempotent — re-run to converge (picks up Hub/service changes).
# If the Hub is down the bridge still applies; the route serves the moment
# the LaunchAgent is back (KeepAlive).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HUB_NS=${HUB_NS:-$GW_NS}
HUB_SVC=${HUB_SVC:-oie-hub-bridge}
HUB_PORT=${HUB_PORT:-8765}
# Docker Desktop's internal host-gateway — stable, but discover it from the
# node instead of hardcoding (falls back to the well-known address).
HUB_HOST_IP=${HUB_HOST_IP:-$(docker exec "${KIND_CLUSTER_NAME}-control-plane" \
  getent hosts host.docker.internal 2>/dev/null | awk '{print $1}' | head -1)}
HUB_HOST_IP=${HUB_HOST_IP:-192.168.65.254}

say "OIE Hub bridge (hub.$DOMAIN -> host ${HUB_HOST_IP}:${HUB_PORT})"

# ── 1. bridge Service (annotation-driven registration) ────────────────
say "Applying bridge Service ${HUB_NS}/${HUB_SVC}..."
apply_manifest hub-bridge.yaml

# ── 2. EndpointSlice with the Mac's IP (update only when changed) ─────
have_ip="$(kctl -n "$HUB_NS" get endpointslice -l \
  "kubernetes.io/service-name=${HUB_SVC}" \
  -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || true)"
if [[ "$have_ip" != "$HUB_HOST_IP" ]]; then
  say "Writing EndpointSlice endpoint ${have_ip:-<none>} -> ${HUB_HOST_IP}..."
  kctl -n "$HUB_NS" apply -f - >/dev/null <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${HUB_SVC}
  namespace: ${HUB_NS}
  labels:
    kubernetes.io/service-name: ${HUB_SVC}
    app.kubernetes.io/managed-by: kind-infra
addressType: IPv4
endpoints:
  - addresses:
      - ${HUB_HOST_IP}
ports:
  - name: http
    port: ${HUB_PORT}
    protocol: TCP
EOF
else
  say "EndpointSlice already points at ${HUB_HOST_IP} — unchanged."
fi

# ── 3. hostname registration (annotation -> HTTPRoute + TLS SAN) ──────
say "Registering hub.${DOMAIN} (60-register.sh sync)..."
bash "$ROOT_DIR/scripts/60-register.sh" sync >/dev/null
refresh_gateway_cert

# ── 4. acceptance check through the gateway ───────────────────────────
sleep 2
hub_up="$(curl -s -m 5 "http://127.0.0.1:${HUB_PORT}/healthz" 2>/dev/null || true)"
if [[ "$hub_up" != *ok* ]]; then
  warn "The Hub is not answering on 127.0.0.1:${HUB_PORT} — route applied anyway;"
  warn "start it with: launchctl kickstart -k gui/\$(id -u)/com.oie.hub"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://hub.${DOMAIN}/healthz" 2>/dev/null || true)"
if [[ "$code" == "200" ]]; then
  ok "OIE Hub        http://hub.${DOMAIN}   (host bridge -> ${HUB_HOST_IP}:${HUB_PORT})"
else
  die "hub.${DOMAIN} health check failed (HTTP ${code:-none}) — see deploy/README.md §4"
fi
