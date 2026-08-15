#!/usr/bin/env bash
#
# Undo scripts/40-dns-install.sh: remove the macOS resolver entry and the
# dnsmasq zone. dnsmasq itself stays installed/running for other uses.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BREW_PREFIX="$(brew --prefix)"

# Homebrew refuses to run as root; sudo is invoked internally where needed.
if [[ "$(id -u)" == "0" ]]; then
  echo "Don't run this as root — Homebrew breaks. Run 'make dns-remove' as your regular user." >&2
  exit 1
fi

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
