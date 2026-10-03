# Проверки ключа без боевого конфига: probe (соединение) и check (разбор).

# Проверка ключа в изоляции: свой конфиг с временным socks-входом, боевой
# конфиг, nft и dnsmasq не трогаются -- можно на работающем роутере.
# PROBE_URL -- проверить через ноду конкретный сайт, а не только выход.
cmd_probe() {
    [ -x "$XRAY" ] ||
        dief "движка нет (%s) — ключ проверить нечем; сам ключ тут ни при чём" "$XRAY"
    # --all -- каждый ключ автовыбора отдельным процессом.
    if [ "${1:-}" = "--all" ]; then
        _keys=$(uci -q get byway.main.node_urls || true)
        [ -n "$_keys" ] || die "ключей автовыбора нет (byway.main.node_urls) — проверять нечего"
        _i=0; _okn=0
        for _k in $_keys; do
            _i=$((_i + 1))
            case "$_k" in *#*) _kl=$(pctd "${_k##*#}") ;; *) _kl="" ;; esac
            printf '\n'; sayf "ключ %s %s" "$_i" "$_kl"
            if "$0" probe "$_k"; then _okn=$((_okn + 1)); fi
        done
        printf '\n'; sayf "работают %s из %s" "$_okn" "$_i"
        return 0
    fi
    # Без аргумента в режиме «свой конфиг» проверяется он, как у check.
    if [ -z "${1:-}" ] && [ "$(u conn_mode)" = "outbound" ]; then
        parse_node
    else
        URL=${1:-$(u node_url)}
        [ -n "$URL" ] || die "ссылка не задана: передать аргументом либо записать в byway.main.node_url"
        parse_node "$URL"
    fi
    build_stream

    PORT=${PROBE_PORT:-15080}
    CFG=/tmp/byway-probe.json
    LOG=/tmp/byway-probe.log
    XP=""
    # Ловушка -- до записи конфига: выход по «отвергнут ядром» иначе оставил бы
    # файл с uuid в /tmp.
    # `|| true`: движок к выходу обычно уже убит, kill по нему отвечает 1, и под
    # set -e ловушка обрывалась с кодом 1 -- проверка рабочего ключа
    # заканчивалась неудачей.
    trap '[ -z "$XP" ] || kill $XP 2>/dev/null || true; : > "$CFG" 2>/dev/null; : > "$LOG" 2>/dev/null; : > /tmp/byway-probe.out 2>/dev/null' EXIT INT TERM
    umask 077
    cat > "$CFG" <<PROBE
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "tag": "s", "listen": "127.0.0.1", "port": $PORT,
                  "protocol": "socks", "settings": { "udp": true } } ],
  "outbounds": [ $(proxy_block) ]
}
PROBE

    printf '  %-12s %-22s ' "$N_TYPE/$N_SEC" "$N_HOST:$N_PORT"
    if ! "$XRAY" run -test -c "$CFG" >/dev/null 2>&1; then
        printf "$(_t 'конфиг отвергнут ядром\n')"
        _e=$("$XRAY" run -test -c "$CFG" 2>&1 || true)
        printf '%s\n' "$_e" | tail -2 | sed 's/^/      /'
        xray_hint "$_e"
        return 1
    fi
    "$XRAY" run -c "$CFG" > "$LOG" 2>&1 &
    XP=$!
    sleep 3
    # || R="": под set -e присваивание из неудачной подстановки молча убивает
    # скрипт (2026-09-03, novayagazeta.ru).
    R=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$PORT"         -w '%{http_code} %{time_total}' -o /tmp/byway-probe.out         "${PROBE_URL:-https://api.ipify.org}" 2>/dev/null) || R=""
    IP=$(cat /tmp/byway-probe.out 2>/dev/null | head -c 40)
    kill $XP 2>/dev/null || true
    wait $XP 2>/dev/null || true
    CODE=${R%% *}; TIME=${R##* }
    # Любой трёхзначный код -- связь состоялась (302, 403 Cloudflare без
    # браузерного UA): успех проверки ноды.
    case "$CODE" in [1-5][0-9][0-9]) OKC=1 ;; *) OKC=0 ;; esac
    if [ "$OKC" = "1" ]; then
        printf "$(_t 'РАБОТАЕТ  выход %-16s %s с\n')" "$IP" "$TIME"
    else
        printf "$(_t 'НЕ РАБОТАЕТ (код %s)\n')" "${CODE:-$(_t 'нет ответа')}"
        grep -iE "fail|error|reject" "$LOG" | tail -2 | sed 's/^/      /'
    fi
    : > "$CFG"; : > "$LOG"; : > /tmp/byway-probe.out
    # Код возврата -- исход проверки: probe --all по нему считает «работают N
    # из M», а последняя команда выше успешна всегда.
    [ "$OKC" = "1" ]
}

# ── разбор ссылки без единого соединения ───────────────────────────────────
# Принимает ли Xray эту ссылку, без процесса и сокета (probe поднимает xray и
# ходит наружу). Перед переключением ноды.
cmd_check() {
    # Без движка проверять нечем -- говорим прямо: иначе любой верный ключ
    # объявлялся бы негодным, и меню не давало вписать ни одного.
    [ -x "$XRAY" ] ||
        dief "движка нет (%s) — ключ проверить нечем; сам ключ тут ни при чём" "$XRAY"
    # Ссылку передаём в разбор, только если дана аргументом: иначе разбор сам
    # выберет ключ из UCI или свой конфиг.
    if [ -n "${1:-}" ]; then parse_node "$1"; else parse_node; fi
    build_stream

    CFG=/tmp/byway-check.json
    trap ': > "$CFG" 2>/dev/null' EXIT INT TERM
    umask 077
    cat > "$CFG" <<CHK
{
  "log": { "loglevel": "warning" },
  "outbounds": [ $(proxy_block) ]
}
CHK
    printf '  %-12s %-10s %s:%s  ' "$N_TYPE" "$N_SEC" "$N_HOST" "$N_PORT"
    if "$XRAY" run -test -c "$CFG" >/dev/null 2>&1; then
        printf "$(_t 'ПРИНЯТ\n')"
        : > "$CFG"
        return 0
    fi
    printf "$(_t 'ОТВЕРГНУТ\n')"
    _e=$("$XRAY" run -test -c "$CFG" 2>&1 || true)
    printf '%s\n' "$_e" | tail -1 | sed 's/.*> /    /'
    xray_hint "$_e"
    : > "$CFG"
    return 1
}
