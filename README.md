# mihomo-sync

Установка и обновление клиентского конфига mihomo на роутере с xkeen (Keenetic / Netcraze + Entware) для подписки PigFarm FreeDom.

Конфиг собирается из шаблона `config.template.yaml`. Из серверного конфига подписки берётся только список балансировщиков (имя и filter), так что при изменении состава серверов достаточно запустить скрипт ещё раз.

## Требования

- роутер с Entware, установленные `xkeen` и `mihomo` (каталог `/opt/etc/mihomo`);
- `curl` с сертификатами: `opkg install curl ca-certificates`;
- адрес подписки (из бота или личного кабинета).

Bash не нужен, скрипты написаны на POSIX sh и проверены на BusyBox.

## Установка

```sh
curl -fsSL https://raw.githubusercontent.com/tuefalek/freedom-xkeen/main/install.sh | sh
```

Установщик скачает `update-config.sh` и `config.template.yaml` в `/opt/etc/mihomo`, спросит адрес подписки и пароль веб-интерфейса (Enter на пароле — сгенерировать), соберёт `config.yaml`, перезапустит xkeen и выведет инструкцию.

## Сменить адрес подписки или пароль

```sh
/opt/etc/mihomo/update-config.sh -reconf
```

То же через установщик, заодно обновит файлы проекта:

```sh
curl -fsSL https://raw.githubusercontent.com/tuefalek/freedom-xkeen/main/install.sh | sh -s -- -reconf
```

В режиме `-reconf` на каждый вопрос можно нажать Enter, тогда остаётся текущее значение.

## Обновление

- Конфиг (группы с сервера): `/opt/etc/mihomo/update-config.sh`. Если ничего не изменилось, xkeen не перезапускается.
- Сам проект: повторить команду установки. Значения заново не спрашиваются. Если шаблон изменился, старый сохраняется как `config.template.yaml.bak`.
- Автообновление: строка в cron (`crontab -e`):
  ```
  0 */6 * * * /opt/etc/mihomo/update-config.sh >/dev/null 2>&1
  ```
  Cron не умеет задавать вопросы, поэтому первый запуск и `-reconf` делаются руками.

## Файлы в /opt/etc/mihomo

| Файл | Что это |
|---|---|
| `.sub_url` | адрес подписки (права 600) |
| `.secret` | пароль веб-интерфейса (права 600) |
| `config.template.yaml` | шаблон; правь его, а не `config.yaml` |
| `config.yaml` | результат; перезаписывается при каждом обновлении |
| `config.yaml.bak` | предыдущий конфиг |
| `update-config.sh` | сборка конфига |

Веб-интерфейс: `http://<IP-роутера>:9090/ui`.

## Как это работает

1. Скачивает подписку с User-Agent `mihomo` и достаёт из `proxy-groups` пары «имя, filter».
2. Группы, имя которых подходит под `EXCLUDE` в начале `update-config.sh` (по умолчанию `Обход БС`), пропускаются.
3. Подставляет в шаблон балансировщики, списки их имён, пароль и адрес провайдера нод (`<подписка>/mihomo/proxies`).
4. Проверяет результат через `mihomo -t`; при ошибке старый конфиг остаётся.
5. Сохраняет `config.yaml.bak`, записывает новый конфиг и перезапускает xkeen.

Плейсхолдеры шаблона: `#@@SECRET@@`, `#@@PROXIES_URL@@`, `#@@BALANCERS@@`, `#@@NAMES@@`.

## Безопасность

`curl | sh` выполняет скачанный код. Для постоянного использования закрепи установку на тег или коммит вместо `main`:

```sh
curl -fsSL https://raw.githubusercontent.com/tuefalek/freedom-xkeen/v1.0.0/install.sh | REPO_RAW=https://raw.githubusercontent.com/tuefalek/freedom-xkeen/v1.0.0 sh
```

Если GitHub с роутера недоступен, выложи те же файлы на любой свой хостинг и передай адрес в `REPO_RAW`.

## Удаление

```sh
rm /opt/etc/mihomo/update-config.sh /opt/etc/mihomo/config.template.yaml /opt/etc/mihomo/.secret /opt/etc/mihomo/.sub_url
```
(`config.yaml` и `.bak` удали или замени своим конфигом, затем `xkeen -restart`.)
