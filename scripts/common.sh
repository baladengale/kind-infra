#!/usr/bin/env bash
#
# Shared helpers and configuration for the kind-infra scripts.
# Sourced by the numbered scripts — not executed directly.
#
# All values can be overridden via environment variables (the Makefile
# exports its ?= defaults, so `make create FOO=bar` wins over both).

KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-kind}
KIND_IMAGE_VERSION=${KIND_IMAGE_VERSION:-1.35.0}
# Hostnames look like <name>.$DOMAIN — e.g. kagent.internal, kind-registry.internal.
# ".internal" is not formally reserved but has never been delegated as a real
# TLD, so it is collision-free in practice. Do NOT use "local": macOS reserves
# it for Bonjour/mDNS and unicast DNS (/etc/resolver) is unreliable.
DOMAIN=${DOMAIN:-internal}
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}
REG_NAME=${REG_NAME:-kind-registry}
REG_PORT=${REG_PORT:-5001}
REG_INTERNAL_PORT=${REG_INTERNAL_PORT:-5000}
REG_SCHEME=${REG_SCHEME:-http}

# Gateway layer (AgentGateway, Gateway API)
GWAPI_VERSION=${GWAPI_VERSION:-1.6.0}
AGW_VERSION=${AGW_VERSION:-0.0.0-latest-dev}
GW_NS=${GW_NS:-agentgateway-system}
GW_NAME=${GW_NAME:-kind-infra}

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

# kubectl for this cluster. Falls back to the ambient context when ours is
# not in the effective kubeconfig — e.g. under chainsaw, which runs scripts
# with a temporary kubeconfig containing a single renamed context.
kctl() {
  if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KUBE_CONTEXT"; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

# render <manifest> — substitute ${VAR} placeholders in manifests/<manifest>
# with the current environment and print the result. Vars shown in the
# manifests are exported by common.sh / the calling script.
render() {
  local file="$ROOT_DIR/manifests/$1" line name
  while IFS= read -r line || [[ -n "$line" ]]; do
    while [[ "$line" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
      name="${BASH_REMATCH[1]}"
      line="${line//\$\{${name}\}/${!name:-}}"
    done
    printf '%s\n' "$line"
  done < "$file"
}

# apply_manifest <manifest> — render a template and kubectl-apply it.
apply_manifest() { render "$1" | kctl apply -f - >/dev/null; }

# Regenerate the gateway TLS cert when a registered hostname is missing from
# its SANs. Strict clients (macOS curl/LibreSSL, browsers) don't match a
# wildcard directly under a bare suffix (*.internal), so every registered
# hostname also gets an explicit SAN. Updates the TLS secret and restarts
# the proxy dataplane only when the certificate actually changed.
refresh_gateway_cert() {
  local cert_dir="$ROOT_DIR/certs"
  local cert_file="$cert_dir/_wildcard.${DOMAIN}.pem"
  local key_file="$cert_dir/_wildcard.${DOMAIN}-key.pem"
  mkdir -p "$cert_dir"

  # Always keep a copy of the CA for --cacert probes.
  [[ -f "$cert_dir/rootCA.pem" ]] || cp "$(mkcert -CAROOT)/rootCA.pem" "$cert_dir/rootCA.pem"

  local -a sans=("*.${DOMAIN}")
  local h
  while IFS= read -r h; do
    [[ -n "$h" ]] && sans+=("$h")
  done < <(kctl get httproute -A -o json 2>/dev/null \
    | jq -r '.items[].spec.hostnames[]?' | sort -u)

  local want have
  want="$(printf '%s\n' "${sans[@]}" | sort -u)"
  if [[ -f "$cert_file" ]]; then
    have="$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null \
      | grep -o 'DNS:[^ ,]*' | sed 's/^DNS://' | sort -u)"
  fi

  if [[ "$want" != "${have:-}" ]]; then
    say "Issuing certificate for: ${sans[*]}"
    (cd "$cert_dir" && mkcert --cert-file "$cert_file" --key-file "$key_file" "${sans[@]}" >/dev/null)
  fi

  local fp_file fp_secret
  fp_file="$(openssl x509 -in "$cert_file" -noout -fingerprint 2>/dev/null || true)"
  fp_secret="$(kctl -n "$GW_NS" get secret kind-infra-wildcard \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null \
    | openssl x509 -noout -fingerprint 2>/dev/null || true)"

  if [[ "$fp_file" != "$fp_secret" ]]; then
    kctl -n "$GW_NS" create secret tls kind-infra-wildcard \
      --cert "$cert_file" --key "$key_file" \
      --dry-run=client -o yaml | kctl apply -f - >/dev/null
    if kctl -n "$GW_NS" get deploy "$GW_NAME" >/dev/null 2>&1; then
      say "Restarting proxy to pick up the new certificate..."
      kctl -n "$GW_NS" rollout restart deploy "$GW_NAME"
      kctl -n "$GW_NS" rollout status deploy "$GW_NAME" --timeout=180s >/dev/null
    fi
  fi
}
