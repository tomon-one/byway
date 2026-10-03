# byway report: отчёт для обращения, адреса и имена вымараны, ключа нет.

# ── отчёт для обращения ────────────────────────────────────────────────────
# Ключи настроек в отчёте -- по белому списку: новая настройка с секретом по
# умолчанию закрыта. Про ключ узла печатается форма (схема, транспорт, защита),
# не значение.
REPORT_KEYS="enabled conn_mode list_mode ru_direct preset interface
             fakeip_pool dns_upstream dns_upstream2 dns_bootstrap dns_listen tproxy_port local_proxy_port
             redirect_port router_via_vpn mark self_mark log_level ipv6 fakeip6_pool
             show_usage mux_concurrency probe_interval guard block_quic allow_insecure
             lang xray_bin conn_label"

cmd_report() {
    _out=${1:-}
    if [ -n "$_out" ]; then
        path_ok "$_out" || dief "сюда писать нельзя: %s" "$_out"
        # Сразу под 600, не chmod после: существующий файл сохраняет прежние
        # права.
        ( umask 077; report_body > "$_out.new.$$" 2>&1 )
        mv "$_out.new.$$" "$_out"
        sayf "отчёт записан: %s" "$_out"
        say "  секреты убраны, но перед отправкой файл стоит просмотреть"
    else
        report_body
    fi
}

report_body() {
    _esc=$(printf '\033')   # для снятия цветов из вывода
    MERGED_R=$(merged_domains)

    # Обёртки: переводятся и заголовок, и подпись, а printf в busybox считает
    # байты -- колонку выравнивает _len.
    _r()  { printf '%s\n' "$(_t "$1")"; }
    _rv() { _rl=$(_t "$1"); _rp=$((16 - $(_len "$_rl"))); [ "$_rp" -lt 1 ] && _rp=1
            printf '%s%*s%s\n' "$_rl" "$_rp" "" "$2"; }

    _r "# byway report 1"
    printf '# %s: %s\n' "$(_t 'снято')" "$(date '+%Y-%m-%d %H:%M')"
    _r "# ключ от VPN, адрес сервера и адрес подписки сюда НЕ попадают"
    echo
    _r "== устройство =="
    _rv "byway" "$BYWAY_VERSION"
    _fw=$(sed -n 's/^DISTRIB_DESCRIPTION=//p' /etc/openwrt_release 2>/dev/null | tr -d "'")
    _rv "прошивка" "${_fw:-?}"
    _model=$(cat /tmp/sysinfo/model 2>/dev/null || tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)
    _rv "железо" "${_model:-?} ($(uname -m))"
    _rv "ядро" "$(uname -r)"
    _rv "флеш" "$(df -h /overlay 2>/dev/null | awk 'NR==2{print $4" / "$2}')"
    _rv "память" "$(free 2>/dev/null | awk '/^Mem/{print int($4/1024)" / "int($2/1024)" MB"}')"
    echo
    _r "== окружение =="
    cmd_doctor 2>&1 | sed "s/$_esc\[[0-9;]*m//g" || true
    echo
    _r "== состояние =="
    cmd_status 2>&1 | sed "s/$_esc\[[0-9;]*m//g" || true
    echo
    _r "== проверка =="
    cmd_health 2>&1 || true
    echo
    _r "== подключение (без значений) =="
    # В автовыборе разбирается первый ключ списка, а не node_url (его там нет).
    _rk=""
    case "$(u conn_mode)" in
      urltest|selector) _rk=$(u node_urls | awk '{ print $1; exit }') ;;
    esac
    if ( parse_node $_rk >/dev/null 2>&1 ); then
        parse_node $_rk >/dev/null 2>&1 || true
        _rv "протокол" "$N_PROTO"
        _rv "транспорт" "$N_TYPE"
        _rv "защита" "$N_SEC"
        [ -n "${N_FLOW:-}" ] && _rv "flow" "$N_FLOW"
        _rv "порт" "$N_PORT"
    else
        _r "ключ не разбирается -- это и есть повод для обращения"
    fi
    echo
    _r "== настройки =="
    uci -q show byway 2>/dev/null | while IFS= read -r _ln; do
        _k=${_ln%%=*}; _k=${_k##*.}
        # Объявление секции -- тип, не значение.
        case "$_ln" in byway.main=byway) printf '%s\n' "$_ln"; continue ;; esac
        if in_set "$_k" "$REPORT_KEYS"; then
            printf '%s\n' "$_ln"
        else
            _f '%s=<скрыто>\n' "${_ln%%=*}"
        fi
    done
    echo
    _r "== списки =="
    _rv "своих доменов" "$(count_list "$LISTS/domains.lst")"
    _rv "всего доменов" "$(count_list "$MERGED_R")"
    _rv "своих подсетей" "$(count_list "$LISTS/subnets.lst")"
    _rv "всего подсетей" "$(count_list "$(merged_subnets)")"
    _rv "пресеты" "$(u preset)"
    _rv "отброшено строк" "$(sort -u "$BADLIST" 2>/dev/null | grep -c . || true)"
    echo
    _r "== перехват =="
    # Элементы наборов не печатаем: сотни строк подсетей, для разбора лишнее.
    nft list table inet "$TABLE" 2>/dev/null |
      grep -vE '^[[:space:]]*(elements|[0-9]+\.[0-9]+)' || _r "таблицы нет"
    echo
    ip rule show 2>/dev/null | grep -E "$(rule_re)" || _r "правила ip rule нет"
    ip route show table "$RT_TABLE" 2>/dev/null || true
    echo
    _r "== журнал состояния (последние 20) =="
    tail -20 "$WATCH_LOG" 2>/dev/null || _r "пусто"
    echo
    _r "== системный журнал byway (последние 30) =="
    # Те же вымарки, что у журнала движка: watch пишет сюда имя и адрес сервера.
    # Строки crond о задачах byway (pulse раз в минуту) вытесняли бы сообщения
    # самой программы.
    logread -e byway 2>/dev/null | grep -v ' cron\.[a-z]* crond\[' | tail -30 |
      sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/x.x.x.x/g
              s/([A-Za-z0-9-]+\.)+[A-Za-z]{2,}/'"$(_t ИМЯ | sed 's/[\/&]/\\&/g')"'/g' || true
    echo
    _r "== системный журнал движка (последние 20) =="
    # Только жалобы движка: в строках обращений адрес каждого сайта, а отчёт
    # уходит постороннему. Адреса и имена вымарываются (в «dial tcp …» -- адрес
    # сервера).
    logread -e xray 2>/dev/null | grep -iE "error|warn|fail|reject" |
      grep -v "tproxy-in" | tail -20 |
      sed -E 's/^([A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]+ [0-9:]+ [0-9]{4}) [^:]*: /\1 /
              s/[0-9]{1,3}(\.[0-9]{1,3}){3}/x.x.x.x/g
              s/\[[0-9a-fA-F]*:[0-9a-fA-F:]*\]|[0-9a-fA-F]*::[0-9a-fA-F:]+/x::x/g
              s/([A-Za-z0-9-]+\.)+[A-Za-z]{2,}/'"$(_t ИМЯ | sed 's/[\/&]/\\&/g')"'/g' || true
}
