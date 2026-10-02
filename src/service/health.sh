# byway health и проверки связи для сторожа и замены ядра.

# Связь через сервер: запрос через прокси-вход к PROBE_DOMAIN. alive_ok сервера
# не видит, и ядро, которое встало, но не договаривается с сервером, её
# проходило.
tunnel_ok() {
    _tl=$(u local_proxy_port); _tl=${_tl:-1603}
    _tc=$(curl -s -o /dev/null --max-time 8 -w '%{http_code}' \
          --proxy "http://127.0.0.1:$_tl" "https://$PROBE_DOMAIN/" 2>/dev/null || true)
    [ "${_tc:-000}" != "000" ]
}

# Движок жив, обвязка на месте, резолвер отдаёт fakeip. По ней автооткат
# обновления судит об удаче: канала извещений нет.
alive_ok() {
    [ -n "$(xray_pid)" ] || return 1
    nft list table inet "$TABLE" >/dev/null 2>&1 || return 1
    # Проба по объединённому списку: у роутера с одними пресетами свой файл
    # пуст, и проба по нему не проверяла ничего.
    _ad=$(plain_domains "$(merged_domains)" | head -1)
    # Пустой список -- не поломка, проверять нечем.
    [ -n "$_ad" ] || return 0
    nslookup "$_ad" 127.0.0.1 2>/dev/null | awk '/^Address/{print $NF}' |
        grep -qE "^$(fakeip_re)"
}

# ── короткая проверка для панели ───────────────────────────────────────────
# Формат «ключ<таб>состояние<таб>подробность», состояния ok/warn/fail: панель
# красит, не разбирая текст.
cmd_health() {
    _l=$(dns_addr)
    _lp=$(u local_proxy_port); _lp=${_lp:-1603}

    # 1. Служба
    _pid=$(xray_pid)
    if [ -n "$_pid" ]; then
        # Молодой процесс -- warn, не отказ: Xray поднимается ~15 с. Возраста
        # мало: procd перезапускает движок через 5 с без предела попыток, и у
        # вечно падающего он не старше 25 с.
        # Отличает слепок applied: service_started пишет его раз за запуск.
        # Процесс молод, слепок стар -- круг падений, это отказ.
        if [ "$(_proc_age "$_pid")" -lt 25 ] &&
           [ -n "$(find /var/run/byway.applied -mmin -1 2>/dev/null)" ]; then
            _young=1
            printf "$(_t 'service\twarn\tзапускается\n')"
        else
            _young=0
            printf "$(_t 'service\tok\tработает\n')"
        fi
    else
        printf "$(_t 'service\tfail\tне запущена\n')"
        printf "$(_t 'vpn\tfail\tпроверять нечем\n')"
        printf "$(_t 'tunnel\tfail\tпроверять нечем\n')"
        printf "$(_t 'dns\tfail\tпроверять нечем\n')"
        return 0
    fi

    # 2. Доступность VPN: время TCP-connect до адреса ноды (ICMP может быть
    #    закрыт). parse_node при плохой ссылке зовёт die -> exit, поэтому в
    #    подоболочке. При автовыборе ссылка -- из node_urls: node_url этот
    #    режим не заполняет.
    _hk=""
    [ "$(u conn_mode)" = "urltest" ] &&
        _hk=$(uci -q get byway.main.node_urls 2>/dev/null | awk '{print $1}')
    if ! ( parse_node ${_hk:+"$_hk"} >/dev/null 2>&1 ); then
        printf "$(_t 'vpn\tfail\tссылка не разобрана\n')"
        printf "$(_t 'tunnel\tfail\tпроверять нечем\n')"
        printf "$(_t 'dns\tfail\tпроверять нечем\n')"
        return 0
    fi
    parse_node ${_hk:+"$_hk"} >/dev/null 2>&1 || true
    # Свой конфиг: адреса ноды у byway нет, мерить нечего.
    if [ "$N_PROTO" = "raw" ]; then
        printf "$(_t 'vpn\twarn\tсвой конфиг: адрес сервера неизвестен\n')"
        _ms=-1
    fi
    # Две попытки: одиночный замер изредка не укладывается в таймаут.
    [ "${_ms:-0}" = "-1" ] || _ms=0
    for _try in 1 2; do
        [ "$_ms" = "-1" ] && break
        # --max-time обязателен: рукопожатие проходит, HTTP-ответа нет, и curl
        # висел бесконечно. Панель обрывает запрос на ~20 с, шаги 2-4 должны
        # в них уложиться.
        _t=$(curl -s -o /dev/null --connect-timeout 3 --max-time 4 -w '%{time_connect}' \
             "http://$N_HOST:$N_PORT" 2>/dev/null || true)
        _ms=$(awk -v v="${_t:-0}" 'BEGIN{printf "%d", v*1000}')
        [ "${_ms:-0}" -gt 0 ] && break
        [ "$_try" = 1 ] && sleep 1
    done
    if [ "${_ms:-0}" = "-1" ]; then
        :   # своё сообщение уже напечатано выше
    elif [ "${_ms:-0}" -gt 0 ]; then
        if [ "$_ms" -lt 400 ]; then printf "$(_t 'vpn\tok\t%s мс\n')" "$_ms"
        else printf "$(_t 'vpn\twarn\t%s мс, медленно\n')" "$_ms"; fi
    else
        _hfail vpn "$(_t 'не отвечает')"
    fi

    # 3. Трафик насквозь: через локальный прокси на PROBE_DOMAIN, который
    #    byway сам заворачивает в туннель. Не первый домен списка: им был
    #    1drv.com без веб-сервера на корне, ответ 000 при живом туннеле.
    _d=$PROBE_DOMAIN
    if [ -n "$_d" ]; then
        # Потолок 5, а не 8: бюджет шагов 2-4 (см. --max-time выше).
        _c=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' \
             --proxy "http://127.0.0.1:$_lp" "https://$_d/" 2>/dev/null || true)
        case "${_c:-000}" in
          000) _hfail tunnel "$(_t 'трафик не проходит')" ;;
          *)   printf "$(_t 'tunnel\tok\tтрафик проходит\n')" ;;
        esac
    else
        printf "$(_t 'tunnel\twarn\tсписок пуст\n')"
    fi

    # 4. Резолвер: домен списка обязан получить fakeip. Попыток две: кэш
    #    dnsmasq выключен, каждый резолв идёт полным путём (Xray, DoH), и
    #    замедление канала давало красное на исправном туннеле.
    if [ -n "$_d" ]; then
        _a=""
        for _try in 1 2; do
            _a=$(nslookup "$_d" 127.0.0.1 2>/dev/null |
                 sed -n 's/^Address: *//p' | grep -E "^$(fakeip_re)" | head -1)
            [ -n "$_a" ] && break
            [ "$_try" = 1 ] && sleep 1
        done
        if [ -n "$_a" ]; then printf "$(_t 'dns\tok\tотвечает\n')"
        else _hfail dns "$(_t 'не выдаёт адрес')"; fi
    fi
}

# Неудача при только что запущенной службе -- warn, не fail.
_hfail() {
    if [ "${_young:-0}" = "1" ]; then
        printf '%s\twarn\t%s\n' "$1" "$(_t 'ещё запускается')"
    else
        printf '%s\tfail\t%s\n' "$1" "$(_t "$2")"
    fi
}

# Возраст процесса в секундах: busybox ps не печатает etime. starttime из
# /proc/PID/stat против /proc/uptime; всё до «) » отрезается -- имя команды
# в скобках может содержать пробелы.
_proc_age() {
    _pu=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
    _ps=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}')
    if [ -z "$_pu" ] || [ -z "$_ps" ]; then echo 999999; return 0; fi
    echo $(( _pu - _ps / 100 ))
}
