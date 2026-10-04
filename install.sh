#!/bin/sh
# Установщик mihomo-sync.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | sh -s -- -reconf
#
# Скачивает update-config.sh и config.template.yaml в $DIR, спрашивает адрес
# подписки и пароль веб-интерфейса, собирает config.yaml и перезапускает xkeen.
# Повторный запуск обновляет сами файлы проекта; значения не спрашивает,
# пока не передан -reconf.

REPO_RAW=${REPO_RAW:-https://raw.githubusercontent.com/tuefalek/freedom-xkeen/main}
DIR=${DIR:-/opt/etc/mihomo}
export DIR

case "$1" in
  -h|--help)
    cat <<EOF
Использование: ... | sh [-s -- -reconf]
  -reconf   заново спросить адрес подписки и пароль веб-интерфейса
Переменные: DIR (по умолчанию /opt/etc/mihomo), REPO_RAW (откуда качать файлы)
EOF
    exit 0 ;;
esac

die() { echo "Ошибка: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "нужен curl (opkg install curl ca-certificates)"
[ -d "$DIR" ] || die "нет каталога $DIR. Сначала поставь xkeen и mihomo."

TMP=$(mktemp -d) || die "не удалось создать временный каталог"
trap 'rm -rf "$TMP"' EXIT

echo "Скачиваю файлы из $REPO_RAW ..."
for f in update-config.sh config.template.yaml; do
  curl -fsSL "$REPO_RAW/$f" -o "$TMP/$f" || die "не удалось скачать $f"
  [ -s "$TMP/$f" ] || die "$f пустой"
done
head -n 1 "$TMP/update-config.sh" | grep -q '^#!/bin/sh' || die "update-config.sh скачался неправильно"
grep -q '#@@BALANCERS@@' "$TMP/config.template.yaml"      || die "config.template.yaml скачался неправильно"

# локальные правки шаблона не теряем молча
if [ -f "$DIR/config.template.yaml" ] && ! cmp -s "$TMP/config.template.yaml" "$DIR/config.template.yaml"; then
  cp "$DIR/config.template.yaml" "$DIR/config.template.yaml.bak"
  echo "Шаблон изменился, старый сохранён: $DIR/config.template.yaml.bak"
fi
cp "$TMP/config.template.yaml" "$DIR/config.template.yaml"
cp "$TMP/update-config.sh" "$DIR/update-config.sh"
chmod +x "$DIR/update-config.sh"

echo
"$DIR/update-config.sh" "$@" || {
  echo >&2
  echo "Установка не завершена, см. сообщения выше. Повторить: $DIR/update-config.sh" >&2
  exit 1
}

LAN_IP=$(ip -4 addr show br0 2>/dev/null | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}')
[ -n "$LAN_IP" ] || LAN_IP="<IP-роутера>"

cat <<EOF

=====================================================================
Готово.

Веб-интерфейс:   http://$LAN_IP:9090/ui
Пароль:          cat $DIR/.secret
Адрес подписки:  cat $DIR/.sub_url

Обновить конфиг (список групп берётся с сервера подписки):
  $DIR/update-config.sh

Сменить адрес подписки или пароль:
  $DIR/update-config.sh -reconf

Автообновление: добавь в cron (crontab -e):
  0 */6 * * * $DIR/update-config.sh >/dev/null 2>&1

Обновить сам проект (скрипт и шаблон):
  curl -fsSL $REPO_RAW/install.sh | sh

config.yaml собирается из config.template.yaml и перезаписывается при
каждом обновлении, правь шаблон, а не config.yaml.
=====================================================================
EOF
