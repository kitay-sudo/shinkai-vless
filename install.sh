#!/bin/bash

set -e

REPO="${VLESS_REPO:-kitay-sudo/Chameleon}"
BRANCH="${VLESS_BRANCH:-main}"
SERVER_ADDR="${1:-${VLESS_SERVER:-}}"
SNI_DOMAIN="${2:-${VLESS_SNI:-static.rutube.ru}}"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/install-vless-simple.sh"

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage:"
  echo "  curl -sSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh | sudo bash -s -- <server-address> [sni-domain]"
  echo ""
  echo "Environment:"
  echo "  VLESS_REPO=${REPO}"
  echo "  VLESS_BRANCH=${BRANCH}"
  echo "  VLESS_SERVER=<server-address>"
  echo "  VLESS_SNI=${SNI_DOMAIN}"
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: curl ... | sudo bash -s -- <server-address> [sni-domain]"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading VLESS installer from ${SCRIPT_URL}"
curl -fsSL "$SCRIPT_URL" -o "$TMP_DIR/install-vless-simple.sh"
chmod +x "$TMP_DIR/install-vless-simple.sh"

if [ -n "$SERVER_ADDR" ]; then
  bash "$TMP_DIR/install-vless-simple.sh" "$SERVER_ADDR" "$SNI_DOMAIN"
elif [ -r /dev/tty ]; then
  bash "$TMP_DIR/install-vless-simple.sh" </dev/tty
else
  echo "Server address is required in non-interactive mode."
  echo "Example:"
  echo "  curl -sSL ${SCRIPT_URL%install-vless-simple.sh}install.sh | sudo bash -s -- 1.2.3.4 static.rutube.ru"
  exit 1
fi
