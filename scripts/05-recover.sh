#!/usr/bin/env bash
#
# Post-restart recovery — `make recover`.
#
# A host reboot (or Docker Desktop restart) renumbers container and pod IPs,
# which breaks this stack in two known ways:
#   1. default/kind-registry Endpoints still point at the registry container's
#      old kind-network IP  -> https://kind-registry.* returns 503
#      (scripts/50-registry.sh sync fixes it)
#   2. substrate worker registrations hold pre-restart pod IPs, so actor
#      dispatches route to dead addresses -> every agent invoke fails with
#      "input was not accepted" after a 5s timeout
#      (recycling the kagent-default workerpool pods re-registers them)
#
# Everything here is idempotent: run it after any Docker/host restart before
# using the cluster.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require kubectl curl

# 1. Docker daemon: start Docker Desktop if the socket is gone.
if ! docker info >/dev/null 2>&1; then
  say "Docker daemon not reachable — starting Docker Desktop..."
  open -a Docker 2>/dev/null || die "docker daemon down and 'open -a Docker' failed — start it manually."
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 5
  done
  docker info >/dev/null 2>&1 || die "docker daemon did not come up within 5 minutes."
fi
ok "docker daemon up"

# 2. Cluster containers: kind restart policies usually revive them, but make
#    sure both are running before waiting on the API.
for c in "$KIND_CLUSTER_NAME-control-plane" kind-registry; do
  state="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo missing)"
  if [ "$state" != "true" ]; then
    [ "$state" = "missing" ] && die "container $c does not exist — run 'make create' first."
    say "Starting stopped container $c..."
    docker start "$c" >/dev/null
  fi
done

# 3. Kubernetes API + node Ready.
say "Waiting for the Kubernetes API and node..."
for _ in $(seq 1 60); do
  kctl get nodes 2>/dev/null | grep -q " Ready " && break
  sleep 5
done
kctl get nodes 2>/dev/null | grep -q " Ready " || die "node never became Ready."
ok "node Ready"

# 4. Let crashed-at-the-moment-of-freeze pods settle (kubelet status catch-up).
sleep 20

# 5. Registry Endpoints vs the container's current kind-network IP.
reg_ip="$(docker inspect kind-registry -f \
  '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "kind"}}{{$v.IPAddress}}{{end}}{{end}}')"
ep_ip="$(kctl -n default get endpoints kind-registry -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
if [ -n "$reg_ip" ] && [ "$reg_ip" != "$ep_ip" ]; then
  say "Registry Endpoints stale ($ep_ip -> $reg_ip) — syncing..."
  bash "$ROOT_DIR/scripts/50-registry.sh" sync
else
  ok "registry endpoint in sync ($ep_ip)"
fi

# 6. Substrate worker registrations: the syncer warns on IP disagreement.
#    Recycling the workerpool pods forces fresh registrations (actors are
#    snapshot-backed, so this is the designed resume path).
if kctl -n ate-system get deploy ate-controller >/dev/null 2>&1; then
  if kctl logs -n ate-system deploy/ate-controller --since=15m 2>/dev/null \
      | grep -q "registered worker IP disagrees with its pod"; then
    say "Stale substrate worker registrations — recycling the kagent-default workerpool..."
    kctl -n kagent delete pod -l ate.dev/worker-pool=kagent-default --wait=false >/dev/null
    kctl -n kagent wait --for=condition=Ready pod -l ate.dev/worker-pool=kagent-default --timeout=180s >/dev/null
    sleep 15
    if kctl logs -n ate-system deploy/ate-controller --since=1m 2>/dev/null \
        | grep -q "registered worker IP disagrees"; then
      warn "worker IPs still disagree after recycle — check ate-controller logs"
    else
      ok "substrate workers re-registered"
    fi
  else
    ok "substrate worker registrations fresh"
  fi

  # 7. Report (not repair) crashed actors — recovery is surgical: patch
  #    atepg.actors.proto status.state 7->4, drop status.worker_assignment,
  #    and never bump the version column (it must equal the proto's
  #    metadata.version). See the substrate-crashed-actor-recovery playbook.
  crashed="$(for n in $(kubectl exec -n ate-system postgres-0 -- psql -U postgres -d atepg -tA \
      -c "SELECT name FROM actors WHERE name LIKE 'ai-%'" 2>/dev/null); do
    kubectl exec -n ate-system postgres-0 -- psql -U postgres -d atepg -tA -c \
      "SELECT encode(proto,'base64') FROM actors WHERE name='$n'" 2>/dev/null | python3 -c '
import sys, base64
def fields(buf):
    out, i = [], 0
    while i < len(buf):
        k = 0; s = 0
        while True:
            b = buf[i]; i += 1; k |= (b & 0x7F) << s; s += 7
            if not b & 0x80: break
        f, w = k >> 3, k & 7
        if w == 0:
            v = 0; s = 0
            while True:
                b = buf[i]; i += 1; v |= (b & 0x7F) << s; s += 7
                if not b & 0x80: break
            out.append((f, w, v))
        elif w == 2:
            ln = 0; s = 0
            while True:
                b = buf[i]; i += 1; ln |= (b & 0x7F) << s; s += 7
                if not b & 0x80: break
            out.append((f, w, buf[i:i+ln])); i += ln
        elif w == 5: out.append((f, w, buf[i:i+4])); i += 4
        elif w == 1: out.append((f, w, buf[i:i+8])); i += 8
    return out
for f, w, v in fields(base64.b64decode(sys.stdin.read().strip())):
    if f == 7 and w == 2:
        print(next(sv for sf, sw, sv in fields(v) if sf == 1 and sw == 0))
'
  done | grep -c "^7$" || true)"
  if [ "${crashed:-0}" != "0" ]; then
    warn "$crashed actor(s) are CRASHED — 'make kagent-mcp-test' will fail on them; apply the atepg proto patch (state 7->4), then recycle workerpool pods"
  else
    ok "no crashed substrate actors"
  fi
fi

# 8. Route probes.
say "Probing routes..."
fail=0
for h in kagent kagent-api hub baladengale kind-registry; do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://$h.$DOMAIN/" || echo 000)"
  if [ "$code" = "200" ]; then
    ok "https://$h.$DOMAIN -> $code"
  else
    warn "https://$h.$DOMAIN -> $code"
    fail=1
  fi
done

[ "$fail" = "0" ] && ok "recovery complete" || die "one or more routes unhealthy — see warnings above."
