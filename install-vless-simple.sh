#!/bin/bash

# ============================================
# Chameleon — Simple VLESS Reality Installer
# ============================================
# Usage: sudo ./install-vless-simple.sh
# Installs Xray with VLESS + Reality on port 8443
# One proven protocol, works everywhere

set -e

# Colors & styles
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# Symbols
CHECK="✔"
CROSS="✘"
ARROW="→"
SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

CURRENT_STEP=0
TOTAL_STEPS=7
FAILED=0

# ── Helpers ──────────────────────────────────

print_header() {
  clear
  echo ""
  echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}  ║     Chameleon — VLESS Reality Install    ║${NC}"
  echo -e "${CYAN}${BOLD}  ╚══════════════════════════════════════════╝${NC}"
  echo ""
}

step_start() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo -e "  ${BLUE}${BOLD}[$CURRENT_STEP/$TOTAL_STEPS]${NC} ${YELLOW}⟳${NC}  $1"
}

step_done() {
  echo -e "\033[1A\033[2K  ${BLUE}${BOLD}[$CURRENT_STEP/$TOTAL_STEPS]${NC} ${GREEN}${CHECK}${NC}  $1"
}

step_fail() {
  echo -e "\033[1A\033[2K  ${BLUE}${BOLD}[$CURRENT_STEP/$TOTAL_STEPS]${NC} ${RED}${CROSS}${NC}  $1"
  FAILED=1
}

info() {
  echo -e "         ${DIM}${ARROW} $1${NC}"
}

run_with_spinner() {
  local msg="$1"
  shift

  eval "$@" > /tmp/chameleon_install.log 2>&1 &
  local pid=$!
  local i=0

  while kill -0 $pid 2>/dev/null; do
    local char="${SPIN_CHARS:$i:1}"
    printf "\r         ${YELLOW}%s${NC} ${DIM}%s${NC}  " "$char" "$msg"
    i=$(( (i + 1) % ${#SPIN_CHARS} ))
    sleep 0.1
  done

  wait $pid
  local code=$?
  printf "\r\033[2K"
  return $code
}

# ── Preflight ────────────────────────────────

if [ "$EUID" -ne 0 ]; then
  echo -e "  ${RED}${CROSS}  Run this script as root (sudo)${NC}"
  exit 1
fi

# ── User Input ───────────────────────────────

print_header

echo -e "  ${CYAN}${BOLD}Configuration${NC}"
echo ""

read -p "  Server address (domain or IP): " SERVER_ADDR
if [ -z "$SERVER_ADDR" ]; then
  echo -e "  ${RED}${CROSS}  Address cannot be empty${NC}"
  exit 1
fi

echo ""
echo -e "  ${DIM}Recommended SNI: static.rutube.ru, cloudflare.com, www.google.com${NC}"
read -p "  SNI domain [static.rutube.ru]: " SNI_DOMAIN
SNI_DOMAIN=${SNI_DOMAIN:-static.rutube.ru}

echo ""

# ── Install ──────────────────────────────────

print_header
echo -e "  ${DIM}Server: ${SERVER_ADDR}  |  SNI: ${SNI_DOMAIN}${NC}"
echo ""

# ── Step 1: System dependencies ──
step_start "Installing system dependencies..."

if run_with_spinner "apt update & install deps" "apt update -qq && apt install -y curl wget unzip jq > /dev/null 2>&1"; then
  step_done "System dependencies installed"
else
  step_fail "Dependency install failed"
  tail -5 /tmp/chameleon_install.log 2>/dev/null | while IFS= read -r line; do info "$line"; done
  exit 1
fi

echo ""

# ── Step 2: Install Xray ──
step_start "Installing Xray..."

if run_with_spinner "xray install" 'bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install'; then
  XRAY_VER=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
  step_done "Xray installed ${DIM}(v${XRAY_VER})${NC}"
else
  step_fail "Xray installation failed"
  tail -5 /tmp/chameleon_install.log 2>/dev/null | while IFS= read -r line; do info "$line"; done
  exit 1
fi

echo ""

# ── Step 3: Generate Reality keys ──
step_start "Generating Reality keys..."

KEYS=$(/usr/local/bin/xray x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')

# Fallback for different xray output formats
if [ -z "$PRIVATE_KEY" ]; then
  PRIVATE_KEY=$(echo "$KEYS" | grep -i "privat" | awk '{print $NF}')
  PUBLIC_KEY=$(echo "$KEYS" | grep -i "publi" | awk '{print $NF}')
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

if [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$UUID" ]; then
  step_done "Reality keys generated"
  info "UUID: ${UUID:0:8}..."
else
  step_fail "Key generation failed"
  exit 1
fi

echo ""

# ── Step 4: Configure Xray ──
step_start "Writing Xray configuration..."

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 8443,
      "protocol": "vless",
      "tag": "vless-reality",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$SNI_DOMAIN:443",
          "serverNames": ["$SNI_DOMAIN"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
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

# ── Step 5: Configure firewall ──
step_start "Configuring firewall..."

if command -v ufw &> /dev/null; then
  ufw allow 8443/tcp > /dev/null 2>&1
  step_done "Firewall configured ${DIM}(ufw)${NC}"
else
  iptables -I INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  step_done "Firewall configured ${DIM}(iptables)${NC}"
fi

echo ""

# ── Step 6: Start Xray ──
step_start "Starting Xray service..."

systemctl enable xray > /dev/null 2>&1
systemctl restart xray > /dev/null 2>&1

sleep 2

if systemctl is-active --quiet xray; then
  step_done "Xray service running"
else
  step_fail "Xray failed to start"
  journalctl -u xray -n 5 --no-pager 2>/dev/null | while IFS= read -r line; do info "$line"; done
  exit 1
fi

echo ""

# ── Step 7: Save config & verify ──
step_start "Saving credentials..."

mkdir -p /root/vless-config

VLESS_LINK="vless://${UUID}@${SERVER_ADDR}:8443?type=tcp&security=reality&fp=random&pbk=${PUBLIC_KEY}&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Chameleon-Simple"

cat > /root/vless-config/keys.txt <<EOF
Server: $SERVER_ADDR
SNI: $SNI_DOMAIN
Port: 8443

UUID: $UUID
Private Key: $PRIVATE_KEY
Public Key: $PUBLIC_KEY
Short ID: $SHORT_ID
EOF

cat > /root/vless-config/links.txt <<EOF
VLESS Link:
$VLESS_LINK

Client Setup:
1. Copy the link above
2. Open v2rayNG (Android) or Streisand (iOS)
3. Tap + > "Import config from clipboard"
4. Paste the link and connect

Connection Parameters:
UUID:        $UUID
Public Key:  $PUBLIC_KEY
Short ID:    $SHORT_ID
SNI:         $SNI_DOMAIN
Type:        tcp
Security:    reality
Fingerprint: random
Flow:        xtls-rprx-vision
Port:        8443
EOF

# Verify port is listening
PORT_OK=0
if ss -tlnp 2>/dev/null | grep -q ':8443'; then
  PORT_OK=1
fi

step_done "Credentials saved to /root/vless-config/"

# ── Result ───────────────────────────────────

echo ""
if [ "$FAILED" = "0" ] && [ "$PORT_OK" = "1" ]; then
  echo -e "  ${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "  ${GREEN}${BOLD}║       Installation completed ${CHECK}           ║${NC}"
  echo -e "  ${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
elif [ "$FAILED" = "0" ]; then
  echo -e "  ${YELLOW}${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "  ${YELLOW}${BOLD}║   Installed — port 8443 not confirmed    ║${NC}"
  echo -e "  ${YELLOW}${BOLD}╚══════════════════════════════════════════╝${NC}"
else
  echo -e "  ${RED}${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "  ${RED}${BOLD}║      Installation failed ${CROSS}               ║${NC}"
  echo -e "  ${RED}${BOLD}╚══════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "  ${CYAN}${BOLD}VLESS Link:${NC}"
echo ""
echo -e "  ${YELLOW}${VLESS_LINK}${NC}"
echo ""
echo -e "  ${DIM}View link:       cat /root/vless-config/links.txt${NC}"
echo -e "  ${DIM}View keys:       cat /root/vless-config/keys.txt${NC}"
echo -e "  ${DIM}Xray status:     systemctl status xray${NC}"
echo -e "  ${DIM}Xray logs:       journalctl -u xray -f${NC}"
echo -e "  ${DIM}Check port:      ss -tlnp | grep 8443${NC}"
echo -e "  ${DIM}Restart:         systemctl restart xray${NC}"
echo -e "  ${DIM}Diagnostics:     bash diagnose.sh${NC}"
echo ""

# Cleanup
rm -f /tmp/chameleon_install.log
