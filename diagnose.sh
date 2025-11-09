#!/bin/bash

# 🔍 Chameleon VPN Diagnostic Script
# Собирает логи и диагностическую информацию для отладки

echo "=========================================="
echo "🔍 Chameleon VPN Diagnostic Tool"
echo "=========================================="
echo ""

# Создаем директорию для логов
DIAG_DIR="/root/chameleon-diag-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIAG_DIR"

echo "📁 Сохраняем диагностику в: $DIAG_DIR"
echo ""

# 1. Информация о системе
echo "1️⃣ Собираем информацию о системе..."
{
    echo "=== System Info ==="
    uname -a
    echo ""
    echo "=== Date/Time ==="
    date
    echo ""
    echo "=== Uptime ==="
    uptime
} > "$DIAG_DIR/system-info.txt"

# 2. Статус сервиса Xray
echo "2️⃣ Проверяем статус Xray..."
{
    echo "=== Xray Service Status ==="
    systemctl status xray --no-pager
    echo ""
    echo "=== Xray is-active ==="
    systemctl is-active xray
    echo ""
    echo "=== Xray is-enabled ==="
    systemctl is-enabled xray
} > "$DIAG_DIR/xray-status.txt"

# 3. Логи Xray (последние 200 строк)
echo "3️⃣ Собираем логи Xray..."
{
    echo "=== Last 200 lines of Xray logs ==="
    journalctl -u xray -n 200 --no-pager
    echo ""
    echo "=== Xray errors only ==="
    journalctl -u xray -p err --no-pager -n 100
} > "$DIAG_DIR/xray-logs.txt"

# 4. Конфигурация Xray
echo "4️⃣ Копируем конфигурацию Xray..."
if [ -f /usr/local/etc/xray/config.json ]; then
    cp /usr/local/etc/xray/config.json "$DIAG_DIR/xray-config.json"

    # Проверяем валидность JSON
    {
        echo "=== Config Validation ==="
        if command -v jq &> /dev/null; then
            jq . /usr/local/etc/xray/config.json > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo "✅ Config is valid JSON"
            else
                echo "❌ Config is INVALID JSON"
                jq . /usr/local/etc/xray/config.json 2>&1
            fi
        else
            echo "⚠️ jq not installed, cannot validate JSON"
        fi
    } > "$DIAG_DIR/config-validation.txt"
else
    echo "❌ Config not found at /usr/local/etc/xray/config.json" > "$DIAG_DIR/xray-config-ERROR.txt"
fi

# 5. Проверка портов
echo "5️⃣ Проверяем открытые порты..."
{
    echo "=== Listening Ports ==="
    ss -tlnp | grep -E ":(443|8443|2053)"
    echo ""
    echo "=== All listening ports ==="
    ss -tlnp
    echo ""
    echo "=== Netstat (if available) ==="
    if command -v netstat &> /dev/null; then
        netstat -tlnp | grep -E ":(443|8443|2053)"
    else
        echo "netstat not available"
    fi
} > "$DIAG_DIR/ports.txt"

# 6. DNS проверка
echo "6️⃣ Проверяем DNS..."
{
    echo "=== DNS Check ==="
    if [ -f /root/vless-config/links.txt ]; then
        DOMAIN=$(grep -oP '@\K[^:]+' /root/vless-config/links.txt | head -1)
        echo "Domain from config: $DOMAIN"
        echo ""
        echo "=== DNS Resolution ==="
        dig +short "$DOMAIN" || nslookup "$DOMAIN"
        echo ""
        echo "=== Server IP ==="
        curl -s ifconfig.me || wget -qO- ifconfig.me
    else
        echo "Cannot find domain in /root/vless-config/links.txt"
    fi
} > "$DIAG_DIR/dns-check.txt"

# 7. Firewall проверка
echo "7️⃣ Проверяем firewall..."
{
    echo "=== UFW Status ==="
    if command -v ufw &> /dev/null; then
        ufw status verbose
    else
        echo "UFW not installed"
    fi
    echo ""
    echo "=== iptables Rules ==="
    iptables -L -n -v
} > "$DIAG_DIR/firewall.txt"

# 8. Network connectivity
echo "8️⃣ Проверяем сетевое соединение..."
{
    echo "=== Network Interfaces ==="
    ip addr show
    echo ""
    echo "=== Routing Table ==="
    ip route show
    echo ""
    echo "=== Internet Connectivity ==="
    ping -c 4 8.8.8.8
    echo ""
    echo "=== DNS Resolution Test ==="
    ping -c 4 google.com
} > "$DIAG_DIR/network.txt"

# 9. VLESS конфигурация
echo "9️⃣ Копируем VLESS конфиги..."
if [ -d /root/vless-config ]; then
    cp -r /root/vless-config "$DIAG_DIR/"
else
    echo "❌ /root/vless-config not found" > "$DIAG_DIR/vless-config-ERROR.txt"
fi

# 10. Проверка Xray версии
echo "🔟 Проверяем версию Xray..."
{
    echo "=== Xray Version ==="
    /usr/local/bin/xray version || xray version
    echo ""
    echo "=== Xray Binary Info ==="
    ls -lh /usr/local/bin/xray
    echo ""
    echo "=== Xray Binary MD5 ==="
    md5sum /usr/local/bin/xray
} > "$DIAG_DIR/xray-version.txt"

# 11. Проверка процессов
echo "1️⃣1️⃣ Проверяем процессы..."
{
    echo "=== Xray Processes ==="
    ps aux | grep xray | grep -v grep
    echo ""
    echo "=== Resource Usage ==="
    top -b -n 1 | head -20
} > "$DIAG_DIR/processes.txt"

# 12. Тест подключения к портам
echo "1️⃣2️⃣ Тестируем порты локально..."
{
    echo "=== Port Connection Tests ==="
    for port in 443 8443 2053; do
        echo "Testing port $port..."
        timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>&1
        if [ $? -eq 0 ]; then
            echo "✅ Port $port is open and accepting connections"
        else
            echo "❌ Port $port is NOT accepting connections"
        fi
        echo ""
    done
} > "$DIAG_DIR/port-tests.txt"

# 13. Создаем summary
echo "1️⃣3️⃣ Создаем summary..."
{
    echo "=========================================="
    echo "🔍 DIAGNOSTIC SUMMARY"
    echo "=========================================="
    echo ""
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "IP: $(curl -s ifconfig.me 2>/dev/null || echo 'unknown')"
    echo ""

    echo "=== Xray Status ==="
    systemctl is-active xray >/dev/null 2>&1 && echo "✅ Xray is running" || echo "❌ Xray is NOT running"

    echo ""
    echo "=== Open Ports ==="
    ss -tlnp | grep -E ":(443|8443|2053)" || echo "❌ No expected ports open"

    echo ""
    echo "=== Config File ==="
    [ -f /usr/local/etc/xray/config.json ] && echo "✅ Config exists" || echo "❌ Config missing"

    echo ""
    echo "=== Recent Errors ==="
    journalctl -u xray -p err --no-pager -n 5 --since "1 hour ago"

    echo ""
    echo "=========================================="
    echo "📁 Full diagnostics saved to: $DIAG_DIR"
    echo "=========================================="
} | tee "$DIAG_DIR/SUMMARY.txt"

# Создаем архив
echo ""
echo "📦 Создаем архив..."
ARCHIVE_NAME="chameleon-diag-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "/root/$ARCHIVE_NAME" -C "$(dirname "$DIAG_DIR")" "$(basename "$DIAG_DIR")"

echo ""
echo "=========================================="
echo "✅ Диагностика завершена!"
echo "=========================================="
echo ""
echo "📁 Папка с диагностикой: $DIAG_DIR"
echo "📦 Архив: /root/$ARCHIVE_NAME"
echo ""
echo "Для отправки архива на анализ:"
echo "  scp root@your-server:/root/$ARCHIVE_NAME ."
echo ""
echo "Или просмотрите summary:"
echo "  cat $DIAG_DIR/SUMMARY.txt"
echo ""
