# kind-infra

Local Kubernetes base infrastructure, managed with make:

- **kind cluster** with host ports 80/443 published for the gateway
- **local container registry** — `docker push kind-registry.internal/img:tag`,
  no port suffix, real TLS on 443
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
make dns-install   # ONE-TIME, machine-level: *.internal -> 127.0.0.1 (uses sudo)
make create        # cluster + registry + AgentGateway (idempotent)
make test          # chainsaw e2e tests against the running cluster
make status        # verify each layer
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
| `make create` | Cluster + registry + AgentGateway + registry route (DNS is one-time, see below) |
| `make update` | Re-apply addons on the existing cluster (idempotent; picks up version bumps) |
| `make upgrade` | Recreate the cluster with the current `KIND_IMAGE_VERSION` (destructive) |
| `make delete` | Delete cluster and registry (DNS zone stays installed) |
| `make delete-cluster` | Delete only the cluster |
| `make test` | Run the chainsaw e2e tests (see below) |
| `make dns-install` / `make dns-remove` | One-time local DNS zone setup / removal (uses `sudo`) |
| `make expose` / `make unexpose` | Register/remove one hostname (`HOST=`, `NS=`, `SVC=`, `PORT=`) |
| `make sync` | Sync all annotated Services to hostnames (+ prune) |
| `make status` | Show clusters, addons, registry, DNS state |

### Variables (override on the command line)

| Variable | Default | Purpose |
|---|---|---|
| `DOMAIN` | `internal` | DNS zone + TLS wildcard (`*.internal`) |
| `KIND_CLUSTER_NAME` | `kind` | Cluster name (context: `kind-kind`) |
| `KIND_IMAGE_VERSION` | `1.35.0` | `kindest/node` version — bump + `make upgrade` |
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
- The proxy binds 8080/8443 (unprivileged) and kind maps host 80/443 to them.

## Structure

```
Makefile                  lifecycle orchestration (create/update/delete/test/...)
kind/kind-config.yaml     cluster config (ports 80/443 -> 8080/8443, registry)
manifests/                all applied YAML, with ${VAR} placeholders filled by scripts
  gateway.yaml            kind-infra Gateway (HTTP 8080 + HTTPS 8443 listeners)
  app-route.yaml          HTTPRoute template used by expose/sync
  registry-service.yaml   registry Service + Endpoints (container IP)
  registry-route.yaml     kind-registry.<DOMAIN> HTTPRoute
  local-registry-hosting.yaml  registry discovery ConfigMap
scripts/
  common.sh               shared vars + helpers (render/apply_manifest)
  10-create-cluster.sh    cluster + local registry
  30-gateway.sh           AgentGateway + mkcert TLS + Gateway + hostPorts
  40-dns-install.sh       dnsmasq zone + /etc/resolver
  41-dns-remove.sh        undo the DNS bits
  50-registry.sh          port-free registry route + containerd bypass
  60-register.sh          hostname registration (expose / remove / sync)
  70-test.sh              chainsaw runner behind `make test`
tests/                    chainsaw e2e tests (see below)
certs/                    mkcert CA + wildcard key (gitignored)
```

Everything applied to the cluster lives in `manifests/` as plain YAML;
the scripts only render `${VAR}` placeholders (`DOMAIN`, gateway names,
registry IP, ...) and pipe the result into `kubectl apply`.

## End-to-end tests (chainsaw)

`make test` runs [chainsaw](https://github.com/kyverno/chainsaw) e2e
tests against the running cluster (note: **not** Homebrew's `chainsaw`
formula — that is an unrelated forensics tool; install Kyverno chainsaw
from its GitHub releases).

| Test | Validates |
|---|---|
| `tests/infra-ready` | Nodes Ready, AgentGateway available, Gateway `Programmed`, DNS answers `*.<DOMAIN> -> 127.0.0.1` |
| `tests/registry` | `https://kind-registry.<DOMAIN>/v2/` returns 200 over real TLS |
| `tests/echo-routing` | Full `make expose` → HTTPRoute accepted → `https://echo.<DOMAIN>` serves 200 → `make unexpose` removes the route |

Tests assume the default `KIND_CLUSTER_NAME=kind` and `DOMAIN=internal`
(assertions hardcode the names); `make test` rejects other values.

```bash
make create   # then
make test     # runs all three
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
automatically), docker or podman, and — for `make test` only —
[Kyverno chainsaw](https://github.com/kyverno/chainsaw/releases).
`mkcert -install` and `make dns-install` / `make dns-remove` use `sudo`.

## Developer Experience

### kubectl plugins and aliases

Install enhanced kubectl tools for better developer experience:

```bash
make kubectl-tools
```

This installs:
- **kubecolor**: Colored kubectl output (easier to read)
- **kctx**: Quick cluster context switching (`kubectl ctx`)
- **kns**: Quick namespace switching (`kubectl ns`)

After installation, source the provided aliases in your shell:

```bash
# Add to your ~/.zshrc or ~/.bashrc
source /path/to/kind/shell-aliases.sh
```

**Common aliases available:**
```bash
k            # kubectl (or kubecolor if installed)
kg           # kubectl get
kd           # kubectl describe
kctx         # switch clusters
kns          # switch namespaces
kkind        # kubectl --context kind-kind
kgw          # kubectl --context kind-kind -n agentgateway-system
kpo          # kubectl get pods
ksv          # kubectl get services
```

**Example workflow:**
```bash
# List pods in current namespace
k get pods

# Switch to a different cluster
kubectl ctx

# Switch namespace
kubectl ns

# Use the kind cluster with aliases
kkind get pods -n agentgateway-system
```

Cluster-setup scripts adapted from the
[kind docs](https://kind.sigs.k8s.io/docs/user/local-registry/) and the
[kagent](https://github.com/kagent-dev/kagent) repo (Apache-2.0). Gateway:
[AgentGateway](https://agentgateway.dev).
