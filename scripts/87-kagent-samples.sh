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
#  12. kubectl get harness,agenttemplate,agent -n kagent   # k8s objects
#  13. kagent agent session create --agent hello-substrate  # chat session
#  14. UI: https://kagent.internal -> chat with hello-substrate
#  15. View -> Substrate: the actor quiesces between requests
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


# The deployable sample object is an Agent (harnessRef + template.ref); the
# controller materializes its runtime revision. Readiness = Ready condition.
wait_agent_ready() {
  say "Waiting for the controller to compile agent/${SAMPLE_TEMPLATE}..."
  if kctl -n "$KAGENT_NS" wait --for=condition=Ready "agent/${SAMPLE_TEMPLATE}" \
    --timeout=180s >/dev/null 2>&1; then
    ok "Agent ${SAMPLE_TEMPLATE} is Ready"
    return 0
  fi
  die "agent/${SAMPLE_TEMPLATE} not Ready after 3m — check: kubectl describe agent ${SAMPLE_TEMPLATE} -n ${KAGENT_NS}"
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

  say "Applying sample Harness + ${SAMPLE_TEMPLATE} AgentTemplate + Agent..."
  KAGENT_SAMPLES_RUNTIME_IMAGE="$image" \
    "${ENVSUBST:-envsubst}" < "$SAMPLES_DIR/substrate-harness.yaml.tmpl" | kctl apply -f - >/dev/null
  kctl apply -f "$SAMPLES_DIR/hello-substrate.yaml" >/dev/null
  kctl apply -f "$SAMPLES_DIR/hello-substrate-agent.yaml" >/dev/null
  wait_agent_ready

  ok "sample ready:"
  echo "   agent    : kubectl get agent ${SAMPLE_TEMPLATE} -n ${KAGENT_NS}"
  echo "   chat     : https://kagent.${DOMAIN} (hello-substrate) or:"
  echo "              kagent agent session create --agent ${SAMPLE_TEMPLATE} && kagent agent invoke --session <id> --task '...'"
  echo "   state    : the substrate actor quiesces between calls (UI -> View -> Substrate)"
  echo "   validate : make substrate-validate"
}

cmd_validate() {
  require jq
  local cli task session_id answer
  cli="$(cli_bin)"
  kctl -n "$KAGENT_NS" get agent "$SAMPLE_TEMPLATE" >/dev/null 2>&1 \
    || die "sample agent not found — run: make substrate-samples"

  task="Where are you running? Answer in one sentence."
  say "Invoking ${SAMPLE_TEMPLATE}: ${task}"
  session_id="$("$cli" agent session create --agent "$SAMPLE_TEMPLATE" 2>/dev/null \
    | jq -r '.id // .sessionId // .session.id // empty' 2>/dev/null)"
  [[ -n "$session_id" ]] || die "could not create a session — check: kagent agent session create --agent ${SAMPLE_TEMPLATE}"
  # --timeout must cover a COLD restore: the actor suspends after every task
  # boundary, so the first invoke pays the gVisor snapshot restore (~20-40s).
  answer="$("$cli" agent invoke --session "$session_id" --task "$task" 2>&1 | tail -5)"
  echo "$answer"
  echo ""
  if printf '%s' "$answer" | grep -qiE "substrate|gvisor|actor|sandbox"; then
    ok "PASS — the agent reports its substrate runtime"
  else
    warn "invoke answered but did not mention substrate/gVisor — check the model/key config, then re-run"
  fi
  say "Substrate inventory (actors): UI -> View -> Substrate"
}

cmd_status() {
  echo "== sample harness/template/agent =="
  kctl -n "$KAGENT_NS" get harness,agenttemplate,agent 2>/dev/null \
    | grep -E "hello-substrate|NAME|^harness" || echo "   (none — run: make substrate-samples)"
  echo "== substrate inventory =="
  echo "   (actors live in the ate-api inventory, not k8s: UI -> View -> Substrate;"
  echo "    the actor quiesces between calls)"
}

cmd_delete() {
  require kubectl
  kctl -n "$KAGENT_NS" delete agent "$SAMPLE_TEMPLATE" --ignore-not-found >/dev/null 2>&1 || true
  kctl -n "$KAGENT_NS" delete agenttemplate "$SAMPLE_TEMPLATE" --ignore-not-found >/dev/null 2>&1 || true
  kctl -n "$KAGENT_NS" delete harness "$SAMPLE_HARNESS" --ignore-not-found >/dev/null 2>&1 || true
  ok "sample agent removed (agent, template, harness)"
}

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  install)  cmd_install ;;
  validate) cmd_validate ;;
  status)   cmd_status ;;
  delete)   cmd_delete ;;
  *)        usage ;;
esac
