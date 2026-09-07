# Agent Substrate + kagent on kind-infra — setup and runbook

How this repo runs [Agent Substrate](https://github.com/kagent-dev/substrate)
as the compute platform for kagent agents: what the `ate-system` platform
needs, how `make substrate-create` wires it up, and the failure modes we have
actually hit (each with the fix that worked).

Short version:

```bash
make substrate-create   # cluster (substrate feature gates) + platform + kagent + sample agent
make substrate-status   # ate-system pods, WorkerPools, sample agent state
make substrate-delete   # remove kagent + substrate (cluster and registry stay)
```

`SUBSTRATE_VERSION` (default `0.0.25`, set in `scripts/common.sh` / `Makefile`)
picks the platform chart + `kubectl-ate` + ateom image version. Upstream CI
runs the same sequence — `.github/workflows/ci.yaml` in the kagent repo is
the source of truth for the bootstrap order.

## What ate-system needs

Substrate is not a single chart install. A working platform is four things:

### 1. Pod-identity APIs on the cluster (both server and node)

Substrate gives every Actor a workload identity via `podCertificate`
projected volumes and distributes trust via `ClusterTrustBundle` projections.
On kubernetes >= 1.34 these are **beta APIs, off by default**:

- API group `certificates.k8s.io/v1beta1` (serves `PodCertificateRequest`,
  `ClusterTrustBundle`) — needs `--runtime-config` **and** the
  `PodCertificateRequest` + `ClusterTrustBundle` feature gates on the
  API server
- `ClusterTrustBundleProjection` gate on the API server (otherwise the API
  server silently **strips** the `clusterTrustBundle`/`podCertificate`
  sources from stored PodSpecs — pods then mount empty volumes and every
  substrate component crash-loops reading a missing `trust-bundle.pem`)
- The same three gates on the **kubelet** (otherwise volume setup fails with
  `MountVolume.SetUp failed ... : unimplemented`). Note the kubelet's gate is
  also named `PodCertificateRequest` — there is no `PodCertificate` gate, and
  an unknown gate name panics the kubelet at startup. Also,
  `ClusterTrustBundleProjection` depends on `ClusterTrustBundle` — enable both.

Fresh clusters: `kind/kind-config-substrate.yaml` (used by
`make substrate-create`) sets all of this at creation time.

Existing clusters: `scripts/85-substrate.sh install` detects the missing API
(`kubectl get --raw /apis/certificates.k8s.io/v1beta1`) and live-patches:

1. `/etc/kubernetes/manifests/kube-apiserver.yaml` inside the
   `<cluster>-control-plane` container — fills kind's empty
   `--runtime-config=` and adds the feature gates; the kubelet picks up the
   static-pod change and restarts the API server
2. `/var/lib/kubelet/config.yaml` — appends the `featureGates` block, then
   `systemctl restart kubelet` (kind nodes run systemd)
3. Waits until the API is served, then continues with the chart installs

The patches live in the node container's writable layer: they survive
`docker stop/start`, but a **cluster recreation** loses them (fresh clusters
get the flags from the kind config instead).

### 2. Platform charts (`substrate-crds` + `substrate` in `ate-system`)

Installed from the published OCI charts
(`oci://ghcr.io/kagent-dev/substrate/helm`), with atelet configured for the
local registry: `--localhost-registry-replacement=kind-registry.default.svc:5000`.
atelet pulls Actor images itself (go-containerregistry, not containerd), so
the usual containerd `certs.d` wiring does not apply to it — the flag
rewrites `localhost:5001/...` refs (what kagent renders) to the in-cluster
registry Service.

The first install runs **without** `--wait` (pods cannot start before step 3
exists), the bootstrap runs, then a `--reuse-values --wait` upgrade waits for
real convergence.

### 3. One-time CA/JWT bootstrap (kubectl-ate)

The platform's own PKI is empty on a bare cluster. `scripts/85-substrate.sh`
downloads `kubectl-ate` (skipped if already in `tools/`, which is
gitignored) and creates:

- `service-dns-ca-pool` + `pod-identity-ca-pool` secrets in
  `podcertificate-controller-system`
- `actor-id-jwt-pool` + `actor-id-ca-pool` secrets in `ate-system`
- the `actor-id-ca-certs` secret (CA root extracted from the pool) and the
  `ate-api-authentication` ConfigMap (Kubernetes-issued-JWT actor identity)
  in `ate-system`

Skipped when the pools already exist — regenerating them would invalidate
every issued pod certificate.

### 4. kagent wired to the platform + default WorkerPool

`scripts/80-kagent.sh SUBSTRATE_ENABLED=true` (via
`make kagent-build-deploy SUBSTRATE_ENABLED=true`) layers
`kagent/values-substrate.yaml` onto the chart:

- `controller.substrate.enabled` — injects the `SUBSTRATE_*` env vars and the
  projected pod-certificate volumes into the controller
- `controller.substrate.ateApiEndpoint: dns:///api.ate-system.svc:443` and
  `atenetRouterURL: http://atenet-router.ate-system.svc:80` — explicit
  because we install the platform standalone, not as a kagent subchart
- `substrateWorkerPool.create/name: kagent-default`, `replicas: 2`,
  `sandboxClass: gvisor` — the default WorkerPool actors are scheduled onto;
  `workerImage` is set by the script to the mirrored ateom image
  (`localhost:5001/...`, rewritten by atelet in-cluster)

The kagent controller dials ate-api **at startup and dies without it**, so
order matters: platform first (`85-substrate.sh install`), kagent second.
`substrate-create` sequences this; `substrate_sets` in `80-kagent.sh`
re-checks and refuses to deploy kagent without a healthy platform.

## The sample agent (`hello-substrate`)

`make substrate-create` (or `make substrate-samples` on an existing stack)
deploys a reference agent you can validate the platform against — shape
copied from the kagent repo's e2e fixtures
(`go/core/test/e2e/manifests/lifecycle.yaml.tmpl`):

- `Harness/kagent` — the Go ADK runtime adapter, pinned to the digest of the
  golang-adk image that the deployed controller was built with (resolved
  from the local registry; the CRD rejects tag-only refs)
- `AgentTemplate/hello-substrate` — a declarative agent whose system prompt
  describes its own runtime, labeled to match the harness admission selector
- one `AgentInstance` created through the kagent CLI

```bash
make substrate-validate   # invoke it: the answer must describe the gVisor actor
kagent get agent-instance # STATE stays READY — see "Where is my pod?" below
```

The same playbook adopts any AgentTemplate: give it the harness's
`matchLabels` (here `kagent.dev/sample: kagent`), then
`kagent create agent-instance --harness kagent --agent-template <name>`.
The UI's View → Substrate page shows the underlying actors.

## Troubleshooting — things that actually broke

**Substrate pods crash-loop reading `trust-bundle.pem` /
`credential-bundle.pem`.** The podcert APIs are not enabled (see §1). After
enabling them on a cluster where substrate was already installed:
**delete and re-apply the charts — do not just rollout-restart.** Workloads
created while the APIs were off keep pod templates with the projected volume
sources stripped to `{}`; new pods copy the poisoned ReplicaSet template no
matter how many times pods are recycled. The install script does this
automatically (uninstalls a pre-existing broken `substrate` release before
installing). If Helm's 3-way merge keeps stale empty `sources` entries even
after re-applying, delete the affected Deployment/StatefulSet and let the
upgrade recreate it — projected `sources` merge by `path`, and empty old
entries poison the merge.

**kubelet panics after adding feature gates.** An unknown gate name
(`PodCertificate` is the classic wrong guess) or a dependency violation
(`ClusterTrustBundleProjection` needs `ClusterTrustBundle`). The exact names
are in `kind-config-substrate.yaml`. Restore with
`cp /var/lib/kubelet/config.yaml.pre-substrate-bak /var/lib/kubelet/config.yaml && systemctl restart kubelet`
inside the node container.

**`helm upgrade` fails with `storedVersions[0]: Invalid value: "v1alpha2"`.**
Clusters upgraded from kagent releases older than v0.10.0 hold legacy
v1alpha2 objects (`agents`, `modelconfigs`, `remotemcpservers`, ...). The new
chart drops those storage versions; kubernetes refuses the CRD update while
`status.storedVersions` still names them. For a dev cluster: back the objects
up, delete them, delete the stale CRDs, and re-run the install (recreate the
ModelConfigs you care about as `v1alpha3`). If a helm release then cannot
compute its diff (`resource mapping not found for kind "Agent"`), uninstall
the release manually (delete its labeled resources + `sh.helm.release.v1.*`
secrets) and install fresh — the postgres PVC survives and is re-bound.

**Controller: `unsupported migration table. Use a new PostgreSQL database`.**
kagent switched to goose migrations; it refuses databases last migrated by
golang-migrate. Delete the `kagent-postgresql` PVC and restart the postgres
pod for a fresh database (dev-only shortcut — legacy session data belongs to
the retired v1alpha2 agents anyway).

**Controller CrashLoop `connection refused` to postgres right after
install.** Just the postgres startup race — the controller retries and
converges; `kubectl delete pod` on the controller skips the backoff wait.

**Invoke fails with `Connect: deadline has elapsed` after ~10s.** The CLI's
default connection deadline is 10s, but the first invoke pays a COLD actor
restore (gVisor snapshot rehydration, ~20-40s), and the actor suspends again
after every task boundary — so every invoke can be a cold wake. Pass
`--timeout 120s` (the sample script's validate does). Warm invocations take
1-2s.

**"Where is my pod?" — no new pod appears when you chat.** That is the
design: agents are NOT per-agent Deployments anymore. The AgentInstance's
actor runs INSIDE a `kagent-default` worker pod's gVisor sandbox, and
between requests it is checkpointed to the snapshot store and its worker
slot released. What a chat actually does (watch with
`kubectl logs -n kagent kagent-default-<TAB> -f` during an invoke):

1. `RestoreWorkload` — the actor snapshot is rehydrated into a worker's
   gVisor sandbox ("Readyz reached 200" when the agent app is up)
2. the A2A request is served through the atenet router
3. `CheckpointWorkload` — a fresh snapshot is written and the sandbox is
   torn down (often ~1s after the restore on a short task)

The AgentInstance STATE deliberately stays `READY` through all of this
(quiescence leaves the instance logically ready). Actor-level visibility:
the kagent UI → View → Substrate, and the worker pod logs above.

**`kubectl get actors` fails (`the server doesn't have a resource type`).**
Actors are ate-api inventory objects, not Kubernetes resources — kubectl can
only see `workerpools.ate.dev`. Actor state: kagent UI → View → Substrate,
or the AgentInstance STATE via `kagent get agent-instance`.

**`kubectl-ate get actors` fails `token issuer ... not trusted`.** The
`ate-api-authentication` ConfigMap trusts issuer
`https://kubernetes.default.svc`, but kind's service-account tokens are
issued as `https://kubernetes.default.svc.cluster.local`. Only affects
ad-hoc `kubectl-ate get/logs` calls (the controller authenticates with pod
certificates, and CI only uses `kubectl-ate admin`, which talks to the k8s
API). To fix, add the `.cluster.local` issuer as a second jwtProviders entry
and restart ate-api.

## Day-2 notes

- Agents on substrate show up as `AgentInstance` (PostgreSQL/gRPC control
  plane), not Kubernetes objects. `kubectl get workerpool -A` shows
  the platform side; the UI (https://kagent.internal → View → Substrate)
  shows actor state, and `kagent get agent-instance` shows instance lifecycle.
- Between requests an actor is `Suspended` (snapshot stored, worker slot
  released); the next A2A request auto-resumes it. First golden snapshot
  after creating an agent takes about a minute.
- `kubectl scale workerpool kagent-default -n kagent --replicas=3` sizes the
  pool until the next helm upgrade; change `substrateWorkerPool.replicas` in
  `kagent/values-substrate.yaml` for a persistent value.
