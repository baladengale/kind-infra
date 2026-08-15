#!/usr/bin/env bash
#
# Install MetalLB and give it an IPAddressPool carved out of the kind docker
# network subnet (e.g. 172.18.255.0-231). Services of type LoadBalancer get
# addresses from that pool.
#
# Adapted from the kagent repo (scripts/kind/setup-metallb.sh, Apache-2.0).
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl jq "$CONTAINER_RUNTIME"
cluster_exists || die "Cluster '${KIND_CLUSTER_NAME}' does not exist — run 'make create' first."

say "Installing MetalLB ${METALLB_VERSION}..."
kubectl --context "$KUBE_CONTEXT" apply -f \
  "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

say "Waiting for MetalLB to be ready..."
kubectl --context "$KUBE_CONTEXT" rollout status -n metallb-system deployment/controller --timeout 5m
kubectl --context "$KUBE_CONTEXT" rollout status -n metallb-system daemonset/speaker --timeout 5m
kubectl --context "$KUBE_CONTEXT" wait -n metallb-system pod -l app=metallb \
  --for=condition=Ready --timeout=60s

# Docker reports the subnet as .[].IPAM.Config[].Subnet; podman as
# .[].subnets[].subnet. Take the first IPv4 subnet.
SUBNET=$("$CONTAINER_RUNTIME" network inspect kind | jq -r '
  [ .[].IPAM.Config[]?.Subnet, .[].subnets[]?.subnet ]
  | map(select(. != null and (contains(":") | not)))
  | .[0]
' | cut -d '.' -f1,2)
if [ -z "${SUBNET}" ] || [ "${SUBNET}" = "null" ]; then
  die "Could not detect the IPv4 subnet of the 'kind' network. Ensure the cluster is running."
fi
MIN=${SUBNET}.255.0
MAX=${SUBNET}.255.231

say "Configuring IPAddressPool ${MIN}-${MAX}..."
# Note: each line below must begin with one tab character for <<-'EOF'.
kubectl --context "$KUBE_CONTEXT" apply -f - <<-EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: address-pool
  namespace: metallb-system
spec:
  addresses:
    - ${MIN}-${MAX}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - address-pool
EOF

ok "MetalLB ready (LoadBalancer services get IPs from ${MIN}-${MAX})"
