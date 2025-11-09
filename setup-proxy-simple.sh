#!/bin/bash

# 🦎 Chameleon - Simple Proxy Setup for Yandex Server
# Пробрасывает только порт 8443 (VLESS) с Origin на Yandex сервер
# Без gRPC, без лишних сложностей

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "=========================================="
echo "🦎 Chameleon - Simple Proxy Setup"
echo "=========================================="
echo -e "${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}⚠️  ВНИМАНИЕ!${NC}"
echo ""
echo "Этот скрипт для ПРОМЕЖУТОЧНОГО сервера (Yandex)."
echo "Он пробрасывает трафик на Origin сервер."
echo ""
echo "Будет проброшен только порт 8443 (VLESS + Reality)"
echo ""
read -p "Продолжить? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Отменено"
    exit 0
fi

# Шаг 1: Очистка старых сервисов
echo ""
echo -e "${BLUE}🧹 Очистка старых сервисов...${NC}"

# Останавливаем и удаляем все старые сервисы проброса
for PORT in 443 8443 2053; do
    if [ -f "/etc/systemd/system/vless-proxy-${PORT}.service" ]; then
        systemctl stop vless-proxy-${PORT} 2>/dev/null || true
        systemctl disable vless-proxy-${PORT} 2>/dev/null || true
        rm -f /etc/systemd/system/vless-proxy-${PORT}.service
        echo "  Удалён: vless-proxy-${PORT}.service"
    fi
done

# Останавливаем Nginx если есть
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

systemctl daemon-reload

echo -e "${GREEN}✅ Старые сервисы удалены${NC}"

# Шаг 2: Освобождение портов
echo ""
echo -e "${BLUE}🔓 Освобождение портов...${NC}"

# Убиваем процессы на портах
for PORT in 443 8443 2053; do
    if command -v lsof &> /dev/null; then
        PID=$(lsof -ti:$PORT 2>/dev/null || true)
        if [ ! -z "$PID" ]; then
            kill -9 $PID 2>/dev/null || true
            echo "  Порт $PORT освобождён (PID: $PID)"
        fi
    fi
done

echo -e "${GREEN}✅ Порты освобождены${NC}"

# Шаг 3: Установка socat
echo ""
echo -e "${BLUE}📦 Установка socat...${NC}"

apt update -qq
apt install -y socat lsof net-tools curl > /dev/null 2>&1

echo -e "${GREEN}✅ socat установлен${NC}"

# Шаг 4: Ввод данных Origin сервера
echo ""
echo -e "${BLUE}📝 Настройка подключения к Origin${NC}"
echo ""
read -p "Введите IP Origin сервера: " ORIGIN_IP

if [ -z "$ORIGIN_IP" ]; then
    echo -e "${RED}❌ IP не может быть пустым${NC}"
    exit 1
fi

echo ""
echo "Проверка доступности Origin..."
if ping -c 2 $ORIGIN_IP >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Origin сервер доступен${NC}"
else
    echo -e "${YELLOW}⚠️  Origin сервер не отвечает на ping (возможно, нормально)${NC}"
fi

# Получаем IP этого сервера
CURRENT_IP=$(curl -s ifconfig.me)

echo ""
echo -e "${GREEN}Origin сервер:${NC} $ORIGIN_IP"
echo -e "${GREEN}Yandex сервер:${NC} $CURRENT_IP"
echo ""

# Шаг 5: Создание сервиса проброса
echo ""
echo -e "${BLUE}⚙️  Создание сервиса проброса (порт 8443)...${NC}"

PORT=8443

cat > /etc/systemd/system/vless-proxy-${PORT}.service <<EOF
[Unit]
Description=VLESS Proxy Port $PORT to Origin Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat TCP-LISTEN:${PORT},fork,reuseaddr TCP:${ORIGIN_IP}:${PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vless-proxy-${PORT}
systemctl start vless-proxy-${PORT}

sleep 2

if systemctl is-active --quiet vless-proxy-${PORT}; then
    echo -e "${GREEN}✅ Сервис проброса запущен${NC}"
else
    echo -e "${RED}❌ Ошибка запуска сервиса${NC}"
    journalctl -u vless-proxy-${PORT} -n 10 --no-pager
    exit 1
fi

# Шаг 6: Настройка firewall
echo ""
echo -e "${BLUE}🔥 Настройка firewall...${NC}"

if command -v ufw &> /dev/null; then
    ufw allow ${PORT}/tcp > /dev/null 2>&1
    echo -e "${GREEN}✅ UFW: порт ${PORT} открыт${NC}"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=${PORT}/tcp > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
    echo -e "${GREEN}✅ firewalld: порт ${PORT} открыт${NC}"
else
    # Используем iptables
    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
    echo -e "${GREEN}✅ iptables: порт ${PORT} открыт${NC}"
fi

# Шаг 7: Проверка
echo ""
echo -e "${BLUE}🔍 Проверка работы...${NC}"

sleep 1

if ss -tlnp | grep -q ":${PORT} "; then
    echo -e "${GREEN}✅ Порт ${PORT} слушается${NC}"
else
    echo -e "${RED}❌ Порт ${PORT} не слушается${NC}"
    exit 1
fi

# Проверка доступности Origin на порту
if timeout 3 bash -c "echo > /dev/tcp/${ORIGIN_IP}/${PORT}" 2>/dev/null; then
    echo -e "${GREEN}✅ Origin доступен на порту ${PORT}${NC}"
else
    echo -e "${YELLOW}⚠️  Origin не отвечает на порту ${PORT}${NC}"
    echo -e "${YELLOW}   (Возможно, firewall или Origin не запущен)${NC}"
fi

# Шаг 8: Создание VLESS ссылки
echo ""
echo -e "${BLUE}📱 Создание VLESS ссылки...${NC}"

# UUID и ключи из Origin сервера
UUID="0d2e067f-508b-40f5-871b-f4492ebaab14"
PUBLIC_KEY="o6aR2VF8tbgzaCqkzRKX13TsLdI54aaBwlGww2FTQSI"
SHORT_ID="676c7f42d711e173"
SNI="static.rutube.ru"

VLESS_LINK="vless://${UUID}@${CURRENT_IP}:${PORT}?type=tcp&security=reality&fp=random&pbk=${PUBLIC_KEY}&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Chameleon-Yandex"

# Сохранение инструкции
mkdir -p /root/proxy-config

cat > /root/proxy-config/info.txt <<EOF
========================================
🦎 Chameleon Proxy Configuration
========================================

Настроено: $(date)

Origin сервер:  $ORIGIN_IP:$PORT
Yandex сервер:  $CURRENT_IP:$PORT
Проброшен порт: $PORT (VLESS + Reality)

========================================
📱 VLESS ссылка для подключения
========================================

$VLESS_LINK

========================================
⚙️ Параметры
========================================

UUID:        $UUID
Public Key:  $PUBLIC_KEY
Short ID:    $SHORT_ID
SNI:         $SNI
Type:        tcp
Security:    reality
Fingerprint: random
Flow:        xtls-rprx-vision
Port:        $PORT

========================================
🔧 Управление
========================================

Статус:
  systemctl status vless-proxy-${PORT}

Логи:
  journalctl -u vless-proxy-${PORT} -f

Порт:
  ss -tlnp | grep ${PORT}

Перезапуск:
  systemctl restart vless-proxy-${PORT}

Остановка:
  systemctl stop vless-proxy-${PORT}

Удаление:
  systemctl stop vless-proxy-${PORT}
  systemctl disable vless-proxy-${PORT}
  rm /etc/systemd/system/vless-proxy-${PORT}.service
  systemctl daemon-reload

========================================
🔍 Диагностика
========================================

Проверка портов:
  ss -tlnp | grep ${PORT}

Тест подключения к Origin:
  nc -zv $ORIGIN_IP $PORT

Логи ошибок:
  journalctl -u vless-proxy-${PORT} -p err -n 50

========================================
EOF

# Шаг 9: Итоговая информация
echo ""
echo -e "${GREEN}"
echo "=========================================="
echo "✅ Проброс настроен!"
echo "=========================================="
echo -e "${NC}"
echo ""
echo -e "${BLUE}📊 Конфигурация:${NC}"
echo ""
echo "  Origin сервер:  $ORIGIN_IP:$PORT"
echo "  Yandex сервер:  $CURRENT_IP:$PORT"
echo "  Проброшен порт: $PORT (VLESS + Reality)"
echo ""
echo -e "${BLUE}📱 Ваша VLESS ссылка через Yandex:${NC}"
echo ""
echo -e "${YELLOW}$VLESS_LINK${NC}"
echo ""
echo -e "${BLUE}📋 Дополнительные команды:${NC}"
echo ""
echo "  Просмотр ссылки:  cat /root/proxy-config/info.txt"
echo "  Статус проброса:  systemctl status vless-proxy-${PORT}"
echo "  Логи проброса:    journalctl -u vless-proxy-${PORT} -f"
echo "  Проверка порта:   ss -tlnp | grep ${PORT}"
echo ""
echo -e "${GREEN}=========================================="
echo "🎉 Готово! Используйте VLESS ссылку выше!"
echo "==========================================${NC}"
echo ""

# Показываем статус
echo -e "${BLUE}🔍 Текущий статус:${NC}"
ss -tlnp | grep ${PORT} || echo -e "${YELLOW}⚠️  Порт не отображается${NC}"
echo ""
