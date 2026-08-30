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
# Agent Substrate (SUBSTRATE_ENABLED=true, set via `make ... SUBSTRATE_ENABLED=true`):
# requires the LOCAL chart + images (build-deploy). The published upstream
# releases predate the podcert wiring the controller needs to talk to the
# substrate v${SUBSTRATE_VERSION} platform (the kagent repo refuses official
# releases for substrate the same way), so `deploy` rejects the flag. Both
# local modes wire the controller to the ate-system platform (installed by
# scripts/85-substrate.sh — it MUST be healthy first, the controller dials
# ate-api at startup) and create the default WorkerPool. In this mode the
# chart's `registry` value switches to localhost:${REG_PORT} so ActorTemplate
# image refs are rewritten by atelet to the in-cluster registry.
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
KAGENT_VERSION="${KAGENT_VERSION:-0.10.0-rc3}"  # chart tag + main image tag
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

# Helm values for Agent Substrate mode (SUBSTRATE_ENABLED=true) — appended
# AFTER the per-mode --sets and BEFORE the -f values files (see cmd_* below).
# Prints nothing when substrate is disabled.
substrate_sets() {
  [[ "$SUBSTRATE_ENABLED" = "true" ]] || return 0
  # The controller dials ate-api unconditionally at startup, so the platform
  # must be installed and healthy before this release is upgraded.
  kctl -n "$SUBSTRATE_NS" get pod -l app=ate-api-server >/dev/null 2>&1 \
    || die "Substrate platform not found in '${SUBSTRATE_NS}' — run: make create SUBSTRATE_ENABLED=true"
  # localhost:PORT registry refs: atelet rewrites them (--localhost-registry-
  # replacement, set by scripts/85-substrate.sh) to the in-cluster registry.
  # kubelet still resolves them via the containerd certs.d wiring, so every
  # other pod image is unaffected.
  printf '%s\n' \
    --set "registry=localhost:${REG_PORT}" \
    --set "substrateWorkerPool.ateomImage=${SUBSTRATE_ATEOM_IMAGE}" \
    -f "$ROOT_DIR/kagent/values-substrate.yaml"
}

# Fix a packaged kagent chart for install: the agent subcharts render a
# `spec.declarative.deployment:` block (older releases render it empty/null,
# which the Agent CRD rejects). Drop the whole block — the key line AND the
# `{{- include "agent.deploymentSpec" }}` line that renders its contents.
# Dropping only the key orphans that content (a `resources:` block) under the
# preceding `a2aConfig:` key, which the CRD then warns about as unknown field
# `spec.declarative.a2aConfig.resources`.
patch_chart() { # <extracted chart dir>
  sed -i '' \
    -e '/^    deployment:$/d' \
    -e '/agent.deploymentSpec/d' \
    "$1"/charts/*/templates/agent.yaml 2>/dev/null || true
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
  # route (UI + /mcp) and the controller-API route (kagent-api.internal, for
  # the CLI/TUI) from the static manifests.
  kctl -n "$KAGENT_NS" delete httproute kagent-mcp --ignore-not-found >/dev/null 2>&1 || true
  apply_manifest kagent-route.yaml
  apply_manifest kagent-api-route.yaml
  refresh_gateway_cert   # explicit SANs for both hostnames
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

# Provision the AgentGateway LLM routing + agw/ark ModelConfigs and secrets
# BEFORE the kagent controller starts. The agents reference agw-cheap-model-
# config as their summarizer; on a fresh cluster the controller can't compile
# the Agents until that ModelConfig exists (their deployments are never
# created and helm --wait times out on Agent readiness). Requires kagent-crds
# and the Gateway to be installed first; safe to run again later (idempotent).
provision_llm_configs() {
  bash "$ROOT_DIR/scripts/35-agentgateway-llm.sh" \
    || warn "agentgateway-llm setup failed — agents stay InProgress until it succeeds (re-run: make agentgateway-llm-setup)"
}

cmd_deploy() {
  require kubectl helm "$CONTAINER_RUNTIME" curl
  # Substrate needs the podcert wiring that only exists in the local chart +
  # locally built controller (see header). Official releases can't talk to
  # the substrate v${SUBSTRATE_VERSION} platform.
  [[ "$SUBSTRATE_ENABLED" = "true" ]] \
    && die "SUBSTRATE_ENABLED=true requires locally built images — run: make kagent-build-deploy SUBSTRATE_ENABLED=true"
  cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."
  kctl -n "$GW_NS" get gateway "$GW_NAME" >/dev/null 2>&1 \
    || die "Gateway '${GW_NAME}' not found — run 'make create' first."
  read_token

  mirror_images
  # bash 3.2 (macOS) has no mapfile — read provider sets line by line.
  local -a sets=() substrate=()
  while IFS= read -r s; do sets+=("$s"); done < <(provider_sets)
  while IFS= read -r s; do substrate+=("$s"); done < <(substrate_sets)

  say "Installing kagent-crds ${KAGENT_VERSION} (upstream OCI chart)..."
  helm upgrade --install kagent-crds "${CHART_REPO}/kagent-crds" \
    --version "$KAGENT_VERSION" --namespace "$KAGENT_NS" --create-namespace \
    --kube-context "$KUBE_CONTEXT" --wait --timeout 5m >/dev/null

  provision_llm_configs

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
    ${substrate[@]+"${substrate[@]}"} \
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
  # Same target order as the kagent repo's `build` target: the agent images
  # (golang-adk) are pushed BEFORE the controller, whose build bakes their
  # manifest digests into the binary (substrate ActorTemplates require
  # digest-pinned refs).
  make -C "$KAGENT_DIR" \
    DOCKER_REGISTRY="localhost:${REG_PORT}" VERSION="$version" \
    CONTAINER_RUNTIME="$CONTAINER_RUNTIME" \
    buildx-create build-ui build-kagent-adk build-golang-adk build-controller

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

  local -a sets=() substrate=()
  while IFS= read -r s; do sets+=("$s"); done < <(provider_sets)
  while IFS= read -r s; do substrate+=("$s"); done < <(substrate_sets)

  say "Installing kagent-crds (local chart ${KAGENT_DIR}/helm/kagent-crds)..."
  helm upgrade --install kagent-crds "$KAGENT_DIR/helm/kagent-crds" \
    --namespace "$KAGENT_NS" --create-namespace \
    --kube-context "$KUBE_CONTEXT" --wait --timeout 5m >/dev/null

  provision_llm_configs

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
    ${substrate[@]+"${substrate[@]}"} \
    -f "$ROOT_DIR/kagent/values.yaml" --wait --timeout 10m >/dev/null

  expose_ui
  probe_ui
}

cmd_delete() {
  require helm
  say "Removing kagent hostname routes..."
  # Remove the consolidated kagent HTTPRoute
  kubectl -n "$KAGENT_NS" delete httproute kagent --ignore-not-found >/dev/null 2>&1 || true
  # Also remove the controller-API route and any legacy kagent-mcp route
  kubectl -n "$KAGENT_NS" delete httproute kagent-api --ignore-not-found >/dev/null 2>&1 || true
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
