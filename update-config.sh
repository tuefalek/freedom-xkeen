#!/bin/sh
# mihomo-sync: собирает config.yaml из config.template.yaml.
#  - балансировщики берёт из серверного конфига подписки (имя + filter);
#  - адрес подписки читает из $DIR/.sub_url, пароль веб-интерфейса из $DIR/.secret;
#  - если файла нет или он пуст, спрашивает значение (терминал берётся из /dev/tty,
#    поэтому работает и при запуске через `curl ... | sh`).
# Ноды приходят через proxy-provider (proxy-sub), копировать их не нужно.

DIR=${DIR:-/opt/etc/mihomo}
TPL=$DIR/config.template.yaml
CFG=$DIR/config.yaml
SECRET_FILE=$DIR/.secret
SUB_FILE=$DIR/.sub_url
UA="mihomo/1.19.0"
EXCLUDE="Обход БС"   # группы, имя которых подходит под regex, в конфиг не попадают

usage() {
  cat <<EOF
Использование: update-config.sh [-reconf]

  (без ключей)  обновить config.yaml и перезапустить xkeen, если что-то изменилось
  -reconf       заново спросить адрес подписки и пароль веб-интерфейса
                (Enter - оставить текущее значение)
  -h            эта справка

Файлы: $SUB_FILE (адрес подписки), $SECRET_FILE (пароль веб-интерфейса)
EOF
}

RECONF=0
for a in "$@"; do
  case "$a" in
    -reconf|--reconf) RECONF=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "неизвестный ключ: $a" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------- ввод ----------
has_tty() { ( : < /dev/tty ) 2>/dev/null; }
filled()  { [ -f "$1" ] && grep -q '[^[:space:]]' "$1"; }

need_tty() {
  has_tty || {
    echo "Нужно задать значения, но терминала нет (cron или ssh без tty)." >&2
    echo "Запусти руками: $DIR/update-config.sh -reconf" >&2
    exit 1
  }
}

# читает строку с терминала в ANSWER (без пробелов по краям)
ask() {
  printf '%s' "$1" > /dev/tty
  IFS= read -r ANSWER < /dev/tty || { echo "ввод прерван" >&2; exit 1; }
  ANSWER=$(printf '%s' "$ANSWER" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

# убирает хвостовой "/" и случайно вставленный "/mihomo/proxies"
normalize_url() { printf '%s' "$1" | sed 's#/*$##; s#/mihomo/proxies$##; s#/*$##'; }

setup_sub() {
  filled "$SUB_FILE" && [ "$RECONF" = 0 ] && return 0
  need_tty
  while :; do
    if filled "$SUB_FILE"; then
      ask "Адрес подписки (Enter - оставить текущий): "
      [ -z "$ANSWER" ] && return 0
    else
      ask "Адрес подписки (https://cdn.smart-load.ru/sub/...): "
    fi
    url=$(normalize_url "$ANSWER")
    case "$url" in
      http://?*|https://?*) break ;;
      *) echo "Адрес должен начинаться с https://" > /dev/tty ;;
    esac
  done
  printf '%s\n' "$url" > "$SUB_FILE"
  chmod 600 "$SUB_FILE"
}

setup_secret() {
  filled "$SECRET_FILE" && [ "$RECONF" = 0 ] && return 0
  need_tty
  if filled "$SECRET_FILE"; then
    ask "Пароль веб-интерфейса (Enter - оставить текущий): "
    [ -z "$ANSWER" ] && return 0
  else
    ask "Пароль веб-интерфейса (Enter - сгенерировать): "
    if [ -z "$ANSWER" ]; then
      ANSWER=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20)
      echo "Сгенерирован пароль: $ANSWER" > /dev/tty
    fi
  fi
  printf '%s\n' "$ANSWER" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
}

[ -f "$TPL" ] || { echo "нет шаблона $TPL" >&2; exit 1; }
setup_sub
setup_secret
SUB_URL=$(tr -d '\r\n' < "$SUB_FILE")

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------- 1. серверный конфиг ----------
curl -fsSL -A "$UA" "$SUB_URL" -o "$TMP/server.yaml" \
  || { echo "Не удалось скачать подписку. Проверь адрес: $DIR/update-config.sh -reconf" >&2; exit 1; }

# ---------- 2. из proxy-groups достаём пары: имя <TAB> filter ----------
cat > "$TMP/pairs.awk" <<'AWK'
function unq(s) {
  sub(/\r$/, "", s)
  sub(/[ \t]+$/, "", s)
  if (s ~ /^'.*'$/) { s = substr(s, 2, length(s) - 2); gsub(/''/, "'", s) }
  else if (s ~ /^".*"$/) { s = substr(s, 2, length(s) - 2) }
  return s
}
function flush() { if (n != "" && f != "") print n "\t" f; n = ""; f = "" }
/^[A-Za-z]/ { flush(); insec = ($0 ~ /^proxy-groups:/); next }
!insec { next }
/^- / { flush() }
/^- name:/   { v = $0; sub(/^- name:[ \t]*/, "", v);   n = unq(v); next }
/^  name:/   { v = $0; sub(/^  name:[ \t]*/, "", v);   n = unq(v); next }
/^  filter:/ { v = $0; sub(/^  filter:[ \t]*/, "", v); f = unq(v); next }
END { flush() }
AWK
awk -f "$TMP/pairs.awk" "$TMP/server.yaml" | awk -F'\t' -v ex="$EXCLUDE" '$1 !~ ex' > "$TMP/pairs.tsv"
[ -s "$TMP/pairs.tsv" ] || { echo "В подписке не нашлось балансировщиков, конфиг не тронут." >&2; exit 1; }

# ---------- 3. блоки для вставки ----------
awk -F'\t' -v q="'" '{
  printf "  - name: \"%s\"\n    type: load-balance\n    strategy: consistent-hashing\n    filter: %s%s%s\n    use: [proxy-sub]\n    url: https://cp.cloudflare.com/generate_204\n    interval: 300\n\n", $1, q, $2, q
}' "$TMP/pairs.tsv" > "$TMP/bal.yml"
awk -F'\t' '{ printf "\"%s\"\n", $1 }' "$TMP/pairs.tsv" > "$TMP/names.txt"
printf '%s/mihomo/proxies\n' "$SUB_URL" > "$TMP/proxies_url"

# ---------- 4. подставляем в шаблон ----------
# secret и url читаются из файлов, а не через -v: так не ломаются спецсимволы
awk -v bal="$TMP/bal.yml" -v names="$TMP/names.txt" -v secf="$SECRET_FILE" -v urlf="$TMP/proxies_url" -v q="'" '
BEGIN {
  getline sec  < secf; close(secf); gsub(/\r/, "", sec);  gsub(q, q q, sec)
  getline purl < urlf; close(urlf); gsub(/\r/, "", purl); gsub(q, q q, purl)
}
/#@@SECRET@@/      { print "secret: " q sec q; next }
/#@@PROXIES_URL@@/ { ind = $0; sub(/#@@PROXIES_URL@@.*/, "", ind); print ind "url: " q purl q; next }
/#@@BALANCERS@@/   { while ((getline l < bal) > 0) print l; close(bal); next }
/#@@NAMES@@/       { ind = $0; sub(/#@@NAMES@@.*/, "", ind); while ((getline l < names) > 0) print ind "- " l; close(names); next }
{ print }
' "$TPL" > "$TMP/new.yaml"

grep -q '#@@' "$TMP/new.yaml" && { echo "В шаблоне остался неподставленный плейсхолдер" >&2; exit 1; }

# ---------- 5. ничего не изменилось ----------
cmp -s "$TMP/new.yaml" "$CFG" && { echo "Конфиг актуален, изменений нет."; exit 0; }

# ---------- 6. проверка и применение ----------
if command -v mihomo >/dev/null 2>&1; then
  mihomo -t -d "$DIR" -f "$TMP/new.yaml" > "$TMP/test.log" 2>&1 \
    || { cat "$TMP/test.log" >&2; echo "Проверка конфига не прошла, старый конфиг оставлен." >&2; exit 1; }
fi

[ -f "$CFG" ] && cp "$CFG" "$CFG.bak"
cp "$TMP/new.yaml" "$CFG" || exit 1
echo "Конфиг обновлён: балансировщиков $(wc -l < "$TMP/pairs.tsv")"
xkeen -restart
