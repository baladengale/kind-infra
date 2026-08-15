#!/usr/bin/env bash
#
# Gateway layer: AgentGateway (Gateway API implementation) + wildcard TLS.
#
# - installs Gateway API CRDs and the agentgateway control plane (helm, OCI)
# - generates a local wildcard cert for *.${DOMAIN} with mkcert and installs
#   it as the Gateway's TLS certificate (trusted by macOS + Docker Desktop,
#   which syncs host roots into its VM)
# - creates the kind-infra Gateway with HTTP (:8080) and HTTPS (:8443)
#   listeners — kind maps host 80/443 to node 8080/8443, so from the machine
#   everything is plain http://name.internal and https://name.internal
# - pins the proxy dataplane to the ingress-ready node with hostPorts
#   8080/8443 (extraPortMappings deliver host traffic there)
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl helm
cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."

command -v mkcert >/dev/null 2>&1 || brew install mkcert
say "Ensuring the mkcert CA is installed (may prompt for your password)..."
mkcert -install >/dev/null

CERT_DIR="$ROOT_DIR/certs"

# ---------------------------------------------------------------------------
# 1. Gateway API CRDs + agentgateway control plane
# ---------------------------------------------------------------------------
if ! kubectl --context "$KUBE_CONTEXT" get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  say "Installing Gateway API CRDs (v${GWAPI_VERSION})..."
  kubectl --context "$KUBE_CONTEXT" apply --server-side --force-conflicts -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GWAPI_VERSION}/standard-install.yaml"
fi

say "Installing agentgateway ${AGW_VERSION} (helm, OCI)..."
helm upgrade -i agentgateway-crds "oci://cr.agentgateway.dev/charts/agentgateway-crds" \
  --create-namespace --namespace "$GW_NS" --version "$AGW_VERSION" \
  --kube-context "$KUBE_CONTEXT" \
  --set controller.image.pullPolicy=Always >/dev/null
helm upgrade -i agentgateway "oci://cr.agentgateway.dev/charts/agentgateway" \
  --namespace "$GW_NS" --version "$AGW_VERSION" \
  --kube-context "$KUBE_CONTEXT" \
  --set controller.image.pullPolicy=Always --wait >/dev/null

# ---------------------------------------------------------------------------
# 2. TLS certificate: wildcard *.${DOMAIN} + an explicit SAN per registered
#    hostname (strict clients don't match bare-suffix wildcards). The mkcert
#    CA lands in the macOS keychain, which Docker Desktop syncs into its VM,
#    so `docker push` trusts the Gateway too.
# ---------------------------------------------------------------------------
refresh_gateway_cert

# ---------------------------------------------------------------------------
# 3. Gateway with HTTP + HTTPS listeners (any namespace may attach routes)
# ---------------------------------------------------------------------------
say "Creating Gateway '${GW_NAME}'..."
kubectl --context "$KUBE_CONTEXT" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${GW_NS}
spec:
  gatewayClassName: agentgateway
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    port: 8443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - group: ""
        kind: Secret
        name: kind-infra-wildcard
    allowedRoutes:
      namespaces:
        from: All
EOF

# ---------------------------------------------------------------------------
# 4. Pin the proxy dataplane to the ingress-ready node with hostPorts.
#    The chart creates one proxy Deployment per Gateway, named after it.
#    Fall back to the newest non-controller deployment if that ever changes.
# ---------------------------------------------------------------------------
say "Waiting for the proxy Deployment '${GW_NAME}' (image pulls can take a while)..."
if kubectl --context "$KUBE_CONTEXT" -n "$GW_NS" wait --for=exist deploy/"$GW_NAME" --timeout=300s >/dev/null 2>&1; then
  dep_name="$GW_NAME"
else
  dep_name="$(kubectl --context "$KUBE_CONTEXT" -n "$GW_NS" get deploy -o json | jq -r '
    .items
    | sort_by(.metadata.creationTimestamp)
    | .[] | select(.metadata.name != "agentgateway")
    | .metadata.name' | tail -1)"
fi
[[ -n "${dep_name:-}" ]] || die "No proxy Deployment found — check: kubectl -n ${GW_NS} get deploy,pods && kubectl -n ${GW_NS} logs deploy/agentgateway"
cname="$(kubectl --context "$KUBE_CONTEXT" -n "$GW_NS" get deploy "$dep_name" \
  -o jsonpath='{.spec.template.spec.containers[0].name}')"

say "Patching ${dep_name} (nodeSelector ingress-ready + hostPorts 8080/8443)..."
# strategic merge: merges containers/ports by name instead of replacing them.
# Recreate strategy: hostPorts conflict during RollingUpdate on a single node.
kubectl --context "$KUBE_CONTEXT" -n "$GW_NS" patch deploy "$dep_name" --type strategic -p "
spec:
  strategy:
    type: Recreate
    rollingUpdate: null
  template:
    spec:
      nodeSelector:
        ingress-ready: \"true\"
      containers:
      - name: ${cname}
        ports:
        - containerPort: 8080
          hostPort: 8080
        - containerPort: 8443
          hostPort: 8443"

kubectl --context "$KUBE_CONTEXT" -n "$GW_NS" rollout status deploy "$dep_name" --timeout=180s
# Gateway API conditions are Accepted/Programmed (there is no Available).
kubectl --context "$KUBE_CONTEXT" -n "$GW_NS" wait --for=condition=Programmed gateway "$GW_NAME" --timeout=180s

# ---------------------------------------------------------------------------
# 5. Probe host ports 80/443 through the node mappings
# ---------------------------------------------------------------------------
http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1 || true)"
https_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1 || true)"
if [[ "$http_code" != "000" && "$https_code" != "000" ]]; then
  ok "Gateway answering on 127.0.0.1:80 (HTTP ${http_code}) and :443 TLS (HTTP ${https_code}) — 404 is expected with no routes yet"
else
  warn "Gateway deployed but host ports 80/443 did not answer."
  warn "The cluster must be created with this repo's kind config (extraPortMappings 80->8080, 443->8443)."
  warn "Recreate with: make upgrade"
fi
