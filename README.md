# 🦎 Chameleon VPN

Простой и надежный VLESS + Reality VPN. Один протокол, один порт, максимальная стабильность.

## Быстрый старт

### На Origin сервере (где будет Xray):

```bash
bash install-vless-simple.sh
```

**Введите:**
- Адрес: IP сервера или домен
- SNI: `static.rutube.ru` (или Enter)

**Получите VLESS ссылку** и импортируйте в клиент!

## Клиенты

**Рекомендуется:** [Happ](https://www.happ.su/) - универсальный клиент для всех платформ

Альтернативы:
- Android: v2rayNG
- iOS: Streisand
- Windows: v2rayN

## Управление

### Основные команды:
```bash
# Статус
systemctl status xray

# Логи
journalctl -u xray -f

# Перезапуск
systemctl restart xray

# VLESS ссылка
cat /root/vless-config/links.txt

# Проверка порта
ss -tlnp | grep 8443

# Диагностика
bash diagnose.sh
```

## Проброс через Yandex сервер

Если нужен российский IP или промежуточный сервер:

### На Yandex сервере:
```bash
bash setup-proxy-simple.sh
```

**Введите:** IP Origin сервера

**Получите:** VLESS ссылку с IP Yandex сервера

**Схема:**
```
Клиент → Yandex (проброс) → Origin (Xray) → Интернет
```

### Управление пробросом:
```bash
# Статус
systemctl status vless-proxy-8443

# Логи
journalctl -u vless-proxy-8443 -f

# Проверка
ss -tlnp | grep 8443
```

## Решение проблем

### "Сервер закрыл соединение"

```bash
# Проверьте Xray
systemctl status xray

# Проверьте порт
ss -tlnp | grep 8443

# Откройте порт
ufw allow 8443/tcp

# Перезапустите
systemctl restart xray
```

### Нет запросов в логах

**Причина:** Клиент не достигает сервера

**Решение:**
- Проверьте IP в VLESS ссылке
- Проверьте DNS (если используете домен)
- Используйте IP вместо домена для надежности

### Полная диагностика

```bash
bash diagnose.sh
# Создаст архив: /root/chameleon-diag-*.tar.gz
```

---

## Технические детали

**Конфигурация:**
- Протокол: VLESS + Reality
- Network: TCP
- Flow: xtls-rprx-vision
- Fingerprint: random
- SNI: static.rutube.ru (рекомендуется)
- Порт: 8443

**Почему порт 8443:**
- Не конфликтует с HTTPS (443)
- Хорошо проходит через firewall
- Меньше блокировок

**Домен vs IP:**
| Параметр | Домен | IP |
|----------|-------|-----|
| Надежность | Зависит от DNS | ✅ Не зависит |
| Скорость | DNS lookup | ✅ Прямое |
| Настройка | A-запись нужна | ✅ Не требуется |
| **Рекомендация** | Постоянное использование | **Максимальная надежность** |

## Файлы проекта

```
chameleon/
├── install-vless-simple.sh    # Установка на Origin
├── setup-proxy-simple.sh      # Проброс на Yandex
├── diagnose.sh                # Диагностика
└── README.md                  # Эта документация
```

**На сервере:**
```
/usr/local/etc/xray/config.json       # Конфигурация
/root/vless-config/links.txt          # VLESS ссылки
/root/vless-config/keys.txt           # Ключи
```

---

## Безопасность

**Не публикуйте:**
- UUID
- Private/Public Keys
- VLESS ссылки

**Регулярно обновляйте:**
```bash
apt update && apt upgrade -y
```

**Смена ключей:**
```bash
bash install-vless-simple.sh  # Создаст новые ключи
```

## FAQ

**Q: Домен или IP?**
A: Оба работают. IP надежнее (не зависит от DNS).

**Q: Нужен ли проброс?**
A: Нет, если Origin доступен напрямую. Да, если нужен конкретный IP.

**Q: Как обновить конфигурацию?**
A: Запустите `install-vless-simple.sh` заново.

**Q: Не работает - что делать?**
A: Запустите `diagnose.sh` и проверьте `systemctl status xray`.

**Версия:** 1.0 Simple & Reliable | **Статус:** ✅ Production Ready
