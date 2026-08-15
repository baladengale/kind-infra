#!/usr/bin/env bash
#
# Shared helpers and configuration for the kind-infra scripts.
# Sourced by the numbered scripts — not executed directly.
#
# All values can be overridden via environment variables (the Makefile
# exports its ?= defaults, so `make create FOO=bar` wins over both).

KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-kind}
KIND_IMAGE_VERSION=${KIND_IMAGE_VERSION:-1.35.0}
DOMAIN=${DOMAIN:-local.test}
METALLB_VERSION=${METALLB_VERSION:-v0.15.3}
INGRESS_NGINX_REF=${INGRESS_NGINX_REF:-main}
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}
REG_NAME=${REG_NAME:-kind-registry}
REG_PORT=${REG_PORT:-5001}
REG_INTERNAL_PORT=${REG_INTERNAL_PORT:-5000}
REG_SCHEME=${REG_SCHEME:-http}

KUBE_CONTEXT="kind-${KIND_CLUSTER_NAME}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m ✓  %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m !  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m ✗  %s\033[0m\n' "$*" >&2; exit 1; }

# require <cmd>... — fail fast with a clear message if a tool is missing.
require() {
  local missing=()
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  ((${#missing[@]})) && die "Missing dependencies: ${missing[*]} (install and re-run)."
  return 0
}

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; }
