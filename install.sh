#!/usr/bin/env bash

# Shinkai - VLESS Reality installer
# Usage:
#   sudo bash install.sh [server-address] [sni-domain]
#   curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install.sh | sudo bash -s -- [server-address] [sni-domain]

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
LOG_FILE="/tmp/shinkai-vless-install.log"
FAILED=0

SERVER_ADDR="${1:-${VLESS_SERVER:-${SERVER_ADDR:-}}}"
SNI_DOMAIN="${2:-${VLESS_SNI:-${SNI_DOMAIN:-}}}"
PORT="${VLESS_PORT:-8443}"
DEFAULT_SNI="static.rutube.ru"
CONFIG_DIR="/root/vless-config"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

print_header() {
  clear 2>/dev/null || true
  echo ""
  echo -e "${CYAN}${BOLD}  ============================================${NC}"
  echo -e "${CYAN}${BOLD}    Shinkai - VLESS Reality Installer${NC}"
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
Shinkai VLESS Reality installer

Usage:
  sudo bash install.sh [server-address] [sni-domain]
  curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install.sh | sudo bash -s -- [server-address] [sni-domain]

Environment:
  VLESS_SERVER  Server IP or domain
  VLESS_SNI     Reality SNI domain, default: ${DEFAULT_SNI}
  VLESS_PORT    Listen port, default: 8443
EOF
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "Run as root: sudo bash install.sh"
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

collect_input() {
  print_header
  echo -e "  ${CYAN}${BOLD}Configuration${NC}"
  echo ""

  if [ -z "$SERVER_ADDR" ]; then
    SERVER_ADDR="$(read_from_tty "Server address (IP or domain)")"
  fi

  if [ -z "$SERVER_ADDR" ]; then
    fail "Server address cannot be empty."
  fi

  if [ -z "$SNI_DOMAIN" ]; then
    info "Recommended SNI: static.rutube.ru, cloudflare.com, www.google.com"
    SNI_DOMAIN="$(read_from_tty "SNI domain" "$DEFAULT_SNI")"
  fi

  SNI_DOMAIN="${SNI_DOMAIN:-$DEFAULT_SNI}"

  echo ""
  echo -e "  ${CYAN}${BOLD}Install plan${NC}"
  info "Server: ${SERVER_ADDR}"
  info "SNI: ${SNI_DOMAIN}"
  info "Port: ${PORT}/tcp"
  info "Protocol: VLESS + Reality + TCP + xtls-rprx-vision"

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
  step_start "Generating Reality keys..."

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
  step_start "Writing Xray configuration..."

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
      "tag": "vless-reality",
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
          "dest": "${SNI_DOMAIN}:443",
          "serverNames": ["${SNI_DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

  step_done "Xray configuration written"
  echo ""
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

  VLESS_LINK="vless://${UUID}@${SERVER_ADDR}:${PORT}?type=tcp&security=reality&fp=random&pbk=${PUBLIC_KEY}&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Shinkai"

  cat > "${CONFIG_DIR}/keys.txt" <<EOF
Server: ${SERVER_ADDR}
SNI: ${SNI_DOMAIN}
Port: ${PORT}

UUID: ${UUID}
Private Key: ${PRIVATE_KEY}
Public Key: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
EOF

  cat > "${CONFIG_DIR}/links.txt" <<EOF
VLESS Link:
${VLESS_LINK}

Connection Parameters:
UUID:        ${UUID}
Public Key:  ${PUBLIC_KEY}
Short ID:    ${SHORT_ID}
SNI:         ${SNI_DOMAIN}
Type:        tcp
Security:    reality
Fingerprint: random
Flow:        xtls-rprx-vision
Port:        ${PORT}
EOF

  chmod 600 "${CONFIG_DIR}/keys.txt" "${CONFIG_DIR}/links.txt"

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
    echo -e "  ${GREEN}${BOLD}  Installation completed${NC}"
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
  echo -e "  ${CYAN}${BOLD}VLESS link:${NC}"
  echo ""
  echo -e "  ${YELLOW}${VLESS_LINK}${NC}"
  echo ""
  echo -e "  ${DIM}View link:   cat ${CONFIG_DIR}/links.txt${NC}"
  echo -e "  ${DIM}View keys:   cat ${CONFIG_DIR}/keys.txt${NC}"
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
  info "Server: ${SERVER_ADDR}"
  info "SNI: ${SNI_DOMAIN}"
  info "Port: ${PORT}/tcp"
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
