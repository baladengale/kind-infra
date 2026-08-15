#!/usr/bin/env bash
#
# Register hostnames -> k8s Services as HTTPRoutes on the AgentGateway.
# Routed on standard ports (80 plain, 443 TLS with the *.${DOMAIN} wildcard),
# no port-forwarding involved.
#
# Two ways to register:
#
#   1. Annotation-driven (declarative, survives redeploys) — annotate the
#      Service, then run `make sync`:
#
#        kubectl -n kagent annotate svc kagent-ui \
#          kind-infra.dev/host=kagent kind-infra.dev/port=8080
#        make sync
#
#      -> https://kagent.internal serves kagent-ui:8080.
#      Port defaults to the Service's first port when the annotation is absent.
#      `make sync` also prunes registrations whose Service lost the annotation.
#
#   2. Direct (no annotations needed):
#
#        make expose HOST=kagent NS=kagent SVC=kagent-ui PORT=8080
#        make unexpose HOST=kagent
#
# Hostnames are relative to $DOMAIN (default: internal), i.e. HOST=kagent
# becomes kagent.internal. DNS itself is a wildcard, so the hostname resolves
# the moment the HTTPRoute exists.
#
# gRPC backends: HTTPRoute is HTTP-only; for gRPC services create a GRPCRoute
# with the same parentRefs/hostnames (AgentGateway supports it on the same
# 443 listener — see README).
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl jq
cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."
kubectl --context "$KUBE_CONTEXT" -n "$GW_NS" get gateway "$GW_NAME" >/dev/null 2>&1 \
  || die "Gateway '${GW_NAME}' not found — run 'bash scripts/30-gateway.sh' first."

ANNOT_HOST="kind-infra.dev/host"
ANNOT_PORT="kind-infra.dev/port"
LABEL_MANAGED="app.kubernetes.io/managed-by=kind-infra"

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

kctl() { kubectl --context "$KUBE_CONTEXT" "$@"; }

apply_route() { # <host> <namespace> <service> <port>
  local host="$1" ns="$2" svc="$3" port="$4"
  kctl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${host}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: kind-infra
  annotations:
    ${ANNOT_HOST}: "${host}"
spec:
  parentRefs:
  - name: ${GW_NAME}
    namespace: ${GW_NS}
  hostnames:
  - ${host}.${DOMAIN}
  rules:
  - backendRefs:
    - name: ${svc}
      port: ${port}
EOF
}

# Enumerate annotated Services: host<TAB>namespace<TAB>service<TAB>port
desired_services() {
  kctl get svc -A -o json | jq -r \
    --arg ah "$ANNOT_HOST" --arg ap "$ANNOT_PORT" '
    .items[]
    | select(.metadata.annotations[$ah] != null)
    | [
        .metadata.annotations[$ah],
        .metadata.namespace,
        .metadata.name,
        (.metadata.annotations[$ap] // (.spec.ports[0].port | tostring))
      ]
    | @tsv'
}

# Enumerate managed HTTPRoutes: namespace<TAB>name<TAB>hostname
managed_routes() {
  kctl get httproute -A -l "$LABEL_MANAGED" -o json | jq -r '
    .items[]
    | [ .metadata.namespace, .metadata.name,
        (.spec.hostnames[0] // "") ]
    | @tsv'
}

cmd_expose() { # <host> [namespace] [service] [port]
  local host="${1:-}" ns="${2:-default}" svc="${3:-}" port="${4:-}"
  [[ -n "$host" && -n "$svc" ]] || usage
  if [[ -z "$port" ]]; then
    port="$(kctl -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)" || true
    [[ -n "$port" ]] || die "Could not read a port from svc ${ns}/${svc} — pass PORT explicitly."
  fi
  apply_route "$host" "$ns" "$svc" "$port" >/dev/null
  refresh_gateway_cert   # explicit SAN for the new hostname
  ok "https://${host}.${DOMAIN} -> ${ns}/${svc}:${port}"
}

cmd_remove() { # <host>
  local host="${1:-}"
  [[ -n "$host" ]] || usage
  local deleted=0 ns name h
  while IFS=$'\t' read -r ns name h; do
    [[ "$h" == "${host}.${DOMAIN}" ]] || continue
    kctl -n "$ns" delete httproute "$name" --ignore-not-found >/dev/null
    ok "Removed ${h} (httproute ${ns}/${name})"
    deleted=1
  done < <(managed_routes)
  ((deleted)) || warn "No registration found for ${host}.${DOMAIN}"
}

cmd_sync() {
  local desired_hosts="$(mktemp)"
  local host ns svc port h name
  while IFS=$'\t' read -r host ns svc port; do
    [[ -n "$host" ]] || continue
    apply_route "$host" "$ns" "$svc" "$port" >/dev/null
    echo "${host}.${DOMAIN}" >> "$desired_hosts"
    ok "https://${host}.${DOMAIN} -> ${ns}/${svc}:${port}"
  done < <(desired_services)

  # Prune managed routes whose Service no longer carries the annotation.
  while IFS=$'\t' read -r ns name h; do
    [[ -n "$h" ]] || continue
    if ! grep -qx "$h" "$desired_hosts"; then
      kctl -n "$ns" delete httproute "$name" --ignore-not-found >/dev/null
      ok "Pruned ${h} (httproute ${ns}/${name})"
    fi
  done < <(managed_routes)

  if [[ ! -s "$desired_hosts" ]]; then
    warn "No Services annotated with ${ANNOT_HOST} — nothing registered."
    echo "Annotate one and re-run, e.g.:"
    echo "  kubectl -n <ns> annotate svc <name> ${ANNOT_HOST}=<host> [${ANNOT_PORT}=<port>]"
  fi
  rm -f "$desired_hosts"
}

case "${1:-}" in
  expose) shift; cmd_expose "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  sync)   cmd_sync ;;
  *)      usage ;;
esac
