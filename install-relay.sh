#!/usr/bin/env bash

# Shinkai - VLESS Reality relay (RF transit node) installer
# Chains: client -> this RF server (whitelisted IP) -> upstream VLESS server (Sweden)
#
# Usage:
#   sudo bash install-relay.sh [rf-server-address] ["upstream vless:// link"]
#   curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install-relay.sh | sudo bash -s -- [rf-server-address] ["upstream vless:// link"]

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

CHECK='OK'
CROSS='FAIL'
ARROW='->'
SPIN='-\|/'

TOTAL_STEPS=7
CURRENT_STEP=0
LOG_FILE="/tmp/shinkai-relay-install.log"
FAILED=0

# RF (this) server, the entry node the client connects to
RF_ADDR="${1:-${RF_SERVER:-${RF_ADDR:-}}}"
INBOUND_SNI="${RELAY_SNI:-${INBOUND_SNI:-}}"
PORT="${RELAY_PORT:-443}"
DEFAULT_SNI="ozon.ru"

# Upstream (Sweden) server, pasted as a vless:// link
UPSTREAM_LINK="${2:-${SWEDEN_LINK:-${UPSTREAM_LINK:-}}}"

CONFIG_DIR="/root/vless-config"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# Parsed upstream fields
SE_ADDR=""
SE_PORT=""
SE_UUID=""
SE_PBK=""
SE_SNI=""
SE_SID=""
SE_FLOW=""

cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

print_header() {
  clear 2>/dev/null || true
  echo ""
  echo -e "${CYAN}${BOLD}  ============================================${NC}"
  echo -e "${CYAN}${BOLD}    Shinkai - VLESS Relay (RF transit)${NC}"
  echo -e "${CYAN}${BOLD}  ============================================${NC}"
  echo ""
}

info() {
  echo -e "       ${DIM}${ARROW} $1${NC}"
}

warn() {
  echo -e "  ${YELLOW}!${NC} $1"
}

fail() {
  echo -e "  ${RED}${CROSS}${NC} $1"
  exit 1
}

step_start() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo -e "  ${BLUE}${BOLD}[$CURRENT_STEP/$TOTAL_STEPS]${NC} ${YELLOW}..${NC} $1"
}

step_done() {
  echo -e "\033[1A\033[2K  ${BLUE}${BOLD}[$CURRENT_STEP/$TOTAL_STEPS]${NC} ${GREEN}${CHECK}${NC} $1"
}

step_fail() {
  echo -e "\033[1A\033[2K  ${BLUE}${BOLD}[$CURRENT_STEP/$TOTAL_STEPS]${NC} ${RED}${CROSS}${NC} $1"
  FAILED=1
}

run_with_spinner() {
  local message="$1"
  shift

  : > "$LOG_FILE"
  "$@" > "$LOG_FILE" 2>&1 &
  local pid=$!
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    local char="${SPIN:$i:1}"
    printf "\r       ${YELLOW}%s${NC} ${DIM}%s${NC}  " "$char" "$message"
    i=$(( (i + 1) % ${#SPIN} ))
    sleep 0.1
  done

  set +e
  wait "$pid"
  local code=$?
  set -e
  printf "\r\033[2K"
  return "$code"
}

show_log_tail() {
  tail -n "${1:-8}" "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    info "$line"
  done
}

read_from_tty() {
  local prompt="$1"
  local default_value="${2:-}"
  local value=""

  if [ -r /dev/tty ]; then
    if [ -n "$default_value" ]; then
      printf "%b" "  ${prompt} [${default_value}]: " > /dev/tty
    else
      printf "%b" "  ${prompt}: " > /dev/tty
    fi
    IFS= read -r value < /dev/tty || true
  elif [ -t 0 ]; then
    if [ -n "$default_value" ]; then
      read -r -p "  ${prompt} [${default_value}]: " value || true
    else
      read -r -p "  ${prompt}: " value || true
    fi
  fi

  if [ -z "$value" ]; then
    value="$default_value"
  fi

  printf "%s" "$value"
}

usage() {
  cat <<EOF
Shinkai VLESS relay (RF transit node) installer

Builds a chain:
  client -> THIS server (whitelisted RF IP) -> upstream VLESS server (Sweden)

Usage:
  sudo bash install-relay.sh [rf-server-address] ["upstream vless:// link"]
  curl -sSL .../install-relay.sh | sudo bash -s -- [rf-server-address] ["upstream vless:// link"]

Environment:
  RF_SERVER     This server public IP or domain (for the client link)
  SWEDEN_LINK   Upstream vless:// link (from install.sh output)
  RELAY_SNI     Reality SNI for client->RF hop, default: ${DEFAULT_SNI}
  RELAY_PORT    Listen port for incoming clients, default: 443
EOF
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "Run as root: sudo bash install-relay.sh"
  fi
}

require_linux() {
  if [ "$(uname -s)" != "Linux" ]; then
    fail "This installer supports Linux servers only."
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    fail "apt-get not found. Use Debian or Ubuntu."
  fi
}

get_query_param() {
  local q="$1" key="$2"
  printf '%s\n' "$q" | tr '&' '\n' | while IFS= read -r kv; do
    case "$kv" in
      "$key"=*) printf '%s' "${kv#*=}"; break ;;
    esac
  done
}

parse_upstream_link() {
  local link="$1"

  # Trim surrounding whitespace/quotes
  link="${link#"${link%%[![:space:]]*}"}"
  link="${link%"${link##*[![:space:]]}"}"
  link="${link#\"}"; link="${link%\"}"
  link="${link#\'}"; link="${link%\'}"

  case "$link" in
    vless://*) ;;
    *) return 1 ;;
  esac

  link="${link#vless://}"
  link="${link%%#*}"            # drop #fragment

  SE_UUID="${link%%@*}"
  local hostpart="${link#*@}"   # addr:port?query
  local hostport="${hostpart%%\?*}"
  local query=""
  case "$hostpart" in
    *\?*) query="${hostpart#*\?}" ;;
  esac

  SE_ADDR="${hostport%%:*}"
  SE_PORT="${hostport##*:}"

  SE_PBK="$(get_query_param "$query" pbk)"
  SE_SNI="$(get_query_param "$query" sni)"
  SE_SID="$(get_query_param "$query" sid)"
  SE_FLOW="$(get_query_param "$query" flow)"

  # Sweden server uses Vision; default it if the link omitted flow
  [ -z "$SE_FLOW" ] && SE_FLOW="xtls-rprx-vision"

  [ -n "$SE_UUID" ] && [ -n "$SE_ADDR" ] && [ -n "$SE_PORT" ] && \
    [ -n "$SE_PBK" ] && [ -n "$SE_SNI" ] && [ -n "$SE_SID" ]
}

collect_upstream() {
  if [ -n "$UPSTREAM_LINK" ]; then
    if parse_upstream_link "$UPSTREAM_LINK"; then
      return 0
    fi
    warn "Could not parse the provided upstream link, switching to manual entry."
  fi

  if [ -r /dev/tty ] || [ -t 0 ]; then
    local pasted
    pasted="$(read_from_tty "Paste upstream (Sweden) vless:// link")"
    if [ -n "$pasted" ] && parse_upstream_link "$pasted"; then
      return 0
    fi
    [ -n "$pasted" ] && warn "Link could not be parsed, entering fields manually."

    SE_ADDR="$(read_from_tty "Upstream server address (IP or domain)")"
    SE_PORT="$(read_from_tty "Upstream port" "8443")"
    SE_UUID="$(read_from_tty "Upstream UUID")"
    SE_PBK="$(read_from_tty "Upstream public key (pbk)")"
    SE_SNI="$(read_from_tty "Upstream SNI")"
    SE_SID="$(read_from_tty "Upstream short id (sid)")"
    SE_FLOW="$(read_from_tty "Upstream flow" "xtls-rprx-vision")"
  fi

  [ -n "$SE_UUID" ] && [ -n "$SE_ADDR" ] && [ -n "$SE_PORT" ] && \
    [ -n "$SE_PBK" ] && [ -n "$SE_SNI" ] && [ -n "$SE_SID" ] || \
    fail "Upstream parameters are incomplete."
}

collect_input() {
  print_header
  echo -e "  ${CYAN}${BOLD}Configuration${NC}"
  echo ""

  if [ -z "$RF_ADDR" ]; then
    RF_ADDR="$(read_from_tty "This RF server address (public IP or domain)")"
  fi
  [ -z "$RF_ADDR" ] && fail "RF server address cannot be empty."

  if [ -z "$INBOUND_SNI" ]; then
    info "Recommended SNI (whitelisted RU sites): ozon.ru, static.rutube.ru, yastatic.net"
    INBOUND_SNI="$(read_from_tty "Inbound SNI (client -> RF mask)" "$DEFAULT_SNI")"
  fi
  INBOUND_SNI="${INBOUND_SNI:-$DEFAULT_SNI}"

  echo ""
  echo -e "  ${CYAN}${BOLD}Upstream (Sweden)${NC}"
  collect_upstream

  echo ""
  echo -e "  ${CYAN}${BOLD}Install plan${NC}"
  info "Entry (client -> RF): ${RF_ADDR}:${PORT}/tcp, SNI ${INBOUND_SNI}"
  info "Upstream (RF -> Sweden): ${SE_ADDR}:${SE_PORT}, SNI ${SE_SNI}"
  info "Chain: client -> ${RF_ADDR} -> ${SE_ADDR} -> internet"
  info "Protocol: VLESS + Reality + xtls-rprx-vision (both hops)"

  if [ -r /dev/tty ]; then
    echo ""
    local confirm
    confirm="$(read_from_tty "Continue? (Y/n)" "Y")"
    case "$confirm" in
      y|Y|yes|YES|"") ;;
      *) fail "Installation cancelled." ;;
    esac
  fi
}

install_dependencies() {
  step_start "Installing system dependencies..."

  if run_with_spinner "apt update and install packages" \
    bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget unzip openssl ca-certificates >/dev/null"; then
    step_done "System dependencies installed"
  else
    step_fail "Dependency installation failed"
    show_log_tail 10
    exit 1
  fi
  echo ""
}

install_xray() {
  step_start "Installing Xray..."

  if run_with_spinner "download and run Xray installer" \
    bash -o pipefail -c "curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install"; then
    local version
    version="$(/usr/local/bin/xray version 2>/dev/null | head -n 1 | awk '{print $2}' || true)"
    step_done "Xray installed${version:+ (v${version})}"
  else
    step_fail "Xray installation failed"
    show_log_tail 10
    exit 1
  fi
  echo ""
}

generate_keys() {
  step_start "Generating Reality keys (entry hop)..."

  local keys
  keys="$(/usr/local/bin/xray x25519 2>&1)"

  PRIVATE_KEY="$(printf "%s\n" "$keys" | grep -iE "privat" | awk '{print $NF}' | head -n 1 || true)"
  PUBLIC_KEY="$(printf "%s\n" "$keys" | grep -iE "public|password" | awk '{print $NF}' | head -n 1 || true)"

  if [ -z "$PRIVATE_KEY" ]; then
    PRIVATE_KEY="$(printf "%s\n" "$keys" | sed -n '1p' | awk '{print $NF}' || true)"
  fi

  if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY="$(printf "%s\n" "$keys" | sed -n '2p' | awk '{print $NF}' || true)"
  fi

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  SHORT_ID="$(openssl rand -hex 8)"

  if [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$UUID" ] && [ -n "$SHORT_ID" ]; then
    step_done "Reality keys generated"
    info "UUID: ${UUID:0:8}..."
  else
    step_fail "Key generation failed"
    printf "%s\n" "$keys" | while IFS= read -r line; do info "$line"; done
    exit 1
  fi
  echo ""
}

write_xray_config() {
  step_start "Writing Xray relay configuration..."

  mkdir -p "$(dirname "$XRAY_CONFIG")"

  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "tag": "vless-in",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${INBOUND_SNI}:443",
          "serverNames": ["${INBOUND_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "to-upstream",
      "settings": {
        "vnext": [
          {
            "address": "${SE_ADDR}",
            "port": ${SE_PORT},
            "users": [
              {
                "id": "${SE_UUID}",
                "encryption": "none",
                "flow": "${SE_FLOW}"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SE_SNI}",
          "fingerprint": "chrome",
          "publicKey": "${SE_PBK}",
          "shortId": "${SE_SID}"
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["vless-in"],
        "outboundTag": "to-upstream"
      }
    ]
  }
}
EOF

  install_mode_switch

  step_done "Xray relay configuration written"
  echo ""
}

install_mode_switch() {
  cat > /usr/local/bin/vless-mode <<'MODESCRIPT'
#!/usr/bin/env bash
# vless-mode - switch the RF node between chain (-> upstream) and direct (RF exit)
set -e

XRAY_CONFIG="/usr/local/etc/xray/config.json"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root: sudo vless-mode $*" >&2
  exit 1
fi

current() {
  if grep -q '"outboundTag": "to-upstream"' "$XRAY_CONFIG"; then
    echo chain
  else
    echo direct
  fi
}

usage() {
  cat <<USAGE
Usage: vless-mode {chain|direct|status}
  chain   - traffic exits via upstream server (e.g. Sweden)
  direct  - traffic exits directly from this (RF) server
  status  - show current mode
USAGE
}

case "${1:-}" in
  chain)  target="to-upstream"; label="chain (-> upstream)" ;;
  direct) target="direct";      label="direct (RF exit)" ;;
  status) echo "Current mode: $(current)"; exit 0 ;;
  *) usage; exit 1 ;;
esac

sed -i -E 's/("outboundTag": ")[^"]+(")/\1'"$target"'\2/' "$XRAY_CONFIG"
systemctl restart xray
sleep 1

if systemctl is-active --quiet xray; then
  echo "Switched to: $label"
else
  echo "Xray failed to start. Check: journalctl -u xray -n 20" >&2
  exit 1
fi
MODESCRIPT

  chmod +x /usr/local/bin/vless-mode
}

configure_firewall() {
  step_start "Configuring firewall..."

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
    step_done "Firewall configured (ufw)"
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || \
      iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || true

    if command -v iptables-save >/dev/null 2>&1; then
      mkdir -p /etc/iptables 2>/dev/null || true
      iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    step_done "Firewall configured (iptables)"
  else
    step_done "Firewall skipped"
    warn "Open ${PORT}/tcp in your VPS firewall if needed."
  fi
  echo ""
}

start_xray() {
  step_start "Starting Xray service..."

  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray >/dev/null 2>&1 || true
  sleep 2

  if systemctl is-active --quiet xray; then
    step_done "Xray service running"
  else
    step_fail "Xray failed to start"
    journalctl -u xray -n 12 --no-pager 2>/dev/null | while IFS= read -r line; do info "$line"; done
    exit 1
  fi
  echo ""
}

save_result() {
  step_start "Saving credentials..."

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  VLESS_LINK="vless://${UUID}@${RF_ADDR}:${PORT}?type=tcp&security=reality&fp=random&pbk=${PUBLIC_KEY}&sni=${INBOUND_SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Shinkai-RF"

  cat > "${CONFIG_DIR}/relay-keys.txt" <<EOF
=== Entry hop (client -> RF) ===
RF Server: ${RF_ADDR}
Inbound SNI: ${INBOUND_SNI}
Port: ${PORT}

UUID: ${UUID}
Private Key: ${PRIVATE_KEY}
Public Key: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}

=== Upstream hop (RF -> Sweden) ===
Server: ${SE_ADDR}:${SE_PORT}
SNI: ${SE_SNI}
UUID: ${SE_UUID}
Public Key: ${SE_PBK}
Short ID: ${SE_SID}
Flow: ${SE_FLOW}
EOF

  cat > "${CONFIG_DIR}/relay-links.txt" <<EOF
VLESS Link (connect your client to the RF node):
${VLESS_LINK}

Connection Parameters:
Address:     ${RF_ADDR}
Port:        ${PORT}
UUID:        ${UUID}
Public Key:  ${PUBLIC_KEY}
Short ID:    ${SHORT_ID}
SNI:         ${INBOUND_SNI}
Type:        tcp
Security:    reality
Fingerprint: random
Flow:        xtls-rprx-vision

Chain: client -> ${RF_ADDR}:${PORT} -> ${SE_ADDR}:${SE_PORT} -> internet
EOF

  chmod 600 "${CONFIG_DIR}/relay-keys.txt" "${CONFIG_DIR}/relay-links.txt"

  PORT_OK=0
  if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
    PORT_OK=1
  fi

  step_done "Credentials saved to ${CONFIG_DIR}/"
  echo ""
}

print_result() {
  if [ "$FAILED" = "0" ] && [ "${PORT_OK:-0}" = "1" ]; then
    echo -e "  ${GREEN}${BOLD}============================================${NC}"
    echo -e "  ${GREEN}${BOLD}  Relay installation completed${NC}"
    echo -e "  ${GREEN}${BOLD}============================================${NC}"
  elif [ "$FAILED" = "0" ]; then
    echo -e "  ${YELLOW}${BOLD}============================================${NC}"
    echo -e "  ${YELLOW}${BOLD}  Installed, but port ${PORT} was not confirmed${NC}"
    echo -e "  ${YELLOW}${BOLD}============================================${NC}"
  else
    echo -e "  ${RED}${BOLD}============================================${NC}"
    echo -e "  ${RED}${BOLD}  Installation finished with warnings${NC}"
    echo -e "  ${RED}${BOLD}============================================${NC}"
  fi

  echo ""
  echo -e "  ${CYAN}${BOLD}Connect your client to the RF node with this link:${NC}"
  echo ""
  echo -e "  ${YELLOW}${VLESS_LINK}${NC}"
  echo ""
  echo -e "  ${DIM}Chain:       client -> ${RF_ADDR}:${PORT} -> ${SE_ADDR}:${SE_PORT} -> internet${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}Switch exit mode (same client link):${NC}"
  echo -e "  ${DIM}Via upstream: sudo vless-mode chain${NC}"
  echo -e "  ${DIM}Direct (RF):  sudo vless-mode direct${NC}"
  echo -e "  ${DIM}Show mode:    sudo vless-mode status${NC}"
  echo ""
  echo -e "  ${DIM}View link:   cat ${CONFIG_DIR}/relay-links.txt${NC}"
  echo -e "  ${DIM}View keys:   cat ${CONFIG_DIR}/relay-keys.txt${NC}"
  echo -e "  ${DIM}Status:      systemctl status xray${NC}"
  echo -e "  ${DIM}Logs:        journalctl -u xray -f${NC}"
  echo -e "  ${DIM}Restart:     systemctl restart xray${NC}"
  echo -e "  ${DIM}Check port:  ss -tlnp | grep ${PORT}${NC}"
  echo ""
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  require_root
  require_linux
  collect_input

  print_header
  info "Entry: ${RF_ADDR}:${PORT}/tcp (SNI ${INBOUND_SNI})"
  info "Upstream: ${SE_ADDR}:${SE_PORT} (SNI ${SE_SNI})"
  echo ""

  install_dependencies
  install_xray
  generate_keys
  write_xray_config
  configure_firewall
  start_xray
  save_result
  print_result
}

main "$@"
