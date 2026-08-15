#!/usr/bin/env bash
#
# Create the kind cluster (with host ports 80/443 for ingress) and a local
# container registry wired into every node's containerd.
#
# Adapted from the kind "local registry" guide and the kagent repo
# (scripts/kind/setup-kind.sh, Apache-2.0).
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kind kubectl "$CONTAINER_RUNTIME"

# 1. Registry container (localhost:5001 on the host).
if [ "$("$CONTAINER_RUNTIME" inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null || true)" != 'true' ]; then
  say "Starting local registry ${REG_NAME} on 127.0.0.1:${REG_PORT}..."
  "$CONTAINER_RUNTIME" run -d --restart=always \
    -p "127.0.0.1:${REG_PORT}:${REG_INTERNAL_PORT}" --network bridge --name "$REG_NAME" \
    registry:2
else
  ok "Registry ${REG_NAME} already running"
fi

# 2. Cluster (skipped if it exists — use `make upgrade` to recreate).
if cluster_exists; then
  ok "Cluster '${KIND_CLUSTER_NAME}' already exists; skipping create"
else
  say "Creating kind cluster '${KIND_CLUSTER_NAME}' (Kubernetes v${KIND_IMAGE_VERSION})..."
  # When using podman, kind needs the experimental provider flag.
  export KIND_EXPERIMENTAL_PROVIDER="$CONTAINER_RUNTIME"
  kind create cluster \
    --name "$KIND_CLUSTER_NAME" \
    --config "$ROOT_DIR/kind/kind-config.yaml" \
    --image "kindest/node:v${KIND_IMAGE_VERSION}"
fi

# 3. Alias localhost:${REG_PORT} to the registry container inside each node.
#    (localhost is network-namespace local, so nodes must be told where it is.)
say "Wiring registry into containerd on every node..."
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "$KIND_CLUSTER_NAME"); do
  "$CONTAINER_RUNTIME" exec "$node" mkdir -p "$REGISTRY_DIR"
  cat <<EOF | "$CONTAINER_RUNTIME" exec -i "$node" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."${REG_SCHEME}://${REG_NAME}:${REG_INTERNAL_PORT}"]
  skip_verify = true
EOF
done

# 4. Attach the registry to the kind network.
if [ "$("$CONTAINER_RUNTIME" inspect -f='{{json .NetworkSettings.Networks.kind}}' "$REG_NAME")" = 'null' ]; then
  "$CONTAINER_RUNTIME" network connect kind "$REG_NAME"
fi

# 5. Advertise the registry (https://kind.sigs.k8s.io/docs/user/local-registry/).
apply_manifest local-registry-hosting.yaml

ok "Cluster + registry ready (push/pull images via localhost:${REG_PORT})"
