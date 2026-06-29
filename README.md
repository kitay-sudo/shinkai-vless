# Shinkai VLESS

Интерактивный установщик Xray **VLESS + XHTTP + Reality** для Debian/Ubuntu. Один скрипт — рабочая клиентская ссылка.

Трафик идёт в форме обычных HTTP/2-запросов (XHTTP) под маскировкой Reality — это переживает throttling провайдеров, который убивает «голый TCP-Reality».

## Скрипты

| Скрипт | Что делает |
| --- | --- |
| [`install.sh`](install.sh) | VLESS + XHTTP + Reality сервер. Клиент коннектится напрямую. |
| [`install-relay.sh`](install-relay.sh) | Транзитный узел в РФ (белый IP), форвардит на основной сервер. |
| [`uninstall.sh`](uninstall.sh) | Полное удаление: остановка сервисов + снос всего, что поставили. |

```text
install.sh:        клиент ─────────────────────→ сервер → интернет
install-relay.sh:  клиент → РФ-узел → сервер (Швеция) → интернет
```

## Установка сервера

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/install.sh | sudo bash
```

Спросит IP/домен сервера и SNI (по умолчанию `static.rutube.ru`). Без интерактива:

```bash
curl -sSL .../install.sh | sudo bash -s -- SERVER_IP [SNI]
```

Ставит Xray, генерит UUID/Reality-ключи/путь, открывает порт `443/tcp`, запускает сервис.
Конфиг: `/usr/local/etc/xray/config.json` · ключи и ссылка: `/root/vless-config/`.

```bash
systemctl status xray        # статус
journalctl -u xray -f        # логи
ss -tlnp | grep 443          # порт
```

## Цепочка через РФ — `install-relay.sh`

Транзитный узел с «белым» РФ-IP: клиент видит только российский IP, вход маскируется под `ozon.ru`, участок `РФ → сервер` — отдельный XHTTP+Reality туннель. На основном сервере менять ничего не нужно.

```bash
curl -sSL .../install-relay.sh | sudo bash
```

Спросит IP РФ-узла, SNI входа (`ozon.ru`) и `vless://` ссылку основного сервера (параметры извлекаются автоматически). Порт входа по умолчанию `443/tcp`.

### Два режима выхода — `vless-mode`

Переключение не меняет клиентскую ссылку:

```bash
sudo vless-mode chain    # выход через основной сервер (обход)
sudo vless-mode direct   # выход прямо с РФ-узла (российский IP, быстро)
sudo vless-mode status
```

### Цепочка из двух РФ-узлов

Прячет от провайдера первого узла сам факт заграничного коннекта:

```text
Клиент → РФ-узел №1 → РФ-узел №2 (другой хостинг!) → Швеция → интернет
```

Ставь снизу вверх: сначала Швеция (`install.sh`), потом №2 и №1 (`install-relay.sh`), каждый раз передавая `vless://` ссылку предыдущего узла как upstream. Финальную ссылку (с №1) вставляешь в клиент. РФ-узел №2 должен быть **не на том же хостинге**, что №1.

## Удаление

```bash
curl -sSL https://raw.githubusercontent.com/kitay-sudo/shinkai-vless/main/uninstall.sh | sudo bash
```

Останавливает и сносит Xray, удаляет конфиги, ключи, `vless-mode` и правила фаервола.

## Если связь нестабильна

XHTTP требует свежий Xray (ставится автоматически официальным установщиком). Клиент тоже должен поддерживать `xhttp` (v2rayNG ≥ 1.9, Nekoray, Streisand, Hiddify). Проверь, что слушается порт: `ss -tlnp | grep -E ':443|:8443'`.

## Безопасность

Не публикуй UUID, private key, `vless://` ссылку и содержимое `/root/vless-config/`.

## License

MIT
