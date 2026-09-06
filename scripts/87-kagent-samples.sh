#!/usr/bin/env bash
#
# Sample agent on Agent Substrate — `make substrate-samples` deploys it,
# `make substrate-validate` runs the end-to-end check, `make substrate-status`
# includes its state. `bash scripts/87-kagent-samples.sh delete` removes it.
#
# Deploys the sample Harness (kagent runtime adapter) + hello-substrate
# AgentTemplate, then creates one AgentInstance from them via the kagent CLI
# so there is always a live reference agent to inspect:
#
#   kubectl get harness,agenttemplate -n kagent   # platform-side objects
#   kagent get agent-instance                     # control-plane instances
#   UI: https://kagent.internal -> chat with hello-substrate
#   View -> Substrate: the actor sits Suspended between requests
#
# The Harness workload image must be DIGEST-pinned (CRD validation), so
# install resolves the golang-adk digest from the local registry — the image
# that `make kagent-build-deploy` pushed. Run it AFTER kagent is deployed
# (substrate-create does; scripts/00-up.sh does when SUBSTRATE_ENABLED=true).
#
# Validate (also: make substrate-validate) asks the agent where it runs; the
# expected answer describes the gVisor substrate actor from its system prompt.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

KAGENT_NS=${KAGENT_NS:-kagent}
KAGENT_DIR=${KAGENT_DIR:-$ROOT_DIR/../kagent}
SAMPLE_TEMPLATE="hello-substrate"
SAMPLE_HARNESS="kagent"
SAMPLES_DIR="$ROOT_DIR/kagent/samples"

harness_image() { # digest-pinned golang-adk matching the DEPLOYED kagent build
  local tag digest
  tag="$(kctl get deploy kagent-controller -n "$KAGENT_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')"
  [[ -n "$tag" ]] || die "cannot read the deployed controller image tag — is kagent deployed?"
  local digest
  digest="$(curl -sfI -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://localhost:${REG_PORT}/v2/kagent-dev/kagent/golang-adk/manifests/${tag}" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')"
  [[ -n "$digest" ]] || die "golang-adk:${tag} not found in localhost:${REG_PORT} — run: make kagent-build-deploy"
  printf 'localhost:%s/kagent-dev/kagent/golang-adk@%s\n' "$REG_PORT" "$digest"
}

cli_bin() { # build the kagent CLI from ../kagent when missing
  local bin="$KAGENT_DIR/go/core/bin/kagent-local"
  if [[ ! -x "$bin" ]]; then
    say "Building the kagent CLI (one-time)..."
    make -C "$KAGENT_DIR/go" core/bin/kagent-local >/dev/null
  fi
  printf '%s\n' "$bin"
}

instances_json() { "$1" get agent-instance -o json 2>/dev/null || echo '{}'; }

sample_instance_id() { # <cli-bin> — ID of an existing sample instance, if any
  local json
  json="$(instances_json "$1")"
  printf '%s' "$json" | jq -r '(.agentInstances // .instances // [])[]?
    | select((.agentTemplate.name // .agentTemplate // "") == "hello-substrate")
    | .id' 2>/dev/null | head -1
}

wait_template_ready() { # <cli-bin missing: kubectl wait on the template condition>
  say "Waiting for the Harness to compile ${SAMPLE_TEMPLATE}..."
  local i ready=""
  for i in $(seq 1 36); do
    ready="$(kctl get agenttemplate "$SAMPLE_TEMPLATE" -n "$KAGENT_NS" -o jsonpath='{.status.harnesses[?(@.harness=="kagent")].conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "$ready" = "True" ]] && break
    sleep 5
  done
  [[ "$ready" = "True" ]] || die "${SAMPLE_TEMPLATE} not Ready after 3m — check: kubectl describe agenttemplate ${SAMPLE_TEMPLATE} -n ${KAGENT_NS}"
  ok "Harness compiled ${SAMPLE_TEMPLATE}"
}

cmd_install() {
  require kubectl curl jq
  kctl -n "$SUBSTRATE_NS" get pod -l app=ate-api-server >/dev/null 2>&1 \
    || die "Substrate platform not found in '${SUBSTRATE_NS}' — run: make substrate-create"
  kctl get workerpool kagent-default -n "$KAGENT_NS" >/dev/null 2>&1 \
    || die "WorkerPool kagent-default not found — is kagent deployed with SUBSTRATE_ENABLED=true?"
  [[ -d "$KAGENT_DIR" ]] || die "kagent checkout not found at ${KAGENT_DIR} — set KAGENT_DIR=..."

  local image
  image="$(harness_image)"

  say "Applying sample Harness + ${SAMPLE_TEMPLATE} AgentTemplate..."
  KAGENT_SAMPLES_RUNTIME_IMAGE="$image" \
    "${ENVSUBST:-envsubst}" < "$SAMPLES_DIR/substrate-harness.yaml.tmpl" | kctl apply -f - >/dev/null
  kctl apply -f "$SAMPLES_DIR/hello-substrate.yaml" >/dev/null
  wait_template_ready

  local cli id
  cli="$(cli_bin)"
  id="$(sample_instance_id "$cli")"
  if [[ -z "$id" ]]; then
    say "Creating an AgentInstance from ${SAMPLE_TEMPLATE}..."
    "$cli" create agent-instance --harness "$SAMPLE_HARNESS" --agent-template "$SAMPLE_TEMPLATE" >/dev/null
    id="$(sample_instance_id "$cli")"
  fi
  [[ -n "$id" ]] || die "could not resolve the sample AgentInstance ID — check: kagent get agent-instance"

  ok "sample ready:"
  echo "   instance : $id"
  echo "   chat     : https://kagent.${DOMAIN} (hello-substrate) or: kagent invoke --agent-instance $id --task '...'"
  echo "   state    : kagent get agent-instance   (instance quiesces between calls)"
  echo "   validate : make substrate-validate"
}

cmd_validate() {
  require jq
  local cli id task
  cli="$(cli_bin)"
  id="$(sample_instance_id "$cli")"
  [[ -n "$id" ]] || die "sample instance not found — run: make substrate-samples"

  task="Where are you running? Answer in one sentence."
  say "Invoking ${SAMPLE_TEMPLATE} (${id}): ${task}"
  # --timeout must cover a COLD restore: the actor suspends after every task
  # boundary, so the first invoke pays the gVisor snapshot restore (~20-40s).
  local answer
  answer="$("$cli" invoke --agent-instance "$id" --task "$task" --timeout 120s 2>&1 | tail -5)"
  echo "$answer"
  echo ""
  if printf '%s' "$answer" | grep -qiE "substrate|gvisor|actor|sandbox"; then
    ok "PASS — the agent reports its substrate runtime"
  else
    warn "invoke answered but did not mention substrate/gVisor — check the model/key config, then re-run"
  fi
  say "Instance state (quiesces between calls; RUNNING right after one):"
  "$cli" get agent-instance 2>/dev/null || true
  say "Substrate inventory (actors): UI -> View -> Substrate"
}

cmd_status() {
  echo "== sample harness/templates =="
  kctl -n "$KAGENT_NS" get harness,agenttemplate 2>/dev/null || echo "   (none — run: make substrate-samples)"
  echo "== sample agent instances =="
  local cli
  if cli="$(command -v kagent-local 2>/dev/null || [[ -x "$KAGENT_DIR/go/core/bin/kagent-local" ]] && echo "$KAGENT_DIR/go/core/bin/kagent-local")"; then
    "$cli" get agent-instance 2>/dev/null || echo "   (CLI could not reach the controller)"
  else
    echo "   (CLI not built — run: make substrate-samples)"
  fi
  echo "== substrate inventory =="
  echo "   (actors live in the ate-api inventory, not k8s: UI -> View -> Substrate;"
  echo "    the instance STATE above shows quiescence)"
}

cmd_delete() {
  require kubectl
  if cli="$(command -v kagent-local 2>/dev/null || [[ -x "$KAGENT_DIR/go/core/bin/kagent-local" ]] && echo "$KAGENT_DIR/go/core/bin/kagent-local")"; then
    local id
    id="$(sample_instance_id "$cli")"
    [[ -z "$id" ]] || "$cli" delete agent-instance "$id" >/dev/null 2>&1 || true
  fi
  kctl -n "$KAGENT_NS" delete agenttemplate "$SAMPLE_TEMPLATE" --ignore-not-found >/dev/null 2>&1 || true
  kctl -n "$KAGENT_NS" delete harness "$SAMPLE_HARNESS" --ignore-not-found >/dev/null 2>&1 || true
  ok "sample agent removed (harness, template, instance)"
}

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  install)  cmd_install ;;
  validate) cmd_validate ;;
  status)   cmd_status ;;
  delete)   cmd_delete ;;
  *)        usage ;;
esac
