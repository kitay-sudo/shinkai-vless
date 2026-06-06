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

## Цепочка через РФ-сервер (белый список)

`install-relay.sh` поднимает транзитный (промежуточный) узел в РФ — например, на сервере в Яндекс.Облаке с «белым» IP. Клиент коннектится к этому узлу, а тот сам идёт VLESS-клиентом на твой основной сервер (Швеция).

```text
клиент → РФ-узел (белый IP, маскировка под ozon.ru) → Швеция (VLESS+Reality) → интернет
```

Зачем так:

- Клиент видит только российский «белый» IP. Если провайдер работает в режиме белых списков, разрешённый российский ресурс остаётся доступным.
- Вход `клиент → РФ` маскируется Reality под легитимный российский домен (по умолчанию `ozon.ru`). Активная проверка IP отдаёт настоящий TLS-ответ этого домена.
- Участок `РФ → Швеция` — отдельный Reality-туннель, тоже под видом TLS. Домен не нужен ни на одном из узлов — Reality берёт чужой SNI.

### Установка транзита

На российском сервере:

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install-relay.sh | sudo bash
```

Скрипт спросит:

- публичный IP/домен этого РФ-сервера (для клиентской ссылки);
- SNI входа `клиент → РФ`, по умолчанию `ozon.ru` (можно сменить на `static.rutube.ru`, `yastatic.net` и т.п.);
- `vless://` ссылку основного сервера (из вывода `install.sh`) — параметры Швеции достаются из неё автоматически.

Без интерактива:

```bash
curl -sSL .../install-relay.sh | sudo bash -s -- RF_SERVER_IP "vless://...основная ссылка..."
```

По умолчанию вход слушает порт `443/tcp` (максимально похоже на обычный HTTPS). Сменить: `RELAY_PORT=8443`, SNI: `RELAY_SNI=static.rutube.ru`.

В конце скрипт выдаёт **новую** клиентскую ссылку — она ведёт на РФ-узел. Старую (прямую на Швецию) клиенту использовать больше не нужно. Результат сохраняется в `/root/vless-config/relay-links.txt` и `relay-keys.txt`.

### Если связь нестабильна

Обе ноды используют `xtls-rprx-vision`. Если на конкретной версии Xray цепочка капризничает, убери `flow` у входного клиента (в `clients[0]` конфига РФ и в клиентской ссылке) — Reality продолжит работать без Vision.

## Безопасность

Не публикуй:

- UUID
- private key
- VLESS-ссылку
- содержимое `/root/vless-config/keys.txt` и `relay-keys.txt`

## License

MIT
