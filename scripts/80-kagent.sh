#!/usr/bin/env bash
#
# kagent deployment wrapper — `make kagent-deploy` / `make kagent-build-deploy`
# / `make kagent-delete`.
#
# Deploys kagent onto the kind-infra cluster with everything served from the
# local registry, and exposes the UI at https://kagent.${DOMAIN} through the
# shared AgentGateway. The kagent code lives in ../kagent — this repo only
# holds the deployment wrapper and its customization defaults.
#
# Modes:
#   deploy        upstream release: mirror the published images into the local
#                 registry (local cache — the cluster never pulls from ghcr)
#                 and install the upstream OCI chart.
#   build-deploy  build the ../kagent checkout and push into the local
#                 registry via localhost:${REG_PORT} (buildkit treats
#                 localhost as insecure), then install the LOCAL chart.
#   delete        uninstall both releases and remove the hostname route.
#
# Token reading (wrapper default: Anthropic provider):
#   ANTHROPIC_API_KEY  required — from the environment or a gitignored .env at
#                      the repo root (see kagent/env.example)
#   KAGENT_MODEL       optional model override
#   KAGENT_BASE_URL    optional Anthropic-compatible endpoint (e.g. DeepSeek)
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================================
# kagent upstream release configuration — THE tuning block. Every upstream
# version and image path lives here; nothing below should need editing.
#
# Published versions: https://github.com/orgs/kagent-dev/packages?repo_name=kagent
# (images) — chart lives at oci://ghcr.io/kagent-dev/kagent/helm/{kagent,
# kagent-crds}. Note: image tags sort lexicographically in the ghcr UI/API,
# so 0.10.x is listed before 0.7.x — check the UI or probe a tag directly.
#
# Override the release per-run:  make kagent-deploy KAGENT_VERSION=0.7.9
# (older releases may not have all images below — trim CORE/EXTRA to match).
# ============================================================================
KAGENT_VERSION="${KAGENT_VERSION:-0.10.0-rc2}"  # chart tag + main image tag
KAGENT_IMAGE_PREFIX="ghcr.io/kagent-dev/kagent" # upstream main images
CHART_REPO="oci://ghcr.io/kagent-dev/kagent/helm" # charts: ${CHART_REPO}/kagent{,-crds}

# Chart-referenced images (tag = KAGENT_VERSION):
CORE_IMAGES="controller ui app skills-init golang-adk"
# Extra images cached for local use, same tag (edit to taste):
EXTRA_IMAGES="app-full golang-adk-full kagent-adk kagent-adk-full"
#  (available but not mirrored by default — uncomment to cache:)
#EXTRA_IMAGES="$EXTRA_IMAGES acp-sandbox-hermes acp-sandbox-openclaw acp-sandbox-claude"

# Dependency versions (each on its own release cadence, not KAGENT_VERSION):
TOOLS_TAG="0.2.1"    # kagent-tools image (ghcr.io/kagent-dev/kagent/tools)
KMCP_TAG="0.3.0"     # kmcp image (ghcr.io/kagent-dev/kmcp/controller)
QUERYDOC_TAG="1.1.14" # querydoc image (ghcr.io/kagent-dev/doc2vec/mcp)

# Dependency images mirrored alongside: "<source>|<repo in kind-registry>"
DEP_IMAGES=(
  "ghcr.io/kagent-dev/kagent/tools:${TOOLS_TAG}|kagent-dev/kagent/tools:${TOOLS_TAG}"
  "ghcr.io/kagent-dev/kmcp/controller:${KMCP_TAG}|kagent-dev/kmcp/controller:${KMCP_TAG}"
  "ghcr.io/kagent-dev/doc2vec/mcp:${QUERYDOC_TAG}|kagent-dev/doc2vec/mcp:${QUERYDOC_TAG}"
  "docker.io/mcp/grafana:latest|mcp/grafana:latest"                           # grafana-mcp
)

# --- cluster-side settings ---------------------------------------------------
KAGENT_NS="kagent"
KAGENT_UI_HOST="kagent"                # -> https://kagent.${DOMAIN}
KAGENT_DIR="${KAGENT_DIR:-$ROOT_DIR/../kagent}"
REG_HOST="kind-registry.${DOMAIN}"

# Full mirror list for 'deploy' mode, built from the block above.
# Names ending in "-full" are tag variants (repo app + tag <version>-full),
# not separate repositories.
UPSTREAM_IMAGES=()
_img=""
for _img in $CORE_IMAGES $EXTRA_IMAGES; do
  case "$_img" in
    *-full) UPSTREAM_IMAGES+=("${KAGENT_IMAGE_PREFIX}/${_img%-full}:${KAGENT_VERSION}-full|kagent-dev/kagent/${_img%-full}:${KAGENT_VERSION}-full") ;;
    *)      UPSTREAM_IMAGES+=("${KAGENT_IMAGE_PREFIX}/${_img}:${KAGENT_VERSION}|kagent-dev/kagent/${_img}:${KAGENT_VERSION}") ;;
  esac
done
UPSTREAM_IMAGES+=("${DEP_IMAGES[@]}")
unset _img

read_token() {
  [[ -f "$ROOT_DIR/.env" ]] && { set -a; . "$ROOT_DIR/.env"; set +a; }
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] \
    || die "ANTHROPIC_API_KEY not set — copy kagent/env.example to .env and fill it in (see README)."
}

# Helm values for the model provider, built after read_token().
provider_sets() {
  local -a args=(--set providers.default=anthropic
                 --set "providers.anthropic.apiKey=${ANTHROPIC_API_KEY}")
  [[ -n "${KAGENT_MODEL:-}" ]]    && args+=(--set "providers.anthropic.model=${KAGENT_MODEL}")
  [[ -n "${KAGENT_BASE_URL:-}" ]] && args+=(--set "providers.anthropic.config.baseUrl=${KAGENT_BASE_URL}")
  printf '%s\n' "${args[@]}"
}

# Fix a packaged kagent chart for install: the agent subcharts render an
# empty `spec.declarative.deployment:` (null), which the Agent CRD rejects,
# and render fields the CRD schema doesn't declare (a2aConfig.resources),
# which server-side apply rejects. Drop those lines; the manifests then
# install cleanly with --server-side=false.
patch_chart() { # <extracted chart dir>
  sed -i '' '/^    deployment:$/d' "$1"/charts/*/templates/agent.yaml 2>/dev/null || true
}

manifest_cached() { # <repo> <tag> — image already in the local registry?
  curl -sf -o /dev/null \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    --cacert "$ROOT_DIR/certs/rootCA.pem" \
    "https://${REG_HOST}/v2/$1/manifests/$2"
}

mirror_pull() { # <image> — ghcr rate-limits bursts of anonymous pulls; retry
  local i
  for i in 1 2 3; do
    "$CONTAINER_RUNTIME" pull "$1" >/dev/null && return 0
    warn "pull of $1 failed (attempt $i/3), retrying in 10s..."
    sleep 10
  done
  die "could not pull $1"
}

mirror_images() {
  say "Mirroring upstream kagent images into ${REG_HOST} (local cache)..."
  local src repo tag entry
  for entry in "${UPSTREAM_IMAGES[@]}"; do
    src="${entry%%|*}"; entry="${entry#*|}"
    repo="${entry%:*}"; tag="${entry##*:}"
    if manifest_cached "$repo" "$tag"; then
      ok "cached    ${REG_HOST}/${repo}:${tag}"
      continue
    fi
    say "mirroring ${src}"
    mirror_pull "$src"
    "$CONTAINER_RUNTIME" tag  "$src" "${REG_HOST}/${repo}:${tag}"
    "$CONTAINER_RUNTIME" push "${REG_HOST}/${repo}:${tag}" >/dev/null
    ok "mirrored  ${REG_HOST}/${repo}:${tag}"
  done
}

expose_ui() {
  say "Exposing kagent UI + MCP at https://${KAGENT_UI_HOST}.${DOMAIN}..."
  # Remove legacy separate routes if they exist, then apply the consolidated
  # route (UI + /mcp) from the static manifest.
  kctl -n "$KAGENT_NS" delete httproute kagent-mcp --ignore-not-found >/dev/null 2>&1 || true
  apply_manifest kagent-route.yaml
  refresh_gateway_cert   # explicit SAN for the hostname
}

probe_ui() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    --cacert "$ROOT_DIR/certs/rootCA.pem" \
    "https://${KAGENT_UI_HOST}.${DOMAIN}" || true)"
  case "$code" in
    2*|3*|401) ok "UI answering at https://${KAGENT_UI_HOST}.${DOMAIN} (HTTP ${code})" ;;
    *)         warn "UI not answering yet (HTTP ${code}) — check: kctl -n ${KAGENT_NS} get pods" ;;
  esac
}

cmd_deploy() {
  require kubectl helm "$CONTAINER_RUNTIME" curl
  cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."
  kctl -n "$GW_NS" get gateway "$GW_NAME" >/dev/null 2>&1 \
    || die "Gateway '${GW_NAME}' not found — run 'make create' first."
  read_token

  mirror_images
  # bash 3.2 (macOS) has no mapfile — read provider sets line by line.
  local -a sets=()
  while IFS= read -r s; do sets+=("$s"); done < <(provider_sets)

  say "Installing kagent-crds ${KAGENT_VERSION} (upstream OCI chart)..."
  helm upgrade --install kagent-crds "${CHART_REPO}/kagent-crds" \
    --version "$KAGENT_VERSION" --namespace "$KAGENT_NS" --create-namespace \
    --kube-context "$KUBE_CONTEXT" --wait --timeout 5m >/dev/null

  # Pull the upstream chart, extract, and patch it (see patch_chart).
  local tmp chart_dir
  tmp="$(mktemp -d)"
  helm pull "${CHART_REPO}/kagent" \
    --version "$KAGENT_VERSION" -d "$tmp" >/dev/null
  tar -xzf "$tmp/kagent-${KAGENT_VERSION}.tgz" -C "$tmp"
  chart_dir="$tmp/kagent"
  patch_chart "$chart_dir"

  say "Installing kagent ${KAGENT_VERSION} (upstream OCI chart, images from ${REG_HOST})..."
  # --server-side=false: the agent manifests render fields the CRD schema
  # doesn't declare (e.g. a2aConfig.resources) — server-side apply rejects
  # those, client-side apply is fine.
  helm upgrade --install kagent "$chart_dir" \
    --namespace "$KAGENT_NS" --create-namespace \
    --kube-context "$KUBE_CONTEXT" \
    --server-side=false \
    --set "registry=${REG_HOST}" --set "tag=${KAGENT_VERSION}" \
    --set imagePullPolicy=IfNotPresent \
    --set "kmcp.image.repository=${REG_HOST}/kagent-dev/kmcp/controller" \
    --set "kagent-tools.image.registry=${REG_HOST}" --set "kagent-tools.image.tag=${TOOLS_TAG}" \
    --set "querydoc.image.registry=${REG_HOST}" \
    --set "grafana-mcp.image.registry=${REG_HOST}" --set "grafana-mcp.image.repository=mcp/grafana" \
    "${sets[@]}" \
    -f "$ROOT_DIR/kagent/values.yaml" --wait --timeout 10m >/dev/null

  expose_ui
  probe_ui
}

cmd_build_deploy() {
  require kubectl helm make git
  cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."
  kctl -n "$GW_NS" get gateway "$GW_NAME" >/dev/null 2>&1 \
    || die "Gateway '${GW_NAME}' not found — run 'make create' first."
  read_token
  [[ -d "$KAGENT_DIR/helm/kagent" ]] || die "kagent checkout not found at ${KAGENT_DIR} — set KAGENT_DIR=..."

  # Same version scheme as the kagent Makefile (git describe), so the images
  # built below match the chart + --set tag.
  local version
  version="$(cd "$KAGENT_DIR" && git describe --tags --always | grep v)"
  say "Building kagent ${version} from ${KAGENT_DIR} into the local registry..."
  make -C "$KAGENT_DIR" \
    DOCKER_REGISTRY="localhost:${REG_PORT}" VERSION="$version" \
    CONTAINER_RUNTIME="$CONTAINER_RUNTIME" \
    buildx-create build-controller build-ui build-app build-skills-init build-golang-adk

  # Refresh Chart.yaml from the template so the chart version matches,
  # then package (pulls the vendored dep charts into the tarball), extract
  # and patch it — the agent manifests need the same fixes as upstream
  # (see patch_chart).
  (cd "$KAGENT_DIR" && VERSION="$version" \
    /opt/homebrew/opt/gettext/bin/envsubst \
    < helm/kagent/Chart-template.yaml > helm/kagent/Chart.yaml)
  local tmp chart_dir
  tmp="$(mktemp -d)"
  helm package "$KAGENT_DIR/helm/kagent" -d "$tmp" >/dev/null
  tar -xzf "$tmp/kagent-${version}.tgz" -C "$tmp"
  chart_dir="$tmp/kagent"
  patch_chart "$chart_dir"

  local -a sets=()
  while IFS= read -r s; do sets+=("$s"); done < <(provider_sets)

  say "Installing kagent-crds (local chart ${KAGENT_DIR}/helm/kagent-crds)..."
  helm upgrade --install kagent-crds "$KAGENT_DIR/helm/kagent-crds" \
    --namespace "$KAGENT_NS" --create-namespace \
    --kube-context "$KUBE_CONTEXT" --wait --timeout 5m >/dev/null

  say "Installing kagent ${version} (local chart, images from ${REG_HOST})..."
  helm upgrade --install kagent "$chart_dir" \
    --namespace "$KAGENT_NS" --create-namespace \
    --kube-context "$KUBE_CONTEXT" \
    --server-side=false \
    --set "registry=${REG_HOST}" --set "tag=${version}" \
    --set imagePullPolicy=Always \
    --set database.postgres.bundled.image.repository=pgvector \
    --set database.postgres.bundled.image.name=pgvector \
    --set database.postgres.bundled.image.tag=pg18-trixie \
    --set database.postgres.vectorEnabled=true \
    "${sets[@]}" \
    -f "$ROOT_DIR/kagent/values.yaml" --wait --timeout 10m >/dev/null

  expose_ui
  probe_ui
}

cmd_delete() {
  require helm
  say "Removing kagent hostname route..."
  # Remove the consolidated kagent HTTPRoute
  kubectl -n "$KAGENT_NS" delete httproute kagent --ignore-not-found >/dev/null 2>&1 || true
  # Also remove any legacy kagent-mcp route
  kubectl -n "$KAGENT_NS" delete httproute kagent-mcp --ignore-not-found >/dev/null 2>&1 || true
  say "Uninstalling kagent releases..."
  helm uninstall kagent     --namespace "$KAGENT_NS" --kube-context "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  helm uninstall kagent-crds --namespace "$KAGENT_NS" --kube-context "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  ok "kagent removed (images stay cached in the local registry)"
}

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  deploy)        cmd_deploy ;;
  build-deploy)  cmd_build_deploy ;;
  delete)        cmd_delete ;;
  *)             usage ;;
esac
