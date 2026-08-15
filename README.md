# kind-infra

Local Kubernetes base infrastructure, managed with make:

- **kind cluster** with host ports 80/443 published for ingress
- **local container registry** (`localhost:5001`, wired into every node)
- **MetalLB** — LoadBalancer services get IPs from the kind network pool
- **ingress-nginx** — routes `http://<name>.<domain>` to services by Host header
- **local DNS** (dnsmasq + macOS resolver) — `*.<domain>` resolves to 127.0.0.1

Hostnames are short: `kagent.test`, `kind-registry.test`, `myapp.test`.

> Why not `*.local`? macOS reserves `.local` for Bonjour/mDNS — those queries
> never reliably reach dnsmasq via `/etc/resolver`. `.test` is RFC
> 6761-reserved for exactly this purpose and the DNS script enforces it.

## Quickstart

```bash
make create     # everything above, idempotent
make status     # verify each layer
```

## Hostnames, without port-forwarding

Two mechanisms — both end at a k8s Service, never a `kubectl port-forward`:

**1. Wildcard DNS (zero registration).** Everything under `*.test` resolves to
127.0.0.1, so any port already published on the host works by name:

```bash
docker push kind-registry.test:5001/myimage:tag   # hits the local registry
```

**2. Register a hostname → Service (routed through ingress on :80).**
Annotate the Service and sync:

```bash
kubectl -n kagent annotate svc kagent-ui \
  kind-infra.dev/host=kagent kind-infra.dev/port=8080
make sync     # creates the Ingress; also prunes stale registrations
# -> http://kagent.test
```

Or do it directly without touching the Service:

```bash
make expose HOST=kagent NS=kagent SVC=kagent-ui PORT=8080
make unexpose HOST=kagent
```

`PORT` defaults to the Service's first port. The Ingress objects carry the
label `app.kubernetes.io/managed-by: kind-infra` so sync can prune safely.

Non-HTTP/TCP ports (e.g. gRPC on 8084) can't ride the HTTP ingress — either
add an `extraPortMapping` in `kind/kind-config.yaml` + `make upgrade`, or use
ingress-nginx's `tcp-services` ConfigMap.

## Lifecycle targets

| Target | What it does |
|---|---|
| `make create` | Cluster + registry + MetalLB + ingress + DNS |
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
| `DOMAIN` | `test` | DNS zone managed by dnsmasq |
| `KIND_CLUSTER_NAME` | `kind` | Cluster name (context: `kind-kind`) |
| `KIND_IMAGE_VERSION` | `1.35.0` | `kindest/node` version — bump + `make upgrade` |
| `METALLB_VERSION` | `v0.15.3` | MetalLB manifest version |
| `INGRESS_NGINX_REF` | `main` | ingress-nginx manifest ref |
| `CONTAINER_RUNTIME` | auto (podman→docker) | Runtime kind runs on |

Example — a second cluster with its own zone:

```bash
make create KIND_CLUSTER_NAME=dev DOMAIN=dev.test
```

Point targets at an existing cluster (e.g. one created by another repo):

```bash
make sync KIND_CLUSTER_NAME=kagent     # uses context kind-kagent
```

Note: hostname routing still requires that cluster to have been created with
this repo's kind config (host ports 80/443 + `ingress-ready` label).

## How it fits together

```
http://kagent.test
  │  1. macOS routes *.test to dnsmasq (/etc/resolver/test)
  │  2. dnsmasq answers 127.0.0.1
  ▼
127.0.0.1:80  (kind extraPortMappings)
  ▼
  3. ingress-nginx routes by Host header
  ▼
Service kagent-ui  (registered via `make expose` / annotation + `make sync`)
```

Notes:
- Only the configured zone is routed to dnsmasq; the rest of your DNS is
  untouched.
- On macOS/Docker Desktop, MetalLB IPs (172.18.255.x) are **not** reachable
  from the host — that's why ingress goes through published host ports.

## Structure

```
Makefile                  lifecycle orchestration
kind/kind-config.yaml     cluster config (ports 80/443, ingress-ready label, registry)
scripts/common.sh         shared vars + helpers
scripts/10-create-cluster.sh   cluster + local registry
scripts/20-metallb.sh          MetalLB + IPAddressPool
scripts/30-ingress.sh          ingress-nginx
scripts/40-dns-install.sh      dnsmasq zone + /etc/resolver
scripts/41-dns-remove.sh       undo the DNS bits
scripts/50-register.sh         hostname registration (expose / remove / sync)
```

## Debugging (layer by layer)

```bash
dig anything.test @127.0.0.1                    # 1. dnsmasq -> 127.0.0.1?
curl -H "Host: kagent.test" http://127.0.0.1    # 2. ingress routing?
kubectl get ingress -A -l app.kubernetes.io/managed-by=kind-infra
make status                                      # everything at a glance
```

Stale DNS cache: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`

## Requirements

macOS with: kind, kubectl, jq, Homebrew (dnsmasq installed automatically),
docker or podman. `make delete` and the DNS scripts use `sudo` for
`/etc/resolver`.

Cluster-setup scripts adapted from the
[kind docs](https://kind.sigs.k8s.io/docs/user/local-registry/) and the
[kagent](https://github.com/kagent-dev/kagent) repo (Apache-2.0).
