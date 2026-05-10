# Shinkai VLESS

Интерактивный установщик Xray VLESS + Reality для Linux-сервера.

В проекте оставлен один основной файл установки: `install.sh`. Он работает и локально из скачанного репозитория, и одной командой через `curl | sudo bash`.

## Установка

На сервере:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install.sh | sudo bash
```

Скрипт интерактивно спросит:

- IP или домен сервера
- SNI-домен, по умолчанию `static.rutube.ru`

Без интерактива:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install.sh | sudo bash -s -- SERVER_IP_OR_DOMAIN
```

С явным SNI:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install.sh | sudo bash -s -- SERVER_IP_OR_DOMAIN static.rutube.ru
```

Если репозиторий уже скачан:

```bash
sudo bash install.sh SERVER_IP_OR_DOMAIN static.rutube.ru
```

## Что ставится

- Xray
- VLESS + Reality
- TCP inbound на порту `8443`
- Flow: `xtls-rprx-vision`
- SNI по умолчанию: `static.rutube.ru`

Конфиг сервера:

```text
/usr/local/etc/xray/config.json
```

Ключи и клиентская ссылка:

```text
/root/vless-config/keys.txt
/root/vless-config/links.txt
```

## Управление

```bash
systemctl status xray
journalctl -u xray -f
systemctl restart xray
ss -tlnp | grep 8443
```

Чтобы пересоздать ключи и конфигурацию, запусти установку заново:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install.sh | sudo bash -s -- SERVER_IP_OR_DOMAIN
```

## Firewall

Открой `8443/tcp` в панели VPS-провайдера, если порт закрыт.

Скрипт также пытается открыть порт через `ufw` или `iptables` на самом сервере.

## Безопасность

Не публикуй:

- UUID
- private key
- VLESS-ссылку
- содержимое `/root/vless-config/keys.txt`
