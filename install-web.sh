#!/usr/bin/env bash

# Shinkai - VLESS over WebSocket + TLS behind a real web site
# Turns a node into "just a web server": nginx owns 443 and serves a working
# site, Xray listens on loopback and only gets requests that arrive on one
# secret path with a WebSocket upgrade. Everything else is the site.
#
# Usage:
#   sudo bash install-web.sh <domain> [letsencrypt-email]
#   sudo bash install-web.sh --rollback
#
# Env:
#   WEB_PATH        secret WS path (default: /api/v2/<random hex>)
#   XRAY_WS_PORT    loopback port for Xray (default: 10000)
#   SITE_SRC        directory with your own site to publish instead of the built-in one
#   TLS13_ONLY      1 = TLS 1.3 only (default: 1.2 + 1.3, like a normal site)
#   ENABLE_UFW      1 = allow 22/80/443 and enable ufw (off by default)
#   APT_LOCK_WAIT   seconds to wait for cloud-init/unattended-upgrades (default: 300)

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

TOTAL_STEPS=10
CURRENT_STEP=0
LOG_FILE="/tmp/shinkai-web-install.log"
FAILED=0

# Seconds to wait for cloud-init / unattended-upgrades to release the apt lock
APT_LOCK_WAIT="${APT_LOCK_WAIT:-300}"

DOMAIN="${1:-}"
LE_EMAIL="${2:-${LE_EMAIL:-}}"
XRAY_WS_PORT="${XRAY_WS_PORT:-10000}"
TLS13_ONLY="${TLS13_ONLY:-0}"
ENABLE_UFW="${ENABLE_UFW:-0}"
SITE_SRC="${SITE_SRC:-}"

CONFIG_DIR="/root/vless-config"
BACKUP_DIR="/root/vless-backup"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
ACME_ROOT="/var/www/certbot"
WEB_ROOT=""
NGINX_SITE=""
UUID=""
WEB_PATH="${WEB_PATH:-}"
VLESS_LINK=""
BACKUP_FILE=""
UPSTREAM_KEPT=0

cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

print_header() {
  clear 2>/dev/null || true
  echo ""
  echo -e "${CYAN}${BOLD}  ============================================${NC}"
  echo -e "${CYAN}${BOLD}    Shinkai - VLESS + WebSocket + TLS + site${NC}"
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
  fi

  printf '%s' "${value:-$default_value}"
}

usage() {
  cat <<USAGE
Shinkai - VLESS + WebSocket + TLS behind a real site

  sudo bash install-web.sh <domain> [letsencrypt-email]
  sudo bash install-web.sh --rollback

The domain must already resolve (A record) to this server's public IP,
and TCP 80 + 443 must be reachable from the internet.
USAGE
}

apt_lock_busy() {
  if command -v fuser >/dev/null 2>&1; then
    if fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  if pgrep -x apt >/dev/null 2>&1 \
    || pgrep -x apt-get >/dev/null 2>&1 \
    || pgrep -x dpkg >/dev/null 2>&1 \
    || pgrep -f unattended-upgr >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

wait_for_apt_lock() {
  local timeout="${1:-$APT_LOCK_WAIT}"
  local waited=0

  while apt_lock_busy; do
    if [ "$waited" -ge "$timeout" ]; then
      echo "apt/dpkg lock still held after ${waited}s"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done

  if [ "$waited" -gt 0 ]; then
    echo "apt/dpkg lock released after ${waited}s"
  fi
  return 0
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "Run as root: sudo bash install-web.sh <domain>"
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

  if [ -z "$DOMAIN" ]; then
    DOMAIN="$(read_from_tty "Domain that points to this server (A record)")"
  fi
  [ -z "$DOMAIN" ] && fail "Domain cannot be empty."

  DOMAIN="$(printf '%s' "$DOMAIN" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##')"
  if ! printf '%s' "$DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$'; then
    fail "This does not look like a domain: ${DOMAIN}"
  fi

  if [ -z "$LE_EMAIL" ]; then
    info "Let's Encrypt uses the email only for expiry warnings. Empty = register without email."
    LE_EMAIL="$(read_from_tty "Email for Let's Encrypt (optional)")"
  fi

  WEB_ROOT="/var/www/${DOMAIN}"
  NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}.conf"

  if [ -z "$WEB_PATH" ]; then
    WEB_PATH="/api/v2/$(openssl rand -hex 6)"
  fi
  case "$WEB_PATH" in
    /*) ;;
    *) WEB_PATH="/${WEB_PATH}" ;;
  esac
}

preflight() {
  step_start "Preflight checks..."

  local pub_ip dns_ip
  pub_ip="$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null || curl -s4 --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  dns_ip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"

  if [ -z "$dns_ip" ]; then
    step_fail "Preflight failed"
    info "${DOMAIN} does not resolve. Create an A record to ${pub_ip:-this server} and retry."
    exit 1
  fi

  if [ -n "$pub_ip" ] && [ "$dns_ip" != "$pub_ip" ]; then
    step_fail "Preflight failed"
    info "${DOMAIN} resolves to ${dns_ip}, this server is ${pub_ip}."
    info "Fix the A record (or set FORCE_DNS=1 to continue anyway) and retry."
    [ "${FORCE_DNS:-0}" != "1" ] && exit 1
  fi

  local busy80
  busy80="$(ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print $NF}' | head -n1 || true)"
  if [ -n "$busy80" ]; then
    step_fail "Preflight failed"
    info "TCP 80 is already used by: ${busy80}. Let's Encrypt needs it. Stop that service and retry."
    exit 1
  fi

  if [ -f "$XRAY_CONFIG" ] && grep -q '"tag": "to-upstream"' "$XRAY_CONFIG"; then
    UPSTREAM_KEPT=1
  fi

  step_done "Preflight passed (DNS ${dns_ip}, port 80 free)"
  [ -f /var/run/reboot-required ] && info "Note: this server has a pending reboot (kernel update)."
  echo ""
}

backup_current() {
  step_start "Backing up current configuration..."

  install -d -m 700 "$BACKUP_DIR"
  local ts paths=""
  ts="$(date +%F-%H%M%S)"
  BACKUP_FILE="${BACKUP_DIR}/pre-web-${ts}.tar.gz"

  local p
  for p in /usr/local/etc/xray "$CONFIG_DIR" /usr/local/bin/vless-mode /etc/nginx /etc/letsencrypt /var/www; do
    [ -e "$p" ] && paths="$paths $p"
  done

  if [ -n "$paths" ]; then
    tar czf "$BACKUP_FILE" $paths >/dev/null 2>&1 || true
  else
    tar czf "$BACKUP_FILE" --files-from /dev/null >/dev/null 2>&1
  fi

  {
    echo "timestamp=${ts}"
    echo "xray_active=$(systemctl is-active xray 2>/dev/null || echo unknown)"
    echo "nginx_present=$(command -v nginx >/dev/null 2>&1 && echo yes || echo no)"
    echo "domain=${DOMAIN}"
  } > "${BACKUP_DIR}/pre-web-${ts}.state"

  ln -sfn "$BACKUP_FILE" "${BACKUP_DIR}/latest.tar.gz"
  step_done "Backup saved to ${BACKUP_FILE}"
  echo ""
}

apt_install_packages() {
  wait_for_apt_lock || true

  local attempt=1
  while :; do
    if apt-get -o DPkg::Lock::Timeout=180 update -qq \
      && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 \
        install -y nginx certbot jq curl openssl ca-certificates cron python3 >/dev/null; then
      return 0
    fi
    if [ "$attempt" -ge 3 ]; then
      return 1
    fi
    echo "apt attempt ${attempt} failed, waiting for the lock and retrying..."
    attempt=$((attempt + 1))
    wait_for_apt_lock 120 || true
    sleep 5
  done
}

install_dependencies() {
  step_start "Installing nginx, certbot and tools..."

  if apt_lock_busy; then
    info "apt is busy (cloud-init / unattended-upgrades), waiting up to ${APT_LOCK_WAIT}s..."
  fi

  if ! run_with_spinner "apt update and install packages" apt_install_packages; then
    step_fail "Dependency installation failed"
    show_log_tail 10
    exit 1
  fi

  # Clean server: no Shinkai installer ran before, so Xray is not there yet.
  if [ ! -x /usr/local/bin/xray ]; then
    if ! run_with_spinner "installing Xray (official installer)"       bash -o pipefail -c "curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install"; then
      step_fail "Xray installation failed"
      show_log_tail 10
      exit 1
    fi
  fi

  local nver
  nver="$(nginx -v 2>&1 | sed -E 's#.*/##')"
  step_done "nginx ${nver}, certbot, Xray and tools ready"
  echo ""
}

write_rates_updater() {
  cat > /usr/local/bin/shinkai-rates-update <<'RATES'
#!/usr/bin/env python3
"""Fetch the official Bank of Russia daily rates and store them as JSON.

Keeps the previous file untouched if the fetch fails, so the site never breaks.
"""
import json
import os
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

URL = "https://www.cbr.ru/scripts/XML_daily.asp"
OUT = sys.argv[1] if len(sys.argv) > 1 else "/var/www/html/api/rates.json"


def fetch():
    req = urllib.request.Request(URL, headers={"User-Agent": "rates-updater/1.0"})
    with urllib.request.urlopen(req, timeout=25) as resp:
        return resp.read()


def parse(raw):
    root = ET.fromstring(raw.decode("windows-1251", "replace"))
    rates = []
    for valute in root.findall("Valute"):
        try:
            value = float((valute.findtext("Value") or "0").replace(",", "."))
            nominal = int(valute.findtext("Nominal") or "1")
        except ValueError:
            continue
        if value <= 0 or nominal <= 0:
            continue
        rates.append(
            {
                "code": (valute.findtext("CharCode") or "").strip(),
                "name": (valute.findtext("Name") or "").strip(),
                "nominal": nominal,
                "value": round(value, 4),
                "per_unit": round(value / nominal, 6),
            }
        )
    rates.sort(key=lambda item: item["code"])
    return {
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cbr_date": root.get("Date", ""),
        "base": "RUB",
        "source": "cbr.ru",
        "rates": rates,
    }


def write(data, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".rates-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except Exception:
        os.unlink(tmp)
        raise


def main():
    try:
        data = parse(fetch())
    except Exception as exc:  # network problem or upstream format change
        print("rates update failed: %s" % exc, file=sys.stderr)
        return 1
    if not data["rates"]:
        print("rates update failed: empty payload", file=sys.stderr)
        return 1
    write(data, OUT)
    print("wrote %d rates to %s" % (len(data["rates"]), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
RATES
  chmod 755 /usr/local/bin/shinkai-rates-update

  cat > /etc/cron.d/shinkai-rates <<CRON
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
17 */6 * * * root /usr/local/bin/shinkai-rates-update ${WEB_ROOT}/api/rates.json >/dev/null 2>&1
@reboot root sleep 90 && /usr/local/bin/shinkai-rates-update ${WEB_ROOT}/api/rates.json >/dev/null 2>&1
CRON
  chmod 644 /etc/cron.d/shinkai-rates
}

write_site_html() {
  install -d -m 755 "$WEB_ROOT" "${WEB_ROOT}/assets" "${WEB_ROOT}/api" "$ACME_ROOT"

  cat > "${WEB_ROOT}/index.html" <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Курс ЦБ РФ — конвертер валют по официальному курсу</title>
<meta name="description" content="Официальные курсы валют Банка России и конвертер. Данные обновляются автоматически из открытого XML-фида ЦБ РФ.">
<link rel="canonical" href="https://${DOMAIN}/">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="top">
  <div class="wrap">
    <a class="brand" href="/"><span class="mark">Р</span><span>Курс ЦБ РФ</span></a>
    <nav>
      <a href="/">Конвертер</a>
      <a href="/about.html">О проекте</a>
      <a href="/api/rates.json">API</a>
    </nav>
  </div>
</header>

<main class="wrap">
  <h1>Конвертер по официальному курсу Банка России</h1>
  <p class="lead">Курсы берутся из открытого XML-фида ЦБ РФ и обновляются каждые шесть часов. Пересчёт считается в браузере, на сервер ничего не отправляется.</p>

  <section class="card" id="converter">
    <div class="row">
      <label>Сумма
        <input id="amount" type="number" inputmode="decimal" value="100" min="0" step="any">
      </label>
      <label>Из
        <select id="from"></select>
      </label>
      <button id="swap" type="button" title="Поменять валюты">&#8646;</button>
      <label>В
        <select id="to"></select>
      </label>
    </div>
    <output id="result" class="result">&mdash;</output>
    <p class="hint" id="pair-hint"></p>
  </section>

  <section class="card">
    <div class="table-head">
      <h2>Все курсы</h2>
      <input id="filter" type="search" placeholder="Поиск: USD, юань, франк" aria-label="Поиск по валютам">
    </div>
    <div class="table-scroll">
      <table id="rates">
        <thead>
          <tr><th>Код</th><th>Валюта</th><th class="num">Единиц</th><th class="num">Курс, руб.</th><th class="num">За 1 ед.</th></tr>
        </thead>
        <tbody></tbody>
      </table>
    </div>
    <p class="hint" id="updated">Загрузка данных...</p>
  </section>
</main>

<footer class="wrap foot">
  <p>Источник данных: <a href="https://www.cbr.ru/development/SXML/" rel="nofollow noopener" target="_blank">открытый XML-фид Банка России</a>. Проект личный и справочный, без гарантий и без сбора статистики.</p>
</footer>

<script src="/assets/app.js" defer></script>
</body>
</html>
HTML

  cat > "${WEB_ROOT}/about.html" <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>О проекте — Курс ЦБ РФ</title>
<meta name="description" content="Как работает конвертер: источник данных, периодичность обновления, приватность.">
<link rel="canonical" href="https://${DOMAIN}/about.html">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="top">
  <div class="wrap">
    <a class="brand" href="/"><span class="mark">Р</span><span>Курс ЦБ РФ</span></a>
    <nav>
      <a href="/">Конвертер</a>
      <a href="/about.html">О проекте</a>
      <a href="/api/rates.json">API</a>
    </nav>
  </div>
</header>

<main class="wrap prose">
  <h1>О проекте</h1>
  <p>Небольшой личный инструмент: официальные курсы валют Банка России в удобном виде плюс конвертер, который считает прямо в браузере.</p>

  <h2>Откуда данные</h2>
  <p>Единственный источник — открытый фид ЦБ РФ <code>XML_daily.asp</code>. Скрипт на сервере забирает его каждые шесть часов и раскладывает в статический JSON. Если фид недоступен, остаётся предыдущая копия, поэтому страница не ломается.</p>

  <h2>API</h2>
  <p>Тот же JSON лежит по адресу <code>/api/rates.json</code>: поля <code>updated</code>, <code>cbr_date</code>, <code>base</code> и массив <code>rates</code> с кодом валюты, номиналом, курсом и курсом за единицу.</p>

  <h2>Приватность</h2>
  <p>Ни счётчиков, ни cookies, ни сторонних скриптов и шрифтов. Все файлы отдаются с этого же домена.</p>

  <h2>Точность</h2>
  <p>Курс ЦБ справочный, он не равен курсу обмена в банке или на бирже. Для сделок сверяйтесь с первоисточником.</p>
</main>

<footer class="wrap foot">
  <p><a href="/">К конвертеру</a></p>
</footer>
</body>
</html>
HTML

  cat > "${WEB_ROOT}/robots.txt" <<ROBOTS
User-agent: *
Allow: /
Sitemap: https://${DOMAIN}/sitemap.xml
ROBOTS

  cat > "${WEB_ROOT}/sitemap.xml" <<SITEMAP
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${DOMAIN}/</loc><changefreq>daily</changefreq><priority>1.0</priority></url>
  <url><loc>https://${DOMAIN}/about.html</loc><changefreq>monthly</changefreq><priority>0.5</priority></url>
</urlset>
SITEMAP

  printf '{"updated":null,"cbr_date":"","base":"RUB","source":"cbr.ru","rates":[]}\n' > "${WEB_ROOT}/api/rates.json"
}

write_site_assets() {
  cat > "${WEB_ROOT}/assets/style.css" <<'CSS'
:root {
  color-scheme: light dark;
  --bg: #f7f7f5;
  --card: #ffffff;
  --ink: #16181d;
  --muted: #6b7280;
  --line: #e4e4e1;
  --accent: #1f6feb;
  --accent-soft: #eaf1fe;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14161a;
    --card: #1b1e24;
    --ink: #e8e9ec;
    --muted: #9aa1ac;
    --line: #2a2f37;
    --accent: #6ea8ff;
    --accent-soft: #1e2836;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
}
.wrap { width: min(920px, 100% - 2.5rem); margin-inline: auto; }
.top { border-bottom: 1px solid var(--line); background: var(--card); }
.top .wrap { display: flex; align-items: center; justify-content: space-between; gap: 1rem; min-height: 60px; }
.brand { display: inline-flex; align-items: center; gap: .55rem; font-weight: 650; color: inherit; text-decoration: none; }
.mark { display: grid; place-items: center; width: 28px; height: 28px; border-radius: 8px; background: var(--accent); color: #fff; font-weight: 700; }
nav { display: flex; gap: 1.1rem; }
nav a { color: var(--muted); text-decoration: none; font-size: .94rem; }
nav a:hover { color: var(--accent); }
h1 { font-size: 1.6rem; margin: 2rem 0 .5rem; }
h2 { font-size: 1.1rem; margin: 0; }
.lead { color: var(--muted); margin: 0 0 1.5rem; max-width: 62ch; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 1.15rem 1.25rem 1.35rem; margin-bottom: 1.25rem; }
.row { display: flex; flex-wrap: wrap; align-items: end; gap: .75rem; }
label { display: grid; gap: .3rem; font-size: .82rem; color: var(--muted); flex: 1 1 8rem; }
input, select, button { font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 9px; padding: .55rem .65rem; min-width: 0; }
input:focus, select:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
#swap { align-self: end; cursor: pointer; padding: .55rem .8rem; background: var(--accent-soft); border-color: transparent; }
#swap:hover { background: var(--accent); color: #fff; }
.result { display: block; margin-top: 1.1rem; font-size: 1.75rem; font-weight: 650; letter-spacing: -.01em; }
.hint { color: var(--muted); font-size: .85rem; margin: .4rem 0 0; }
.table-head { display: flex; align-items: center; justify-content: space-between; gap: 1rem; margin-bottom: .9rem; }
.table-head input { flex: 0 1 15rem; }
.table-scroll { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: .5rem .6rem; border-bottom: 1px solid var(--line); white-space: nowrap; }
th { font-size: .78rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); font-weight: 600; }
td.num, th.num { text-align: right; }
tbody tr:hover { background: var(--accent-soft); }
.prose { max-width: 68ch; padding-bottom: 1rem; }
.prose h2 { margin: 1.8rem 0 .4rem; font-size: 1.05rem; }
.prose code { background: var(--accent-soft); padding: .1rem .35rem; border-radius: 5px; font-size: .9em; }
.foot { color: var(--muted); font-size: .85rem; padding: 1.5rem 0 2.5rem; }
a { color: var(--accent); }
CSS

  cat > "${WEB_ROOT}/assets/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="14" fill="#1f6feb"/>
  <text x="32" y="45" font-family="Arial, Helvetica, sans-serif" font-size="36" font-weight="700" fill="#fff" text-anchor="middle">&#8381;</text>
</svg>
SVG
}

write_site_js() {
  cat > "${WEB_ROOT}/assets/app.js" <<'JS'
(function () {
  "use strict";

  var RUB = { code: "RUB", name: "Российский рубль", nominal: 1, value: 1, per_unit: 1 };
  var state = { rates: [], byCode: { RUB: RUB } };

  var amount = document.getElementById("amount");
  var from = document.getElementById("from");
  var to = document.getElementById("to");
  var swap = document.getElementById("swap");
  var result = document.getElementById("result");
  var pairHint = document.getElementById("pair-hint");
  var filter = document.getElementById("filter");
  var tbody = document.querySelector("#rates tbody");
  var updated = document.getElementById("updated");

  var money = new Intl.NumberFormat("ru-RU", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  var precise = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 4 });

  function fillSelects() {
    var list = [RUB].concat(state.rates);
    [from, to].forEach(function (select) {
      select.innerHTML = "";
      list.forEach(function (item) {
        var option = document.createElement("option");
        option.value = item.code;
        option.textContent = item.code + " - " + item.name;
        select.appendChild(option);
      });
    });
    from.value = state.byCode.USD ? "USD" : (list[1] ? list[1].code : "RUB");
    to.value = "RUB";
  }

  function convert() {
    var value = parseFloat(String(amount.value).replace(",", "."));
    if (!isFinite(value) || value < 0) {
      result.textContent = "-";
      pairHint.textContent = "";
      return;
    }
    var src = state.byCode[from.value] || RUB;
    var dst = state.byCode[to.value] || RUB;
    var out = (value * src.per_unit) / dst.per_unit;
    result.textContent = money.format(out) + " " + dst.code;
    pairHint.textContent = "1 " + src.code + " = " + precise.format(src.per_unit / dst.per_unit) + " " + dst.code;
  }

  function renderTable() {
    var needle = (filter.value || "").trim().toLowerCase();
    tbody.innerHTML = "";
    state.rates.filter(function (item) {
      if (!needle) return true;
      return item.code.toLowerCase().indexOf(needle) === 0 || item.name.toLowerCase().indexOf(needle) !== -1;
    }).forEach(function (item) {
      var tr = document.createElement("tr");
      var cells = [item.code, item.name, item.nominal, precise.format(item.value), precise.format(item.per_unit)];
      cells.forEach(function (cell, index) {
        var td = document.createElement("td");
        if (index >= 2) td.className = "num";
        td.textContent = cell;
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
  }

  function plural(count) {
    var forms = ["валюта", "валюты", "валют"];
    var mod10 = count % 10;
    var mod100 = count % 100;
    var index = 2;
    if (mod10 === 1 && mod100 !== 11) {
      index = 0;
    } else if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) {
      index = 1;
    }
    return count + " " + forms[index];
  }

  function stamp(data) {
    var parts = [];
    if (data.cbr_date) parts.push("курс ЦБ на " + data.cbr_date);
    if (data.updated) {
      var when = new Date(data.updated);
      if (!isNaN(when.getTime())) parts.push("загружено " + when.toLocaleString("ru-RU"));
    }
    parts.push(plural(state.rates.length));
    updated.textContent = parts.join(" \u00b7 ");
  }

  fetch("/api/rates.json", { cache: "no-cache" }).then(function (response) {
    if (!response.ok) throw new Error("http " + response.status);
    return response.json();
  }).then(function (data) {
    state.rates = Array.isArray(data.rates) ? data.rates : [];
    state.byCode = { RUB: RUB };
    state.rates.forEach(function (item) { state.byCode[item.code] = item; });
    if (!state.rates.length) {
      updated.textContent = "Данные обновляются, обновите страницу через несколько минут.";
      return;
    }
    fillSelects();
    renderTable();
    convert();
    stamp(data);
  }).catch(function () {
    updated.textContent = "Данные обновляются, обновите страницу через несколько минут.";
  });

  [amount, from, to].forEach(function (el) {
    el.addEventListener("input", convert);
    el.addEventListener("change", convert);
  });
  swap.addEventListener("click", function () {
    var keep = from.value;
    from.value = to.value;
    to.value = keep;
    convert();
  });
  filter.addEventListener("input", renderTable);
})();
JS
}

deploy_site() {
  step_start "Publishing the site..."

  if [ -n "$SITE_SRC" ]; then
    [ -d "$SITE_SRC" ] || fail "SITE_SRC=${SITE_SRC} is not a directory."
    install -d -m 755 "$WEB_ROOT" "$ACME_ROOT"
    cp -a "${SITE_SRC%/}/." "$WEB_ROOT/"
    chown -R www-data:www-data "$WEB_ROOT"
    step_done "Site published from ${SITE_SRC}"
    echo ""
    return 0
  fi

  write_site_html
  write_site_assets
  write_site_js
  write_rates_updater

  local rates_ok=0
  if run_with_spinner "fetching live rates from cbr.ru" \
    /usr/local/bin/shinkai-rates-update "${WEB_ROOT}/api/rates.json"; then
    rates_ok=1
  fi

  chown -R www-data:www-data "$WEB_ROOT" "$ACME_ROOT"

  if [ "$rates_ok" = "1" ]; then
    step_done "Site published with live CBR rates ($(jq -r '.rates | length' "${WEB_ROOT}/api/rates.json") currencies)"
  else
    step_done "Site published (rates fetch failed, cron will retry every 6h)"
    show_log_tail 4
  fi
  echo ""
}

nginx_http2_directive() {
  # nginx >= 1.25.1 wants "http2 on;", older builds take it on the listen line.
  local ver major minor patch
  ver="$(nginx -v 2>&1 | sed -E 's#.*/([0-9.]+).*#\1#')"
  major="${ver%%.*}"; minor="$(printf '%s' "$ver" | cut -d. -f2)"; patch="$(printf '%s' "$ver" | cut -d. -f3)"
  major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -gt 25 ]; } \
    || { [ "$major" -eq 1 ] && [ "$minor" -eq 25 ] && [ "$patch" -ge 1 ]; }; then
    echo "directive"
  else
    echo "listen"
  fi
}

configure_nginx_http() {
  step_start "Serving the site over HTTP (for the ACME challenge)..."

  rm -f /etc/nginx/sites-enabled/default

  cat > "$NGINX_SITE" <<CONF
# Managed by shinkai install-web.sh - removed by uninstall.sh
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${DOMAIN};

    root ${WEB_ROOT};
    index index.html;
    charset utf-8;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type "text/plain";
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
CONF

  ln -sfn "$NGINX_SITE" "/etc/nginx/sites-enabled/${DOMAIN}.conf"

  if ! nginx -t >"$LOG_FILE" 2>&1; then
    step_fail "nginx configuration is invalid"
    show_log_tail 10
    exit 1
  fi

  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/" || true)"
  if [ "$code" = "200" ]; then
    step_done "Site is live on port 80 (local check ${code})"
  else
    step_fail "Site did not answer on port 80 (got ${code:-no response})"
    show_log_tail 6
    exit 1
  fi
  echo ""
}

issue_certificate() {
  step_start "Issuing the Let's Encrypt certificate..."

  if [ -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    step_done "Certificate already present for ${DOMAIN}, reusing it"
    echo ""
    return 0
  fi

  local email_args
  if [ -n "$LE_EMAIL" ]; then
    email_args="--email ${LE_EMAIL}"
  else
    email_args="--register-unsafely-without-email"
  fi

  # --agree-tos accepts the Let's Encrypt Subscriber Agreement on your behalf.
  if run_with_spinner "certbot certonly --webroot" \
    bash -c "certbot certonly --webroot -w '${ACME_ROOT}' -d '${DOMAIN}' \
      --key-type ecdsa --agree-tos -n ${email_args} \
      --deploy-hook 'systemctl reload nginx'"; then
    step_done "Certificate issued for ${DOMAIN}"
  else
    step_fail "Certificate issuing failed"
    show_log_tail 14
    info "Most common causes: TCP 80 closed in the cloud firewall, or the A record points elsewhere."
    info "Nothing is broken yet - the old Xray setup still works. Fix the cause and re-run."
    exit 1
  fi
  echo ""
}

xray_test_config() {
  local file="$1"
  if /usr/local/bin/xray test -c "$file" >/dev/null 2>&1; then
    return 0
  fi
  if /usr/local/bin/xray run -test -c "$file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

write_xray_ws_config() {
  step_start "Moving Xray to WebSocket on 127.0.0.1:${XRAY_WS_PORT}..."

  UUID="$(cat /proc/sys/kernel/random/uuid)"

  local inbound tmp
  inbound="$(cat <<JSON
{
  "listen": "127.0.0.1",
  "port": ${XRAY_WS_PORT},
  "protocol": "vless",
  "tag": "vless-in",
  "settings": {
    "clients": [
      {
        "id": "${UUID}",
        "level": 0
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": {
      "path": "${WEB_PATH}"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
JSON
)"

  tmp="$(mktemp --suffix=.json)"
  if [ "$UPSTREAM_KEPT" = "1" ]; then
    # Keep the existing outbounds (upstream chain) and routing untouched.
    jq --argjson inb "$inbound" '.inbounds = [$inb]' "$XRAY_CONFIG" > "$tmp"
  else
    mkdir -p "$(dirname "$XRAY_CONFIG")"
    jq -n --argjson inb "$inbound" '{
      log: { loglevel: "warning" },
      inbounds: [$inb],
      outbounds: [
        { protocol: "freedom", tag: "direct" },
        { protocol: "blackhole", tag: "block" }
      ],
      routing: { rules: [ { type: "field", inboundTag: ["vless-in"], outboundTag: "direct" } ] }
    }' > "$tmp"
  fi

  if ! xray_test_config "$tmp"; then
    step_fail "Generated Xray config did not pass validation"
    /usr/local/bin/xray test -c "$tmp" 2>&1 | tail -n 8 | while IFS= read -r line; do info "$line"; done
    rm -f "$tmp"
    exit 1
  fi

  install -m 644 "$tmp" "$XRAY_CONFIG"
  rm -f "$tmp"

  systemctl restart xray
  sleep 1

  if ! systemctl is-active --quiet xray; then
    step_fail "Xray failed to start with the new config"
    journalctl -u xray -n 12 --no-pager | while IFS= read -r line; do info "$line"; done
    exit 1
  fi

  if ss -tln 2>/dev/null | grep -q "127.0.0.1:${XRAY_WS_PORT}"; then
    step_done "Xray listens on 127.0.0.1:${XRAY_WS_PORT} (WebSocket ${WEB_PATH})"
  else
    step_fail "Xray started but is not listening on 127.0.0.1:${XRAY_WS_PORT}"
    exit 1
  fi
  echo ""
}

configure_nginx_tls() {
  step_start "Handing 443 to nginx (TLS + secret path)..."

  local ssl_protocols="TLSv1.2 TLSv1.3"
  [ "$TLS13_ONLY" = "1" ] && ssl_protocols="TLSv1.3"

  local listen4 listen6 h2_line
  if [ "$(nginx_http2_directive)" = "directive" ]; then
    listen4="listen 443 ssl default_server;"
    listen6="listen [::]:443 ssl default_server;"
    h2_line="    http2 on;"
  else
    listen4="listen 443 ssl http2 default_server;"
    listen6="listen [::]:443 ssl http2 default_server;"
    h2_line="    # HTTP/2 is enabled on the listen directives above"
  fi

  cat > /etc/nginx/conf.d/shinkai-ws.conf <<'MAPS'
# Upgrade plumbing for the one proxied location. Anything that is not a
# WebSocket upgrade never reaches the backend.
map $http_upgrade $shinkai_connection {
    default upgrade;
    ''      close;
}

map $http_upgrade $shinkai_is_ws {
    default          0;
    "~*^websocket$"  1;
}
MAPS

  cat > "$NGINX_SITE" <<CONF
# Managed by shinkai install-web.sh - removed by uninstall.sh
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    ${listen4}
    ${listen6}
${h2_line}
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       ${ssl_protocols};
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    root ${WEB_ROOT};
    index index.html;
    charset utf-8;
    server_tokens off;

    gzip on;
    gzip_min_length 512;
    gzip_types text/css text/plain application/javascript application/json image/svg+xml application/xml;

    # The proxy lives on exactly one path, and only for WebSocket upgrades.
    # A plain request to the same path is rewritten to the site, so a prober
    # sees the same page as any other visitor.
    location = ${WEB_PATH} {
        if (\$shinkai_is_ws = 0) {
            rewrite ^ / last;
        }

        proxy_pass http://127.0.0.1:${XRAY_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$shinkai_connection;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        access_log off;
    }

    location = /api/rates.json {
        add_header Cache-Control "public, max-age=900";
    }

    location /assets/ {
        add_header Cache-Control "public, max-age=86400";
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
CONF

  if ! nginx -t >"$LOG_FILE" 2>&1; then
    step_fail "nginx TLS configuration is invalid"
    show_log_tail 12
    exit 1
  fi

  systemctl restart nginx
  sleep 1

  if systemctl is-active --quiet nginx && ss -tln 2>/dev/null | grep -qE '(^|[^0-9])(\*|0\.0\.0\.0|\[::\]):443'; then
    step_done "nginx owns 443 (TLS ${ssl_protocols// /, }, HTTP/2 on)"
  else
    step_fail "nginx is not listening on 443"
    journalctl -u nginx -n 12 --no-pager | while IFS= read -r line; do info "$line"; done
    exit 1
  fi
  echo ""
}

configure_firewall() {
  step_start "Firewall..."

  if [ "$ENABLE_UFW" = "1" ] && command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    step_done "ufw enabled with 22, 80, 443 open"
  else
    step_done "Host firewall left as is ($(ufw status 2>/dev/null | head -n1 || echo 'ufw not installed'))"
    info "Cloud firewall still rules: open TCP 80 and 443 for this VM in your provider's console."
    info "To turn on the host firewall too: ENABLE_UFW=1 sudo bash install-web.sh ${DOMAIN}"
  fi
  echo ""
}

install_rollback_tool() {
  cat > /usr/local/bin/vless-web-rollback <<'ROLLBACK'
#!/usr/bin/env bash
# vless-web-rollback - undo install-web.sh and return to the pre-web setup
set -uo pipefail

BACKUP_DIR="/root/vless-backup"
ARCHIVE="${1:-${BACKUP_DIR}/latest.tar.gz}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Run as root: sudo vless-web-rollback [backup.tar.gz]" >&2
  exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
  echo "Backup not found: ${ARCHIVE}" >&2
  echo "Available:" >&2
  ls -1 "${BACKUP_DIR}"/pre-web-*.tar.gz 2>/dev/null >&2 || echo "  none" >&2
  exit 1
fi

echo "Rolling back from ${ARCHIVE}"

systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

rm -f /etc/nginx/conf.d/shinkai-ws.conf /etc/cron.d/shinkai-rates
rm -f /etc/nginx/sites-enabled/*.conf

tar xzf "$ARCHIVE" -C / 2>/dev/null || true

systemctl restart xray 2>/dev/null || true
sleep 1

echo ""
echo "xray:  $(systemctl is-active xray 2>/dev/null)"
echo "nginx: $(systemctl is-active nginx 2>/dev/null)"
ss -tlnp 2>/dev/null | grep -E ':(443|80|10000)\s' || true
echo ""
echo "Old client link (if the previous setup had one):"
grep -m1 '^vless://' /root/vless-config/relay-links.txt /root/vless-config/links.txt 2>/dev/null || echo "  check /root/vless-config/"
echo ""
echo "Site files under /var/www are left in place; nginx is stopped, so nothing serves them."
ROLLBACK
  chmod 755 /usr/local/bin/vless-web-rollback
}

save_result() {
  step_start "Saving credentials and client config..."

  install -d -m 700 "$CONFIG_DIR"

  local path_enc
  path_enc="$(printf '%s' "$WEB_PATH" | sed 's#/#%2F#g')"
  VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&alpn=http%2F1.1&fp=chrome&type=ws&host=${DOMAIN}&path=${path_enc}#Shinkai-WEB"

  cat > "${CONFIG_DIR}/web-keys.txt" <<KEYS
=== Entry hop (client -> this node) ===
Domain: ${DOMAIN}
Port: 443/tcp (nginx)
Transport: VLESS + WebSocket + TLS
Secret path: ${WEB_PATH}
UUID: ${UUID}
uTLS fingerprint: chrome
ALPN: http/1.1
Xray backend: 127.0.0.1:${XRAY_WS_PORT} (loopback only)

=== Files ===
nginx site: ${NGINX_SITE}
nginx maps: /etc/nginx/conf.d/shinkai-ws.conf
Xray config: ${XRAY_CONFIG}
Site root: ${WEB_ROOT}
Certificate: /etc/letsencrypt/live/${DOMAIN}/
Backup: ${BACKUP_FILE}
Rollback: sudo vless-web-rollback
KEYS

  cat > "${CONFIG_DIR}/web-links.txt" <<LINKS
VLESS Link (WebSocket + TLS, looks like plain HTTPS to the site):
${VLESS_LINK}

Connection Parameters:
Address:     ${DOMAIN}
Port:        443
UUID:        ${UUID}
Encryption:  none
Security:    tls
SNI:         ${DOMAIN}
ALPN:        http/1.1
Fingerprint: chrome (uTLS)
Network:     ws
Host header: ${DOMAIN}
Path:        ${WEB_PATH}
LINKS

  cat > "${CONFIG_DIR}/web-client.json" <<CLIENT
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10809,
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "proxy",
      "settings": {
        "vnext": [
          {
            "address": "${DOMAIN}",
            "port": 443,
            "users": [
              {
                "id": "${UUID}",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "alpn": ["http/1.1"],
          "fingerprint": "chrome"
        },
        "wsSettings": {
          "path": "${WEB_PATH}",
          "headers": {
            "Host": "${DOMAIN}"
          }
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
CLIENT

  chmod 600 "${CONFIG_DIR}/web-keys.txt" "${CONFIG_DIR}/web-links.txt" "${CONFIG_DIR}/web-client.json"
  install_rollback_tool

  step_done "Saved to ${CONFIG_DIR}/web-links.txt, web-keys.txt, web-client.json"
  echo ""
}

self_check() {
  echo -e "  ${CYAN}${BOLD}Checks${NC}"

  local site_code path_code ws_code proto h2
  site_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "https://${DOMAIN}/" 2>/dev/null || echo "err")"
  path_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "https://${DOMAIN}${WEB_PATH}" 2>/dev/null || echo "err")"
  ws_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 \
    -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
    "https://${DOMAIN}${WEB_PATH}" 2>/dev/null || echo "err")"
  proto="$(echo | openssl s_client -connect "${DOMAIN}:443" -servername "${DOMAIN}" 2>/dev/null \
    | awk -F': ' '/^ *Protocol *:/ {print $2; exit}')"
  h2="$(curl -sSI --http2 --max-time 12 "https://${DOMAIN}/" 2>/dev/null | awk 'NR==1{print $1}')"

  if [ "$site_code" = "200" ]; then
    info "site over TLS: ${site_code} OK"
  else
    warn "site over TLS answered ${site_code} - check nginx and DNS"
  fi

  if [ "$path_code" = "200" ]; then
    info "plain GET on the secret path: ${path_code} (site page, no proxy error) OK"
  else
    warn "plain GET on the secret path answered ${path_code}, expected 200 from the site"
  fi

  if [ "$ws_code" = "101" ]; then
    info "WebSocket upgrade on the secret path: 101 (reaches Xray) OK"
  else
    warn "WebSocket upgrade answered ${ws_code}, expected 101 - check the Xray backend"
  fi

  info "negotiated TLS: ${proto:-unknown}"
  info "HTTP version for the site: ${h2:-unknown}"
  echo ""
}

print_result() {
  echo -e "  ${GREEN}${BOLD}============================================${NC}"
  echo -e "  ${GREEN}${BOLD}  Web-camouflaged VLESS is up${NC}"
  echo -e "  ${GREEN}${BOLD}============================================${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}Client link:${NC}"
  echo ""
  echo -e "  ${YELLOW}${VLESS_LINK}${NC}"
  echo ""

  if [ "$UPSTREAM_KEPT" = "1" ]; then
    echo -e "  ${DIM}Chain: client -> https://${DOMAIN} (nginx + site) -> Xray -> upstream -> internet${NC}"
    echo -e "  ${DIM}Exit mode still switchable: sudo vless-mode chain | direct | status${NC}"
  else
    echo -e "  ${DIM}Chain: client -> https://${DOMAIN} (nginx + site) -> Xray -> internet${NC}"
  fi
  echo ""
  echo -e "  ${CYAN}${BOLD}Verify by hand:${NC}"
  echo -e "  ${DIM}Open in a browser:  https://${DOMAIN}/${NC}"
  echo -e "  ${DIM}Secret path plain:  curl -i https://${DOMAIN}${WEB_PATH} | head -20${NC}"
  echo -e "  ${DIM}TLS + HTTP/2:       curl -sI --http2 https://${DOMAIN}/ | head -3${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}Files and tools:${NC}"
  echo -e "  ${DIM}Link:      cat ${CONFIG_DIR}/web-links.txt${NC}"
  echo -e "  ${DIM}Client:    cat ${CONFIG_DIR}/web-client.json${NC}"
  echo -e "  ${DIM}Rates job: /usr/local/bin/shinkai-rates-update ${WEB_ROOT}/api/rates.json${NC}"
  echo -e "  ${DIM}Logs:      journalctl -u xray -f  |  tail -f /var/log/nginx/error.log${NC}"
  echo -e "  ${DIM}Rollback:  sudo vless-web-rollback${NC}"
  echo ""
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    --rollback)
      require_root
      install_rollback_tool
      exec /usr/local/bin/vless-web-rollback
      ;;
  esac

  require_root
  require_linux
  collect_input

  print_header
  info "Domain: ${DOMAIN}"
  info "Secret WebSocket path: ${WEB_PATH}"
  info "Xray backend: 127.0.0.1:${XRAY_WS_PORT}"
  info "Site: ${SITE_SRC:-built-in CBR rates site} -> ${WEB_ROOT}"
  echo ""

  preflight
  backup_current
  install_dependencies
  deploy_site
  configure_nginx_http
  issue_certificate
  write_xray_ws_config
  configure_nginx_tls
  configure_firewall
  save_result
  self_check
  print_result
}

main "$@"
