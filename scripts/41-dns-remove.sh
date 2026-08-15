#!/usr/bin/env bash
#
# Undo scripts/40-dns-install.sh: remove the macOS resolver entry and the
# dnsmasq zone. dnsmasq itself stays installed/running for other uses.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BREW_PREFIX="$(brew --prefix)"

if [[ -f "/etc/resolver/${DOMAIN}" ]]; then
  say "Removing /etc/resolver/${DOMAIN} (sudo)..."
  sudo rm -f "/etc/resolver/${DOMAIN}"
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder 2>/dev/null || true
  ok "Resolver entry removed"
else
  ok "No resolver entry for ${DOMAIN}"
fi

if [[ -f "${BREW_PREFIX}/etc/dnsmasq.d/kind-infra.conf" ]]; then
  say "Removing dnsmasq zone for *.${DOMAIN}..."
  rm -f "${BREW_PREFIX}/etc/dnsmasq.d/kind-infra.conf"
  brew services restart dnsmasq >/dev/null 2>&1 || true
  ok "dnsmasq zone removed (stop fully with: brew services stop dnsmasq)"
else
  ok "No dnsmasq drop-in found"
fi
