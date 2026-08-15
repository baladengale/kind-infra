#!/usr/bin/env bash
#
# Local DNS: dnsmasq manages the *.${DOMAIN} zone -> 127.0.0.1, and macOS
# sends queries for that zone (only) to dnsmasq via /etc/resolver.
#
# Result: any Ingress host under ${DOMAIN} resolves, e.g. http://app.${DOMAIN}
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require brew dig
[[ "$(uname -s)" == "Darwin" ]] || die "macOS-only (uses Homebrew dnsmasq + /etc/resolver)."

# Homebrew refuses to run as root; sudo is invoked internally where needed.
[[ "$(id -u)" == "0" ]] && die "Don't run this as root — Homebrew breaks. Run 'make dns-install' as your regular user; the script calls sudo itself for /etc/resolver."

DOMAIN="${DOMAIN#.}"   # tolerate a leading dot
case "$DOMAIN" in
  test|internal) ;;
  local|*.local)
    die "'${DOMAIN}' ends in '.local', which macOS claims for Bonjour/mDNS — lookups stall or never reach dnsmasq via /etc/resolver. Prefer the default 'internal', or a fully reserved suffix like 'test' (kagent.test)."
    ;;
  localhost)
    warn "'.localhost' may be short-circuited to 127.0.0.1 by some apps; 'test' is the safe default."
    ;;
  *)
    warn "Using custom zone '${DOMAIN}' — make sure it does not collide with real domains."
    ;;
esac

BREW_PREFIX="$(brew --prefix)"
DNSMASQ_CONF="${BREW_PREFIX}/etc/dnsmasq.conf"
DNSMASQ_D="${BREW_PREFIX}/etc/dnsmasq.d"

command -v sudo >/dev/null 2>&1 || die "sudo is required to write /etc/resolver."

say "Configuring dnsmasq for *.${DOMAIN} -> 127.0.0.1..."
brew list dnsmasq >/dev/null 2>&1 || brew install dnsmasq

mkdir -p "$DNSMASQ_D"
touch "$DNSMASQ_CONF"
# Enable the drop-in directory exactly once (idempotent).
grep -qE "^conf-dir=${DNSMASQ_D}" "$DNSMASQ_CONF" 2>/dev/null || \
  printf "\n# kind-infra: drop-in directory\nconf-dir=%s\n" "$DNSMASQ_D" >> "$DNSMASQ_CONF"

cat > "${DNSMASQ_D}/kind-infra.conf" <<EOF
# Managed by kind-infra (scripts/40-dns-install.sh)
listen-address=127.0.0.1
bind-interfaces
local=/${DOMAIN}/
address=/${DOMAIN}/127.0.0.1
EOF

brew services restart dnsmasq >/dev/null

# Wait for dnsmasq to answer before wiring the system resolver.
ip=""
for _ in $(seq 1 10); do
  ip="$(dig +short "${DOMAIN}" @127.0.0.1 2>/dev/null | tail -1)"
  [[ "$ip" == "127.0.0.1" ]] && break
  sleep 1
done
[[ "$ip" == "127.0.0.1" ]] || die "dnsmasq not answering on 127.0.0.1:53 — check 'brew services info dnsmasq' and 'sudo lsof -i :53'"
ok "dnsmasq resolves *.${DOMAIN} -> 127.0.0.1"

say "Pointing macOS at dnsmasq for *.${DOMAIN} (sudo required)..."
sudo mkdir -p /etc/resolver
echo "nameserver 127.0.0.1" | sudo tee "/etc/resolver/${DOMAIN}" >/dev/null
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder 2>/dev/null || true

sys_ip="$(dscacheutil -q host -a name "test.${DOMAIN}" | awk '/^ip_address/ {print $2}')"
if [[ "$sys_ip" == "127.0.0.1" ]]; then
  ok "System resolves test.${DOMAIN} -> 127.0.0.1"
else
  warn "System resolver not returning it yet — run:"
  warn "  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
fi

echo
echo "Done. Any Ingress host under ${DOMAIN} now resolves, e.g.: http://app.${DOMAIN}"
echo "Add a service by creating an Ingress with host: <name>.${DOMAIN}"
