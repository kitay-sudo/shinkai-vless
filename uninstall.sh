#!/usr/bin/env bash

# Shinkai - full uninstall
# Stops the services this tool started and removes everything it installed.
# Usage:
#   sudo bash uninstall.sh
#   curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/uninstall.sh | sudo bash

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_DIR="/root/vless-config"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo -e "${RED}Run as root: sudo bash uninstall.sh${NC}" >&2
  exit 1
fi

echo ""
echo -e "${CYAN}${BOLD}  Shinkai - uninstall${NC}"
echo ""

# Collect ports from the config before we delete it, so we can close the firewall.
PORTS=""
if [ -f "$XRAY_CONFIG" ]; then
  PORTS="$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$XRAY_CONFIG" | grep -oE '[0-9]+' | tr '\n' ' ')"
fi
PORTS="${PORTS} 443 8443"

# 1. Stop and disable the Xray service, then kill any orphaned xray process
#    (e.g. left over from a failed install) so our port is actually freed.
systemctl stop xray >/dev/null 2>&1 || true
systemctl disable xray >/dev/null 2>&1 || true
pkill -x xray >/dev/null 2>&1 || true
echo -e "  ${GREEN}OK${NC} Xray service stopped"

# 2. Remove Xray via its official installer (purges service, binary, logs, geodata).
if curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-remove.sh 2>/dev/null; then
  bash /tmp/xray-remove.sh remove --purge >/dev/null 2>&1 || true
  rm -f /tmp/xray-remove.sh
fi

# 3. Remove anything the installer may have left behind.
rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray "$CONFIG_DIR" >/dev/null 2>&1 || true
rm -f /usr/local/bin/xray /usr/local/bin/vless-mode >/dev/null 2>&1 || true
rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service >/dev/null 2>&1 || true
rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
echo -e "  ${GREEN}OK${NC} Binaries, configs and keys removed"

# 4. Close the firewall ports the installer opened.
for p in $PORTS; do
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -D INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
  fi
done
if command -v iptables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
echo -e "  ${GREEN}OK${NC} Firewall rules cleaned"

# 5. Tell the user if another (foreign) service still sits on the usual ports.
if command -v ss >/dev/null 2>&1; then
  for p in 443 8443; do
    leftover="$(ss -tlnp "( sport = :${p} )" 2>/dev/null | grep -i LISTEN || true)"
    if [ -n "$leftover" ]; then
      who="$(printf '%s' "$leftover" | grep -oE 'users:\(\("[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"/\1/')"
      echo -e "  ${YELLOW}!${NC} Port ${p}/tcp is still used by another service: ${who:-unknown} (not ours, left untouched)"
    fi
  done
fi

echo ""
echo -e "  ${GREEN}${BOLD}Shinkai fully removed.${NC}"
echo -e "  ${DIM}Gone: xray service + binary, ${XRAY_CONFIG%/*}, ${CONFIG_DIR}, vless-mode${NC}"
echo ""
