#!/usr/bin/env bash
#
# Internal website hosting — `make site-deploy`.
#
# Serves the personal site from ../baladengale.github.io inside the cluster:
#   1. build the image (multi-stage: markdown render -> nginx)
#   2. side-load it into the kind nodes (deployment uses IfNotPresent)
#   3. apply the site repo's deploy/ manifests in order:
#      namespace -> deployment -> service -> route (baladengale.internal)
#   4. restart the rollout (the tag is always :latest) and refresh the
#      Gateway cert SAN for the hostname
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SITE_DIR="${SITE_DIR:-$ROOT_DIR/../baladengale.github.io}"
SITE_NS="baladengale"
SITE_NAME="baladengale-site"
SITE_IMAGE="baladengale-site:latest"
SITE_HOST="baladengale"

require kubectl kind "$CONTAINER_RUNTIME"
cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."
kctl -n "$GW_NS" get gateway "$GW_NAME" >/dev/null 2>&1 \
  || die "Gateway '${GW_NAME}' not found — run 'make create' first."
[[ -f "$SITE_DIR/Dockerfile" ]] || die "Site checkout not found at ${SITE_DIR} — set SITE_DIR=..."

# kind needs the experimental flag when the runtime is podman.
[[ "$CONTAINER_RUNTIME" == "podman" ]] && export KIND_EXPERIMENTAL_PROVIDER=podman

say "Building ${SITE_IMAGE} from ${SITE_DIR}..."
"$CONTAINER_RUNTIME" build -t "$SITE_IMAGE" "$SITE_DIR"

say "Loading ${SITE_IMAGE} into cluster '${KIND_CLUSTER_NAME}'..."
kind load docker-image "$SITE_IMAGE" --name "$KIND_CLUSTER_NAME"

# Apply in sequence: namespace first, then the workload, its Service, and
# the HTTPS route that puts it on https://baladengale.internal.
for manifest in namespace.yaml deployment.yaml service.yaml route.yaml; do
  say "Applying ${SITE_DIR}/deploy/${manifest}..."
  kctl apply -f "$SITE_DIR/deploy/$manifest"
done

# The tag is always :latest and the image is side-loaded into the nodes, so
# apply alone won't roll pods on a content-only change — restart to pick it up.
say "Restarting rollout (pick up the new :latest image)..."
kctl -n "$SITE_NS" rollout restart "deploy/${SITE_NAME}"
kctl -n "$SITE_NS" rollout status "deploy/${SITE_NAME}" --timeout=120s

# Explicit SAN for the hostname (strict clients need it; the wildcard
# *.${DOMAIN} alone is not matched by macOS curl/LibreSSL).
refresh_gateway_cert

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  --cacert "$ROOT_DIR/certs/rootCA.pem" \
  "https://${SITE_HOST}.${DOMAIN}" || true)"
case "$code" in
  2*|3*) ok "Site answering at https://${SITE_HOST}.${DOMAIN} (HTTP ${code})" ;;
  *)     warn "Site not answering yet (HTTP ${code}) — check: kctl -n ${SITE_NS} get pods" ;;
esac
