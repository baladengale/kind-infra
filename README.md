# kind-infra

Local Kubernetes base infrastructure, managed with make:

- **kind cluster** with host ports 80/443 published for the gateway
- **local container registry** — `docker push kind-registry.internal/img:tag`,
  no port suffix, real TLS on 443
- **MetalLB** — LoadBalancer services get IPs from the kind network pool
- **AgentGateway** (Gateway API) — routes hostnames to services on standard
  ports: `https://kagent.internal`, with a locally-trusted wildcard cert
- **local DNS** (dnsmasq + macOS resolver) — `*.internal` resolves to 127.0.0.1

Hostnames are short: `kagent.internal`, `kind-registry.internal`, `myapp.internal`.

> Why not `*.local`? macOS reserves `.local` for Bonjour/mDNS — those queries
> never reliably reach dnsmasq via `/etc/resolver`. This applies to **any
> suffix ending in `.local`** (`test.local` too); the DNS script refuses them.
> The default `.internal` isn't formally RFC-reserved, but it has never been
> delegated as a real TLD, so it's collision-free in practice. If you want a
> fully reserved suffix, use `test` (`kagent.test`) or `home.arpa`.

## Quickstart

```bash
make create     # everything above, idempotent
make status     # verify each layer
```

## Hostnames on standard ports — no port-forwarding

**1. Register a hostname → Service (80 plain + 443 TLS via the Gateway).**

```bash
# one-off
make expose HOST=kagent NS=kagent SVC=kagent-ui PORT=8080
# -> https://kagent.internal  (http:// works too)

# or declarative: annotate the Service, then sync (prunes stale entries)
kubectl -n kagent annotate svc kagent-ui \
  kind-infra.dev/host=kagent kind-infra.dev/port=8080
make sync

# remove one
make unexpose HOST=kagent
```

`PORT` defaults to the Service's first port. Registrations are HTTPRoute
objects labeled `app.kubernetes.io/managed-by: kind-infra`, attached to the
`kind-infra` Gateway.

**2. The registry — port-free, TLS on 443.**

```bash
docker push kind-registry.internal/myimage:tag
```

This works because the Gateway terminates TLS for `*.internal` with a
[mkcert](https://github.com/FiloSottile/mkcert) wildcard certificate whose CA
lives in your macOS keychain — and Docker Desktop syncs host roots into its
VM. If pushes fail with x509 errors after first setup, restart Docker Desktop
once. Kind nodes pull the same image names directly via a containerd `certs.d`
bypass (no Gateway hop). The legacy `localhost:5001` endpoint keeps working
for compatibility.

**3. Wildcard DNS (zero registration).** Everything under `*.internal`
resolves to 127.0.0.1, so any port published on the host is reachable by
name.

**gRPC services:** HTTPRoute is HTTP-only. For gRPC backends create a
GRPCRoute with the same `parentRefs`/`hostnames` — AgentGateway serves it on
the same 443 listener:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata: { name: kagent-grpc, namespace: kagent }
spec:
  parentRefs: [{ name: kind-infra, namespace: agentgateway-system }]
  hostnames: ["kagent-grpc.internal"]
  rules:
  - backendRefs: [{ name: kagent-controller, port: 8084 }]
```

## Lifecycle targets

| Target | What it does |
|---|---|
| `make create` | Cluster + registry + MetalLB + AgentGateway + DNS + registry route |
| `make update` | Re-apply addons on the existing cluster (idempotent; picks up version bumps) |
| `make upgrade` | Recreate the cluster with the current `KIND_IMAGE_VERSION` (destructive) |
| `make delete` | Remove DNS, delete cluster and registry |
| `make delete-cluster` | Delete only the cluster |
| `make dns-install` / `make dns-remove` | Just the DNS zone |
| `make expose` / `make unexpose` | Register/remove one hostname (`HOST=`, `NS=`, `SVC=`, `PORT=`) |
| `make sync` | Sync all annotated Services to hostnames (+ prune) |
| `make status` | Show clusters, addons, registry, DNS state |

### Variables (override on the command line)

| Variable | Default | Purpose |
|---|---|---|
| `DOMAIN` | `internal` | DNS zone + TLS wildcard (`*.internal`) |
| `KIND_CLUSTER_NAME` | `kind` | Cluster name (context: `kind-kind`) |
| `KIND_IMAGE_VERSION` | `1.35.0` | `kindest/node` version — bump + `make upgrade` |
| `METALLB_VERSION` | `v0.15.3` | MetalLB manifest version |
| `GWAPI_VERSION` | `1.6.0` | Gateway API CRDs version |
| `AGW_VERSION` | `0.0.0-latest-dev` | AgentGateway chart version |
| `CONTAINER_RUNTIME` | auto (podman→docker) | Runtime kind runs on |

Example — a second cluster with its own zone:

```bash
make create KIND_CLUSTER_NAME=dev DOMAIN=dev.test
```

## How it fits together

```
https://kagent.internal            docker push kind-registry.internal/img
        │                                        │
        ▼                                        ▼
  1. macOS routes *.internal to dnsmasq (/etc/resolver/internal)
  2. dnsmasq answers 127.0.0.1
        │
        ▼
  127.0.0.1:443  (kind extraPortMappings -> node 8443)
        │
        ▼
  3. AgentGateway proxy (TLS terminate, mkcert wildcard) routes by hostname
        │
        ├─ kagent.internal ────────▶ Service kagent-ui:8080
        └─ kind-registry.internal ▶ Service kind-registry ─▶ registry:5000
                                   (nodes pull directly via certs.d bypass)
```

Notes:
- Only the configured zone is routed to dnsmasq; the rest of your DNS is
  untouched.
- On macOS/Docker Desktop, MetalLB IPs (172.18.255.x) are **not** reachable
  from the host — that's why the gateway goes through published host ports.
- The proxy binds 8080/8443 (unprivileged) and kind maps host 80/443 to them.

## Structure

```
Makefile                  lifecycle orchestration
kind/kind-config.yaml     cluster config (ports 80/443 -> 8080/8443, registry)
scripts/common.sh         shared vars + helpers
scripts/10-create-cluster.sh   cluster + local registry
scripts/20-metallb.sh          MetalLB + IPAddressPool
scripts/30-gateway.sh          AgentGateway + mkcert TLS + Gateway + hostPorts
scripts/40-dns-install.sh      dnsmasq zone + /etc/resolver
scripts/41-dns-remove.sh       undo the DNS bits
scripts/50-registry.sh         port-free registry route + containerd bypass
scripts/60-register.sh         hostname registration (expose / remove / sync)
certs/                    mkcert CA + wildcard key (gitignored)
```

## Debugging (layer by layer)

```bash
dig anything.internal @127.0.0.1                    # 1. dnsmasq -> 127.0.0.1?
curl -sk https://127.0.0.1 -H 'Host: kagent.internal'  # 2. gateway routing?
kubectl get httproute -A -l app.kubernetes.io/managed-by=kind-infra
kubectl -n agentgateway-system get gateway,pods     # 3. gateway layer
make status                                         # everything at a glance
```

Stale DNS cache: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`

## Requirements

macOS with: kind, kubectl, helm, jq, Homebrew (dnsmasq + mkcert installed
automatically), docker or podman. `mkcert -install`, `make delete` and the
DNS scripts use `sudo`.

Cluster-setup scripts adapted from the
[kind docs](https://kind.sigs.k8s.io/docs/user/local-registry/) and the
[kagent](https://github.com/kagent-dev/kagent) repo (Apache-2.0). Gateway:
[AgentGateway](https://agentgateway.dev).
