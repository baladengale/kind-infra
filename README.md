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
cp kagent/env.example .env   # fill in ANTHROPIC_API_KEY (needed by kagent)
make dns-install   # ONE-TIME, machine-level: *.internal -> 127.0.0.1 (uses sudo)
make all          # ONE command: cluster + registry + AgentGateway + kagent + site
make test         # chainsaw e2e tests against the running cluster
make status       # verify each layer
```

**kagent Agent Substrate** (agents as gVisor actors that snapshot and
rehydrate, instead of per-pod Deployments): add `SUBSTRATE_ENABLED=true` to
any target, or use the shortcuts:

```bash
make substrate-create   # cluster + substrate platform (ate-system) + kagent + sample agent
make substrate-status   # ate-system pods, WorkerPools, sample agent state
make substrate-validate # invoke the sample agent end-to-end and check the answer
make substrate-delete   # remove kagent + substrate (cluster and registry stay)
```

`SUBSTRATE_ENABLED` defaults to `true`; pass `SUBSTRATE_ENABLED=false` to any
target for the plain-Deployment kagent flow. Substrate mode also deploys the
**hello-substrate sample agent** (Harness + AgentTemplate + a running
AgentInstance) — validate with `make substrate-validate`.

Substrate mode uses a separate cluster config (`kind/kind-config-substrate.yaml`)
that enables the pod-identity feature gates substrate requires — the default
`kind/kind-config.yaml` is untouched. Substrate mode also uses the **local
kagent build** (`kagent-build-deploy`): the published upstream kagent
releases predate the pod-identity wiring the controller needs to talk to
the substrate platform. See [Agent Substrate](#kagent-agent-substrate)
below for how it works with the local registry.

`make all` is the full bootstrap in order — cluster + registry, AgentGateway
+ TLS, registry route, kagent (images mirrored into the local registry, helm
install, UI + MCP route), personal site (build, load, manifests, route).
Every step is idempotent: re-run to converge. Only the one-time DNS setup
(`make dns-install`, sudo) is left out — `make all` probes it and reminds
you if it is missing.

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
| `make all` | Full bootstrap: `create` + kagent + personal site, in order (idempotent) |
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
| `make substrate-create` | `create` + kagent with Agent Substrate enabled (see below) |
| `make substrate-status` | Substrate platform + kagent health (pods, workerpools, actors) |
| `make substrate-delete` | Remove kagent + the substrate platform (cluster and registry stay) |
| `make substrate-samples` | Deploy the hello-substrate sample agent (harness + template + instance) |
| `make substrate-validate` | Invoke the sample agent and verify it answers from its gVisor actor |

Any of the above accepts `SUBSTRATE_ENABLED=true` — e.g.
`make create SUBSTRATE_ENABLED=true` also installs the substrate platform,
`make kagent-deploy SUBSTRATE_ENABLED=true` wires kagent to it,
`make delete SUBSTRATE_ENABLED=true` removes substrate first.

### Variables (override on the command line)

| Variable | Default | Purpose |
|---|---|---|
| `DOMAIN` | `internal` | DNS zone + TLS wildcard (`*.internal`) |
| `KIND_CLUSTER_NAME` | `kagent` | Cluster name (context: `kind-kagent`) |
| `KIND_IMAGE_VERSION` | `1.35.0` | `kindest/node` version — bump + `make upgrade` |
| `GWAPI_VERSION` | `1.6.0` | Gateway API CRDs version |
| `AGW_VERSION` | `0.0.0-latest-dev` | AgentGateway chart version |
| `SUBSTRATE_ENABLED` | `false` | Install + wire kagent Agent Substrate (see below) |
| `SUBSTRATE_VERSION` | `0.0.20` | Substrate OCI chart version (ghcr) |
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
kind/kind-config-substrate.yaml  same + substrate pod-identity feature gates
manifests/                plain YAML, no variables — kubectl apply -f works directly
  gateway.yaml            kind-infra Gateway (HTTP 8080 + HTTPS 8443 listeners)
  kagent-route.yaml       kagent.internal HTTPRoute (UI + /mcp)
  registry-service.yaml   registry Service (Endpoints are dynamic — 50-registry.sh)
  registry-route.yaml     kind-registry.internal HTTPRoute
  local-registry-hosting.yaml  registry discovery ConfigMap
scripts/
  00-up.sh                one-command bootstrap behind `make all`
  common.sh               shared vars + helpers (apply_manifest, cert refresh)
  10-create-cluster.sh    cluster + local registry
  30-gateway.sh           AgentGateway + mkcert TLS + Gateway + hostPorts
  40-dns-install.sh       dnsmasq zone + /etc/resolver
  41-dns-remove.sh        undo the DNS bits
  50-registry.sh          port-free registry route + containerd bypass
  60-register.sh          hostname registration (expose / remove / sync)
  70-test.sh              chainsaw runner behind `make test`
  80-kagent.sh            kagent deployment wrapper (see below)
  85-substrate.sh         Agent Substrate platform wrapper (install/status/uninstall)
  90-site.sh              internal website (../baladengale.github.io) deploy
kagent/                   wrapper defaults for deploying ../kagent
  values.yaml             customization defaults (agents off, etc.)
  values-substrate.yaml   substrate mode: controller wiring + default WorkerPool
  env.example             template for the gitignored .env (API keys)
tests/                    chainsaw e2e tests (see below)
certs/                    mkcert CA + wildcard key (gitignored)
```

Everything applied to the cluster lives in `manifests/` as plain YAML with
no variables — any file there can be applied as-is with
`kubectl apply -f`. The only generated objects are the truly dynamic ones:
per-app routes from `make expose`/`make sync` (arbitrary host/service/port)
and the registry Endpoints (the container IP changes on recreate); the
scripts build and apply those inline.

## Deploying kagent (wrapper)

The kagent code lives in `../kagent`; this repo only holds the deployment
wrapper (`scripts/80-kagent.sh` + `kagent/values.yaml`) with our
customization defaults baked in. Both modes serve images from the local
registry and expose the UI at **https://kagent.internal** (no port-forward).

**Prerequisite — API key** (wrapper default: Anthropic provider):

```bash
cp kagent/env.example .env   # gitignored
# edit .env: ANTHROPIC_API_KEY=... (optional: KAGENT_MODEL, KAGENT_BASE_URL
# for an Anthropic-compatible endpoint like DeepSeek)
```

**Option 1 — upstream release, no local build:**

```bash
make kagent-deploy                       # default: 0.10.0-rc3
make kagent-deploy KAGENT_VERSION=0.7.9  # any published release
```

Pulls the published kagent images and the helm chart from ghcr, mirrors the
images into `kind-registry.internal` (cached — the cluster never pulls from
ghcr again, re-runs are fast), and installs the chart pointed at the local
registry. Everything tunable — release version, image list, dependency
versions, chart location — lives in one block at the top of
`scripts/80-kagent.sh` (mirrored: core images, the `-full` variants,
`kagent-adk`, plus tools/kmcp/querydoc/grafana-mcp with their own tags).

**Option 2 — build + deploy the `../kagent` checkout:**

```bash
make kagent-build-deploy
```

Builds the component images via the kagent Makefile (buildx pushes to
`localhost:5001`, which is the same registry container), then installs the
**local chart** from the checkout with `registry=kind-registry.internal`
and the tag from `git describe`. Includes the dev customizations from the
old kagent Makefile flow (pgvector bundled DB, disabled cluster-ops agents).

**Teardown / re-deploy:** both deploy targets are idempotent `helm
upgrade --install` — re-run to pick up changes. `make kagent-delete`
uninstalls both releases and removes the `kagent.internal` route (mirrored
images stay cached in the registry).

Customization defaults (kept here, upstream stays clean) live in
`kagent/values.yaml` — the built-in cluster-ops agents (cilium×3,
observability, promql), the standalone agent charts (argo-rollouts, helm,
istio) and grafana-mcp are disabled for a lean local cluster.

## kagent Agent Substrate

Agent Substrate is a Kubernetes-native runtime that snapshots idle agents and
rehydrates them inside gVisor sandboxes ("actors") instead of running every
agent as its own Deployment. See
[the concept page](https://kagent.dev/docs/kagent/examples/agent-substrate/)
for the background; the wiring here follows the kagent repo's
`examples/substrate-openclaw/README.md`.

```bash
make substrate-create   # = create + kagent-deploy with SUBSTRATE_ENABLED=true
make substrate-status   # ate-system pods, WorkerPools, actors
```

What happens in substrate mode:

- **Cluster** (`scripts/10-create-cluster.sh` + `kind/kind-config-substrate.yaml`)
  is created with the feature gates substrate requires
  (`ClusterTrustBundle`, `ClusterTrustBundleProjection`,
  `PodCertificateRequest`, `certificates.k8s.io/v1beta1`) — beta-off by
  default on kubernetes >= 1.34. Clusters created with the default config
  don't need to be recreated: `scripts/85-substrate.sh install` detects the
  missing API and live-patches the kube-apiserver static manifest + kubelet
  feature gates, then restarts both in place.
- **Platform** (`scripts/85-substrate.sh install`) mirrors the ateom gVisor
  worker image into the local registry and installs `substrate-crds` +
  `substrate` (OCI charts, `ate-system` namespace). atelet — substrate's
  image puller — gets
  `--localhost-registry-replacement=kind-registry.default.svc:5000`, which
  points localhost-origin image refs at the in-cluster registry Service
  (plain HTTP, no Gateway hop — atelet pulls images itself via
  go-containerregistry, so the containerd `certs.d` bypass does not apply to
  it). A one-time bootstrap then creates substrate's pod-identity CA/JWT
  pools with the `kubectl-ate` CLI and derives the ate-api trust + auth
  objects (skipped on re-runs — regenerating the CAs would invalidate issued
  pod certificates).
- **kagent** (`make kagent-build-deploy SUBSTRATE_ENABLED=true`,
  `scripts/80-kagent.sh`) builds the `../kagent` checkout — required: the
  published upstream releases predate the controller's pod-identity wiring
  for substrate — switches the chart's `registry` value to `localhost:5001`
  (kubelet still resolves it via the existing `certs.d` wiring; actor images
  become localhost-origin so atelet rewrites them), then wires the controller
  to the platform (`kagent/values-substrate.yaml`: `controller.substrate.*` +
  `substrateWorkerPool`) and creates the default WorkerPool running the
  mirrored ateom image.

Create a declarative agent on substrate from the kagent UI at
https://kagent.internal: Create → Agent → choose the Declarative type,
runtime Go, and pick the `kagent-default` worker pool in the Sandbox
section (the current controller compiles declarative agents into
ActorTemplates; the legacy `SandboxAgent` kubectl CR from older docs is not
reconciled by this build). The first golden snapshot takes about a minute;
between requests the actor sits `Suspended` in the substrate inventory
(View → Substrate).

Tuning: `SUBSTRATE_VERSION` picks the platform chart version;
`substrateWorkerPool.replicas` in `kagent/values-substrate.yaml` sizes the
pool (`kubectl scale workerpool kagent-default -n kagent --replicas=3`
works too, until the next helm upgrade).

Teardown: `make substrate-delete` removes kagent and the substrate platform
but keeps the cluster and the mirrored images.

Full setup details — what ate-system needs (podcert API gating, CA/JWT pool
bootstrap, controller wiring, the default `kagent-default` WorkerPool) and
troubleshooting notes from real runs — live in
[docs/substrate-kagent.md](docs/substrate-kagent.md).

## Hosting the internal website

The personal site lives in `../baladengale.github.io` (markdown rendered by
`build.py`, served by nginx). One target builds it, side-loads the image into
the nodes, applies the site repo's `deploy/` manifests **in order**
(namespace → deployment → service → route), rolls the pods, and refreshes
the cert SAN:

```bash
make site-deploy
# -> https://baladengale.internal
```

Re-run after any content change — the tag is always `:latest`, so the script
restarts the rollout to pick it up. The route (`deploy/route.yaml` in the
site repo) is plain YAML on the shared Gateway, identical to what
`make sync` would generate from the Service annotations.

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

Tests assume the default `KIND_CLUSTER_NAME=kagent` and `DOMAIN=internal`
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
kkind        # kubectl --context kind-kagent
kgw          # kubectl --context kind-kagent -n agentgateway-system
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
