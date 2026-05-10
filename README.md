# Chameleon VLESS

Простой установщик Xray VLESS + Reality на Linux-сервер.

## Установка одной командой

На сервере:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/Chameleon/main/install.sh | sudo bash -s -- SERVER_IP_OR_DOMAIN
```

Пример:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/Chameleon/main/install.sh | sudo bash -s -- 1.2.3.4
```

С явным SNI:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/Chameleon/main/install.sh | sudo bash -s -- 1.2.3.4 static.rutube.ru
```

Если запускать из уже скачанного репозитория:

```bash
sudo bash install-vless-simple.sh SERVER_IP_OR_DOMAIN static.rutube.ru
```

Без аргументов скрипт спросит адрес сервера и SNI интерактивно.

## Можно ли ставить рядом с Chameleon

Да. Конфликта нет:

- Chameleon обычно слушает `443`.
- VLESS Reality из этого скрипта слушает `8443`.
- Сервисы разные: `chameleon` и `xray`.

После установки на одном сервере будут работать оба варианта:

- Chameleon: `https/tunnel` на `443`.
- VLESS Reality: `vless://...` на `8443`.

Важно открыть порт `8443/tcp` у провайдера/VPS firewall, если он закрыт.

## Где взять ссылку VLESS

После установки:

```bash
sudo cat /root/vless-config/links.txt
```

Импортируй эту ссылку в клиент:

- Android: v2rayNG
- iOS: Streisand
- Windows: v2rayN
- Универсально: Happ

## Управление

```bash
systemctl status xray
journalctl -u xray -f
systemctl restart xray
ss -tlnp | grep 8443
```

Диагностика:

```bash
bash diagnose.sh
```

## Что ставится

- Xray
- VLESS + Reality
- TCP
- Flow: `xtls-rprx-vision`
- Порт: `8443`
- SNI по умолчанию: `static.rutube.ru`

Конфиг сервера:

```text
/usr/local/etc/xray/config.json
```

Сохраненные ключи и ссылки:

```text
/root/vless-config/keys.txt
/root/vless-config/links.txt
```

## Обновление или пересоздание ключей

Запусти установку заново:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/Chameleon/main/install.sh | sudo bash -s -- SERVER_IP_OR_DOMAIN
```

Скрипт пересоздаст конфиг, ключи и VLESS-ссылку.

## Безопасность

Не публикуй:

- UUID
- private key
- VLESS-ссылку
- содержимое `/root/vless-config/keys.txt`
