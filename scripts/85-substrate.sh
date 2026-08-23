#!/usr/bin/env bash
#
# Agent Substrate platform wrapper — `make create SUBSTRATE_ENABLED=true` and
# `make substrate-create` install it; `make status` reports on it;
# `make substrate-delete` removes it.
#
# Installs the substrate platform (substrate-crds + substrate charts) in the
# ate-system namespace from the published OCI charts, and mirrors the ateom
# gVisor worker image into the local registry. Wiring kagent to the platform
# happens in scripts/80-kagent.sh (SUBSTRATE_ENABLED) — the kagent controller
# dials ate-api at startup, so this platform MUST be installed and healthy
# before kagent is deployed with substrate enabled.
#
# Substrate v0.0.20 runs its own pod-identity CA (podcertificate-controller,
# ClusterTrustBundles) and an actor-identity CA. On a bare cluster those CAs
# don't exist yet, so a one-time bootstrap is required after the first chart
# install — the `kubectl-ate` CLI creates the pool secrets, then the actor-id
# CA root + JWT auth config are derived into ate-system (same sequence as the
# kagent repo's E2E CI, .github/workflows/ci.yaml). The bootstrap is skipped
# when the pools already exist (regenerating them would invalidate issued
# pod certs), so re-runs are safe.
#
# Modes:
#   install    mirror the ateom image into the local registry, then install
#              and bootstrap substrate-crds + substrate (ate-system)
#   status     show platform pods, WorkerPools, actors and release state
#   uninstall  helm-uninstall substrate + substrate-crds (cluster stays)
#
# Versions: https://github.com/orgs/kagent-dev/packages?repo_name=substrate
# Override per-run:  make create SUBSTRATE_ENABLED=true SUBSTRATE_VERSION=0.0.20
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SUBSTRATE_CHART_REPO="oci://ghcr.io/kagent-dev/substrate/helm" # ${SUBSTRATE_CHART_REPO}/substrate{,-crds}
SUBSTRATE_ATEOM_SRC="ghcr.io/kagent-dev/substrate/ateom-gvisor:v${SUBSTRATE_VERSION}"
SUBSTRATE_ATEOM_LOCAL="${REG_HOST}/kagent-dev/substrate/ateom-gvisor:v${SUBSTRATE_VERSION}"
PODCERT_NS="podcertificate-controller-system"

manifest_cached() { # <repo> <tag> — image already in the local registry?
  curl -sf -o /dev/null \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    --cacert "$ROOT_DIR/certs/rootCA.pem" \
    "https://${REG_HOST}/v2/$1/manifests/$2"
}

# Mirror the ateom gVisor worker image so atelet pulls it from the local
# registry instead of ghcr (same caching pattern as scripts/80-kagent.sh).
mirror_ateom() {
  local repo="kagent-dev/substrate/ateom-gvisor" tag="v${SUBSTRATE_VERSION}"
  if manifest_cached "$repo" "$tag"; then
    ok "cached    ${REG_HOST}/${repo}:${tag}"
    return 0
  fi
  say "mirroring ${SUBSTRATE_ATEOM_SRC}"
  local i
  for i in 1 2 3; do
    "$CONTAINER_RUNTIME" pull "$SUBSTRATE_ATEOM_SRC" >/dev/null && break
    warn "pull of ${SUBSTRATE_ATEOM_SRC} failed (attempt $i/3), retrying in 10s..."
    sleep 10
  done
  "$CONTAINER_RUNTIME" image inspect "$SUBSTRATE_ATEOM_SRC" >/dev/null 2>&1 \
    || die "could not pull ${SUBSTRATE_ATEOM_SRC}"
  "$CONTAINER_RUNTIME" tag  "$SUBSTRATE_ATEOM_SRC" "$SUBSTRATE_ATEOM_LOCAL"
  "$CONTAINER_RUNTIME" push "$SUBSTRATE_ATEOM_LOCAL" >/dev/null
  ok "mirrored  ${SUBSTRATE_ATEOM_LOCAL}"
}

# Fetch kubectl-ate (the substrate admin CLI) for this machine's os/arch.
kubectl_ate() {
  local os arch bin
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"; [[ "$arch" = "x86_64" ]] && arch="amd64"
  bin="$ROOT_DIR/tools/kubectl-ate-${SUBSTRATE_VERSION}"
  if [[ ! -x "$bin" ]]; then
    mkdir -p "$ROOT_DIR/tools"
    say "Downloading kubectl-ate ${SUBSTRATE_VERSION} (${os}/${arch})..."
    curl -fsSL -o "$bin" \
      "https://github.com/kagent-dev/substrate/releases/download/v${SUBSTRATE_VERSION}/kubectl-ate-${os}-${arch}" \
      || die "could not download kubectl-ate — check https://github.com/kagent-dev/substrate/releases/tag/v${SUBSTRATE_VERSION}"
    chmod +x "$bin"
  fi
  printf '%s\n' "$bin"
}

# One-time CA/JWT pool bootstrap (skipped when the pools already exist —
# regenerating them would invalidate every issued pod certificate).
bootstrap_pools() {
  if kctl -n "$PODCERT_NS" get secret service-dns-ca-pool >/dev/null 2>&1 \
     && kctl -n "$PODCERT_NS" get secret pod-identity-ca-pool >/dev/null 2>&1 \
     && kctl -n "$SUBSTRATE_NS" get secret actor-id-ca-pool >/dev/null 2>&1; then
    ok "cached    substrate CA/JWT pools already bootstrapped"
    return 0
  fi
  say "Bootstrapping substrate CA/JWT pools (one-time)..."
  local ate
  ate="$(kubectl_ate)"
  "$ate" --context "$KUBE_CONTEXT" admin make-ca-pool --ca-id=1 \
    --name=service-dns-ca-pool --secret-namespace="$PODCERT_NS" >/dev/null
  "$ate" --context "$KUBE_CONTEXT" admin make-ca-pool --ca-id=1 \
    --name=pod-identity-ca-pool --secret-namespace="$PODCERT_NS" >/dev/null
  "$ate" --context "$KUBE_CONTEXT" admin make-jwt-pool --key-id=1 \
    --name=actor-id-jwt-pool --secret-namespace="$SUBSTRATE_NS" >/dev/null
  "$ate" --context "$KUBE_CONTEXT" admin make-ca-pool --ca-id=1 \
    --name=actor-id-ca-pool --secret-namespace="$SUBSTRATE_NS" >/dev/null
  ok "bootstrap  substrate CA/JWT pools created"
}

# Derive the ate-system trust + auth objects from the actor-id CA pool
# (kubectl apply — idempotent, same sequence as the kagent repo's CI).
bootstrap_actor_id() {
  local ca_root
  ca_root="$(kctl -n "$SUBSTRATE_NS" get secret actor-id-ca-pool \
    -o jsonpath='{.data.pool}' | base64 --decode \
    | jq -r '.CAs[0].RootCertificateDER' | base64 --decode \
    | openssl x509 -inform der -outform pem)"
  [[ -n "$ca_root" ]] || die "could not read the actor-id CA from secret actor-id-ca-pool"

  kctl -n "$SUBSTRATE_NS" create secret generic actor-id-ca-certs \
    --from-literal=ca.crt="$ca_root" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null

  kctl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ate-api-authentication
  namespace: $SUBSTRATE_NS
data:
  authentication.yaml: |
    actorIdentityJWTProvider: kubernetes
    jwtProviders:
    - name: kubernetes
      issuer: https://kubernetes.default.svc
      audiences: [api.ate-system.svc]
      certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
EOF
  ok "bootstrap  actor-id CA certs + ate-api authentication config"
}

platform_installed() { # helm release 'substrate' present in ate-system?
  cluster_exists && helm ls -n "$SUBSTRATE_NS" --kube-context "$KUBE_CONTEXT" \
    -o json 2>/dev/null | jq -e '.[]? | select(.name == "substrate")' >/dev/null 2>&1
}

cmd_install() {
  require kubectl helm curl jq openssl base64 "$CONTAINER_RUNTIME"
  cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."
  kctl -n "$GW_NS" get gateway "$GW_NAME" >/dev/null 2>&1 \
    || die "Gateway '${GW_NAME}' not found — run 'make create' first."
  [[ -f "$ROOT_DIR/certs/rootCA.pem" ]] \
    || die "Missing $ROOT_DIR/certs/rootCA.pem — run 'bash scripts/30-gateway.sh' first."

  mirror_ateom

  say "Installing substrate-crds ${SUBSTRATE_VERSION} (upstream OCI chart)..."
  helm upgrade --install substrate-crds "${SUBSTRATE_CHART_REPO}/substrate-crds" \
    --version "$SUBSTRATE_VERSION" --namespace "$SUBSTRATE_NS" --create-namespace \
    --kube-context "$KUBE_CONTEXT" --wait --timeout 5m >/dev/null

  # atelet pulls ActorTemplate container images directly (go-containerregistry,
  # NOT containerd), so the containerd certs.d wiring on the nodes does not
  # apply to it. --localhost-registry-replacement rewrites the localhost:PORT
  # image refs kagent renders in substrate mode to the in-cluster
  # kind-registry Service (plain HTTP on the internal port); atelet treats
  # rewritten refs as insecure, so no TLS hop is needed.
  #
  # First pass WITHOUT --wait: the pods cannot start until the CA/JWT pools
  # below exist, so waiting here would just burn the timeout. The bootstrap
  # runs, then a --reuse-values upgrade waits for the real convergence.
  say "Installing substrate ${SUBSTRATE_VERSION} (ate-system, kind registry settings)..."
  helm upgrade --install substrate "${SUBSTRATE_CHART_REPO}/substrate" \
    --version "$SUBSTRATE_VERSION" --namespace "$SUBSTRATE_NS" \
    --kube-context "$KUBE_CONTEXT" --timeout 5m \
    --set atelet.gcpAuthForImagePulls=false \
    --set-json "atelet.extraArgs=[\"--localhost-registry-replacement=${SUBSTRATE_REG_REWRITE}\"]" \
    >/dev/null

  bootstrap_pools
  bootstrap_actor_id

  say "Waiting for the substrate platform to converge..."
  helm upgrade substrate "${SUBSTRATE_CHART_REPO}/substrate" \
    --version "$SUBSTRATE_VERSION" --namespace "$SUBSTRATE_NS" \
    --kube-context "$KUBE_CONTEXT" --reuse-values --wait --timeout 10m >/dev/null

  ok "substrate platform installed in '${SUBSTRATE_NS}'"
  echo "   Wire kagent to it with: make kagent-deploy SUBSTRATE_ENABLED=true"
}

cmd_status() {
  require kubectl
  if ! platform_installed; then
    if [[ "${1:-}" = "true" ]]; then
      echo "== substrate =="
      echo "   (substrate not installed — run: make substrate-create)"
    fi
    return 0
  fi
  echo "== substrate (${SUBSTRATE_NS}) =="
  kctl -n "$SUBSTRATE_NS" get pods 2>/dev/null || true
  echo "== workerpools =="
  kctl get workerpools -A 2>/dev/null \
    || echo "   (no WorkerPools — kagent is not wired to substrate yet: make kagent-deploy SUBSTRATE_ENABLED=true)"
  echo "== actors =="
  kctl get actors -A 2>/dev/null || echo "   (no actors — none have run yet)"
}

cmd_uninstall() {
  require helm
  if ! cluster_exists; then
    warn "Cluster '${KIND_CLUSTER_NAME}' not running — nothing to uninstall."
    return 0
  fi
  say "Uninstalling substrate releases..."
  helm uninstall substrate      --namespace "$SUBSTRATE_NS" --kube-context "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  helm uninstall substrate-crds --namespace "$SUBSTRATE_NS" --kube-context "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  ok "substrate platform removed (cluster and ateom mirror stay)"
}

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  install)    cmd_install ;;
  status)     cmd_status "${2:-}" ;;
  uninstall)  cmd_uninstall ;;
  *)          usage ;;
esac
