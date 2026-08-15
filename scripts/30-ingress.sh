#!/usr/bin/env bash
#
# Install ingress-nginx (kind-tuned manifest) so HTTP traffic to
# 127.0.0.1:80/:443 is routed to in-cluster services by Host header.
#
# Requires the cluster to have been created with kind/kind-config.yaml
# (extraPortMappings 80/443 + the ingress-ready node label).
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl
cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."

# Warn if the node lacks the label this manifest's nodeSelector expects.
if ! kubectl --context "$KUBE_CONTEXT" get nodes \
    -l ingress-ready=true --no-headers 2>/dev/null | grep -q .; then
  warn "No node carries the 'ingress-ready' label — the cluster was probably NOT"
  warn "created with kind/kind-config.yaml. The controller will stay Pending."
  warn "Recreate with: make upgrade"
fi

say "Installing ingress-nginx (ref: ${INGRESS_NGINX_REF})..."
kubectl --context "$KUBE_CONTEXT" apply -f \
  "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_REF}/deploy/static/provider/kind/deploy.yaml"

say "Waiting for ingress-nginx to be ready..."
kubectl --context "$KUBE_CONTEXT" -n ingress-nginx wait --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

# End-to-end probe: the default backend should answer on host port 80.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1 || true)"
if [[ "$code" != "000" ]]; then
  ok "ingress-nginx answering on 127.0.0.1:80 (HTTP ${code} from the default backend)"
else
  warn "ingress-nginx is running but 127.0.0.1:80 did not answer."
  warn "The cluster likely lacks extraPortMappings — recreate with: make upgrade"
fi
