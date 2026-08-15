#!/usr/bin/env bash
#
# End-to-end tests (chainsaw) against the running cluster — `make test`.
#
# The tests exercise the repo's real lifecycle: Gateway/TLS state, DNS,
# `make expose`/`make unexpose` hostname registration, and the registry
# route on 443. Assertions bake in the default names, so non-default
# KIND_CLUSTER_NAME / DOMAIN values are rejected up front.
#
# chainsaw (Kyverno) is NOT Homebrew's `chainsaw` formula (that one is a
# forensics tool). Install from:
#   https://github.com/kyverno/chainsaw/releases
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl curl dig
command -v chainsaw >/dev/null 2>&1 \
  || die "chainsaw not found — install Kyverno chainsaw from https://github.com/kyverno/chainsaw/releases (NOT brew's chainsaw)."

[[ "${KIND_CLUSTER_NAME}" == "kind" && "${DOMAIN}" == "internal" ]] \
  || die "make test requires the defaults KIND_CLUSTER_NAME=kind DOMAIN=internal (assertions hardcode them)."
cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."
[[ -f "$ROOT_DIR/certs/rootCA.pem" ]] || die "Missing certs/rootCA.pem — run 'make create' first."

export REPO_ROOT="$ROOT_DIR"   # used by test scripts to reach make + the CA
export KUBE_CONTEXT DOMAIN CONTAINER_RUNTIME

# Chainsaw must run against the default kubeconfig (a --kube-context flag
# would hand script steps a temp kubeconfig where `--context kind-kind`
# and `make expose` break). Point kubectl at our cluster, restore after.
prev_ctx="$(kubectl config current-context 2>/dev/null || true)"
kubectl config use-context "$KUBE_CONTEXT" >/dev/null
restore_ctx() { [[ -n "$prev_ctx" && "$prev_ctx" != "$KUBE_CONTEXT" ]] && kubectl config use-context "$prev_ctx" >/dev/null || true; }
trap restore_ctx EXIT

say "Running chainsaw e2e tests (tests/)..."
chainsaw test "$ROOT_DIR/tests"
ok "All chainsaw e2e tests passed."
