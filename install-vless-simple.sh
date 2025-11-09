#!/bin/bash

# 🦎 Chameleon - Simple VLESS Reality Installation
# Только один проверенный протокол: VLESS + Reality на порту 8443
# Работает везде, надежно, без лишних сложностей

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "=========================================="
echo "🦎 Chameleon - Simple VLESS Reality"
echo "=========================================="
echo -e "${NC}"

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# Шаг 1: Запрос домена или IP
echo -e "${YELLOW}📝 Настройка подключения${NC}"
echo ""
read -p "Введите ваш домен или IP адрес (например, origin.alfavin.ru или 158.160.57.53): " SERVER_ADDR

if [ -z "$SERVER_ADDR" ]; then
    echo -e "${RED}❌ Адрес не может быть пустым${NC}"
    exit 1
fi

# Шаг 2: Запрос SNI
echo ""
echo -e "${YELLOW}📝 Настройка SNI (Server Name Indication)${NC}"
echo "Рекомендуется: static.rutube.ru, cloudflare.com, www.google.com"
read -p "Введите SNI домен [static.rutube.ru]: " SNI_DOMAIN
SNI_DOMAIN=${SNI_DOMAIN:-static.rutube.ru}

# Шаг 3: Установка Xray
echo ""
echo -e "${BLUE}📦 Устанавливаем Xray...${NC}"

# Обновление системы
apt update -qq

# Установка зависимостей
apt install -y curl wget unzip jq > /dev/null 2>&1

# Скачивание и установка Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Шаг 4: Генерация ключей Reality
echo ""
echo -e "${BLUE}🔑 Генерируем ключи Reality...${NC}"

# Генерация Reality ключей
KEYS=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Password:" | awk '{print $2}')

# Генерация UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# Генерация Short ID
SHORT_ID=$(openssl rand -hex 8)

echo -e "${GREEN}✅ Ключи сгенерированы${NC}"

# Шаг 5: Создание конфигурации Xray
echo ""
echo -e "${BLUE}⚙️  Создаем конфигурацию Xray...${NC}"

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

echo -e "${GREEN}✅ Конфигурация создана${NC}"

# Шаг 6: Настройка firewall
echo ""
echo -e "${BLUE}🔥 Настраиваем firewall...${NC}"

# Открываем порт 8443
if command -v ufw &> /dev/null; then
    ufw allow 8443/tcp > /dev/null 2>&1
    echo -e "${GREEN}✅ UFW: порт 8443 открыт${NC}"
else
    # Если UFW нет, используем iptables
    iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    echo -e "${GREEN}✅ iptables: порт 8443 открыт${NC}"
fi

# Шаг 7: Запуск Xray
echo ""
echo -e "${BLUE}🚀 Запускаем Xray...${NC}"

systemctl enable xray
systemctl restart xray

# Проверка статуса
sleep 2
if systemctl is-active --quiet xray; then
    echo -e "${GREEN}✅ Xray успешно запущен${NC}"
else
    echo -e "${RED}❌ Ошибка запуска Xray${NC}"
    journalctl -u xray -n 20
    exit 1
fi

# Шаг 8: Сохранение конфигурации
echo ""
echo -e "${BLUE}💾 Сохраняем конфигурацию...${NC}"

mkdir -p /root/vless-config

# Сохранение ключей
cat > /root/vless-config/keys.txt <<EOF
========================================
🔑 Chameleon VLESS Reality Keys
========================================

Server: $SERVER_ADDR
SNI: $SNI_DOMAIN
Port: 8443

UUID: $UUID
Private Key: $PRIVATE_KEY
Public Key: $PUBLIC_KEY
Short ID: $SHORT_ID

========================================
EOF

# Создание VLESS ссылки
VLESS_LINK="vless://${UUID}@${SERVER_ADDR}:8443?type=tcp&security=reality&fp=random&pbk=${PUBLIC_KEY}&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Chameleon-Simple"

# Сохранение ссылки
cat > /root/vless-config/links.txt <<EOF
========================================
🦎 Chameleon VLESS Reality Link
========================================

Server: $SERVER_ADDR:8443
Protocol: VLESS + Reality
SNI: $SNI_DOMAIN

📱 Ссылка для подключения:
========================================

$VLESS_LINK

========================================

📋 Как использовать:
========================================

1. Скопируйте ссылку выше
2. Откройте v2rayNG (Android) или Streisand (iOS)
3. Нажмите + → "Import config from clipboard"
4. Вставьте ссылку
5. Подключайтесь!

========================================

⚙️ Параметры конфигурации:
========================================

UUID:        $UUID
Public Key:  $PUBLIC_KEY
Short ID:    $SHORT_ID
SNI:         $SNI_DOMAIN
Type:        tcp
Security:    reality
Fingerprint: random
Flow:        xtls-rprx-vision
Port:        8443

========================================

🔧 Управление:
========================================

Статус:      systemctl status xray
Логи:        journalctl -u xray -f
Перезапуск:  systemctl restart xray
Порты:       ss -tlnp | grep 8443

========================================
EOF

echo -e "${GREEN}✅ Конфигурация сохранена в /root/vless-config/${NC}"

# Шаг 9: Итоговая информация
echo ""
echo -e "${GREEN}"
echo "=========================================="
echo "✅ Установка завершена!"
echo "=========================================="
echo -e "${NC}"
echo ""
echo -e "${BLUE}📱 Ваша VLESS ссылка:${NC}"
echo ""
echo -e "${YELLOW}$VLESS_LINK${NC}"
echo ""
echo -e "${BLUE}📋 Дополнительные команды:${NC}"
echo ""
echo "  Просмотр ссылки:      cat /root/vless-config/links.txt"
echo "  Просмотр ключей:      cat /root/vless-config/keys.txt"
echo "  Статус Xray:          systemctl status xray"
echo "  Логи Xray:            journalctl -u xray -f"
echo "  Проверка порта:       ss -tlnp | grep 8443"
echo "  Диагностика:          bash diagnose.sh"
echo ""
echo -e "${BLUE}🔧 Управление:${NC}"
echo ""
echo "  Перезапуск:           systemctl restart xray"
echo "  Остановка:            systemctl stop xray"
echo "  Запуск:               systemctl start xray"
echo ""
echo -e "${GREEN}=========================================="
echo "🎉 Готово! Подключайтесь!"
echo "==========================================${NC}"
echo ""

# Показываем статус порта
echo -e "${BLUE}🔍 Проверка порта 8443:${NC}"
ss -tlnp | grep 8443 || echo -e "${YELLOW}⚠️  Порт не отображается (возможно, нужно подождать)${NC}"
echo ""
