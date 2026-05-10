# Shinkai VLESS

[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Xray](https://img.shields.io/badge/Xray-VLESS%20Reality-2F80ED)](https://github.com/XTLS/Xray-core)
[![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-555555?logo=linux&logoColor=white)](#что-ставится)
[![License](https://img.shields.io/badge/License-MIT-green)](#license)
[![Install](https://img.shields.io/badge/Install-curl%20%7C%20bash-orange)](#установка)

Shinkai VLESS - это простой интерактивный установщик Xray VLESS + Reality для Linux-сервера.

Цель проекта - не собрать комбайн из десятков режимов, а дать один понятный и воспроизводимый сценарий: запустить скрипт, ввести адрес сервера, получить готовую VLESS-ссылку для клиента.

## Философия

Shinkai исходит из простой идеи: инфраструктурный скрипт должен быть скучным, читаемым и предсказуемым.

- Один основной файл установки: `install.sh`.
- Один проверенный протокол: VLESS + Reality.
- Один порт по умолчанию: `8443/tcp`.
- Понятный интерактивный запуск без ручного редактирования JSON.
- Нормальные сообщения об ошибках вместо молчаливых падений.
- Результат сохраняется в очевидном месте: `/root/vless-config/`.

Проект не пытается заменить полноценную панель управления. Он нужен, когда надо быстро и аккуратно поднять рабочий VLESS Reality на чистом Debian/Ubuntu-сервере.

## Описание

Скрипт устанавливает Xray, генерирует UUID и Reality-ключи, пишет конфиг, открывает порт через `ufw` или `iptables`, запускает сервис `xray` и сохраняет готовую клиентскую ссылку.

Он работает двумя способами:

- локально из скачанного репозитория;
- одной командой через `curl | sudo bash`.

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

## License

MIT
