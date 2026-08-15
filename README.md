# kind-infra

Local Kubernetes base infrastructure, managed with make:

- **kind cluster** with host ports 80/443 published for ingress
- **local container registry** (`localhost:5001`, wired into every node)
- **MetalLB** — LoadBalancer services get IPs from the kind network pool
- **ingress-nginx** — routes `http://<name>.<domain>` to services by Host header
- **local DNS** (dnsmasq + macOS resolver) — `*.<domain>` resolves to 127.0.0.1

## Quickstart

```bash
make create     # everything above, idempotent
make status     # verify each layer
```

Then expose any app:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: myapp, namespace: default }
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.local.test
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: myapp, port: { number: 80 } }
```

`http://myapp.local.test` works immediately — DNS is a wildcard, no per-host
DNS edits, no port-forwarding.

## Lifecycle targets

| Target | What it does |
|---|---|
| `make create` | Cluster + registry + MetalLB + ingress + DNS |
| `make update` | Re-apply addons on the existing cluster (idempotent; picks up version bumps) |
| `make upgrade` | Recreate the cluster with the current `KIND_IMAGE_VERSION` (destructive) |
| `make delete` | Remove DNS, delete cluster and registry |
| `make delete-cluster` | Delete only the cluster |
| `make dns-install` / `make dns-remove` | Just the DNS zone |
| `make status` | Show clusters, addons, registry, DNS state |

### Variables (override on the command line)

| Variable | Default | Purpose |
|---|---|---|
| `DOMAIN` | `local.test` | DNS zone managed by dnsmasq |
| `KIND_CLUSTER_NAME` | `kind` | Cluster name (context: `kind-kind`) |
| `KIND_IMAGE_VERSION` | `1.35.0` | `kindest/node` version — bump + `make upgrade` |
| `METALLB_VERSION` | `v0.15.3` | MetalLB manifest version |
| `INGRESS_NGINX_REF` | `main` | ingress-nginx manifest ref |
| `CONTAINER_RUNTIME` | auto (podman→docker) | Runtime kind runs on |

Example — a second cluster with its own zone:

```bash
make create KIND_CLUSTER_NAME=dev DOMAIN=dev.test
```

## How it fits together

```
http://myapp.local.test
  │  1. macOS routes *.local.test to dnsmasq (/etc/resolver/local.test)
  │  2. dnsmasq answers 127.0.0.1
  ▼
127.0.0.1:80  (kind extraPortMappings)
  ▼
  3. ingress-nginx routes by Host header
  ▼
Service myapp
```

Notes:
- `.test` is RFC 6761-reserved for local use (avoid `.dev` — HSTS-preloaded;
  and `.local` — reserved for mDNS).
- On macOS/Docker Desktop, MetalLB IPs (172.18.255.x) are **not** reachable
  from the host — that's why ingress goes through published host ports.
- Only the configured zone is routed to dnsmasq; the rest of your DNS is
  untouched.

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
```

## Debugging (layer by layer)

```bash
dig anything.local.test @127.0.0.1               # 1. dnsmasq -> 127.0.0.1?
curl -H "Host: myapp.local.test" http://127.0.0.1  # 2. ingress routing?
kubectl get ingress -A                           # 3. rules present?
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
