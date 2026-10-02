# Состояние: status (что поднято), health (связь через туннель),
# tunnel_ok и alive_ok -- для сторожа и замены ядра.

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

cmd_status() {
    printf "byway       %s\n" "$BYWAY_VERSION"
    if [ -f "$OUT" ]; then _cf=$(_f '%s байт' "$(wc -c < "$OUT")"); else _cf=$(_t НЕТ); fi
    printf "$(_t 'конфиг      %s\n')" "$_cf"
    status_urltest
    status_config
    status_block
    # Строки ВНИМАНИЕ панель не читает (overview.js берёт только известные
    # поля): они консольные, на панель не рассчитывать.
    #
    # --short: вкладки «Сеть» и «Основное» читают только голову. Остальное
    # (версия ядра, ps, nft, nslookup) -- 0.14 с из 0.36. Без флага вывод не
    # меняется: «Обслуживание» разбирает его целиком.
    if [ "${1:-}" = "--short" ]; then return 0; fi
    status_engine
    status_plumb
    # Новая версия -- после состояния, не вместо него. Канала извещений нет:
    # про ночное обновление видно только здесь и в системном журнале.
    if [ -s "$AULOG" ]; then
        printf "$(_t 'ночью      %s\n')" "$(cat "$AULOG")"
    fi
    if [ -s "$NEWVER" ]; then
        printf "$(_t 'обновление  %s доступно (у вас %s)\n')" "$(cat "$NEWVER")" "$BYWAY_NUM"
        _rn=$(cat "$RELNOTE" 2>/dev/null)
        [ -n "$_rn" ] && printf "            %s\n" "$_rn"
        printf "$(_t '            поставить: byway update\n')"
    fi
}

# Транспорт и ключ (при автовыборе -- число ключей и активный).
status_urltest() {
    # Транспорт -- из собранного конфига, не из ссылки (в ней uuid). При
    # автовыборе он не один: показывается число ключей.
    if [ "$(u conn_mode)" = "urltest" ] && [ -f "$OUT" ]; then
        # || true: grep -c при нуле совпадений возвращает 1, и под set -e
        # ветка умирала молча.
        _cnt=$(grep -c '"tag": "proxy-' "$OUT" || true)
        printf "$(_t 'подключение автовыбор из %s ключей\n')" "$_cnt"
        # Активный ключ виден только по обращениям, выбирает движок. Цифра в
        # шаблоне обязательна: со звёздочкой ловится «proxy-» из «tproxy-in».
        _act=$( { tail -200 "$ACCESS" 2>/dev/null || logread -e xray 2>/dev/null; } |
                grep -o 'proxy-[0-9][0-9]*' | tail -1 || true)
        [ -n "$_act" ] && printf "$(_t 'сейчас      %s\n')" "$_act"
    elif [ -f "$OUT" ]; then
        _net=$(grep -o '"network": "[a-z0-9]*"' "$OUT" | tail -1 | cut -d'"' -f4)
        _sec=$(grep -o '"security": "[a-z]*"' "$OUT" | tail -1 | cut -d'"' -f4)
        _mx=$(grep -o '"concurrency": [0-9]*' "$OUT" | head -1 | tr -d ' ' | cut -d: -f2)
        printf "$(_t "транспорт   %s / %s%s\n")" "${_net:-?}" "${_sec:-?}" "${_mx:+, mux=$_mx}"
        # Метка -- из ссылки: в конфиг Xray её не пишет.
        _url=$(u node_url)
        if [ -n "$_url" ]; then
            _lb=""
            case "$_url" in
              *#*) _lb=$(printf '%s' "${_url#*#}" | sed 's/%/\\x/g')
                   _lb=$(printf '%b' "$_lb" 2>/dev/null || true) ;;
            esac
            # Строка печатается всегда, когда ключ задан: панель судит по её
            # наличию. Адрес ноды не печатать -- вывод уходит в byway report.
            printf "$(_t "ключ        %s\n")" "${_lb:-$(_t 'без имени')}"
        elif [ "$(u conn_mode)" = "outbound" ]; then
            # Свой конфиг: ссылки нет, строка нужна по той же причине.
            _lb=$(u conn_label 2>/dev/null || true)
            printf "$(_t "ключ        %s\n")" "${_lb:-$(_t 'свой конфиг')}"
        fi
    fi
    return 0
}

# Конфиг собран под тот же режим (одна нода или несколько), что в настройке.
status_config() {
    # Режим меняют через uci без пересборки: остаток пробного автовыбора
    # переключал ноды и рвал соединения.
    if [ -f "$OUT" ]; then
        _np=$(grep -c '"tag": "proxy' "$OUT" || true)
        if [ "$(u conn_mode)" = "urltest" ]; then _want=много; else _want=один; fi
        if [ "${_np:-1}" -gt 1 ]; then _have=много; else _have=один; fi
        if [ "$_want" != "$_have" ]; then
            printf "$(_t "ВНИМАНИЕ    конфиг собран для другого режима, пересобрать: byway gen\n")"
        fi
    fi
    return 0
}

# Строка ВНИМАНИЕ, если включено «не пускать мимо VPN».
status_block() {
    # Запрет виден только по файлу в /tmp: health при нём зелёный (ходит через
    # локальный прокси мимо закрытого dnsmasq). Строка до --short: вкладки
    # читают только голову.
    if [ -f "$BLOCK_MARK" ]; then
        # Три вида запрета не смешивать: «закрыт весь трафик» и «закрывать
        # было нечего» -- противоположные состояния.
        case "$(cat "$BLOCK_MARK" 2>/dev/null || true)" in
          all)
            printf "$(_t "ВНИМАНИЕ    ВЕСЬ трафик мимо VPN ЗАКРЫТ: туннеля нет, так велит «не пускать мимо VPN»\n")" ;;
          none)
            printf "$(_t "ВНИМАНИЕ    «не пускать мимо VPN» включено, но закрывать было нечего — трафик идёт НАПРЯМУЮ\n")" ;;
          *)
            printf "$(_t "ВНИМАНИЕ    доступ к списку ЗАКРЫТ: туннеля нет, так велит «не пускать мимо VPN»\n")" ;;
        esac
    fi
    return 0
}

# Версия и путь ядра, pid, память под пределом, число своих направлений.
status_engine() {
    printf "$(_t "движок      %s\n")" "$("$XRAY" version 2>/dev/null | head -1 | cut -d' ' -f1-2) — $XRAY"
    if [ -f "$OUT" ] && grep -q '"network": "xhttp"' "$OUT" && eng_dial_bug "$XRAY"; then
        printf "$(_t 'xmux        не ограничивает соединения: ядро собрано на Go 1.27, см. byway doctor\n')"
    fi
    # Боевой процесс -- по пути к конфигу, не по имени бинарника: имя меняется,
    # когда рядом лежит версия вне фида (xray-26.7.11).
    _p=$(xray_pid)
    [ -n "$_p" ] && printf "$(_t 'xray        PID %s\n')" "$_p" || printf "$(_t 'xray        не запущен\n')"
    # Предел -- из окружения процесса, не из UCI: видно применённое, а не
    # записанное.
    if [ -n "$_p" ]; then
        _rss=$(awk '/^VmRSS:/ {printf "%d", $2/1024}' "/proc/$_p/status" 2>/dev/null || true)
        _lim=$(tr '\0' '\n' < "/proc/$_p/environ" 2>/dev/null | sed -n 's/^GOMEMLIMIT=//p' || true)
        printf "$(_t 'память      %s МБ, предел %s\n')" "${_rss:-?}" "${_lim:-$(_t 'не задан')}"
    fi
    _rn3=0
    for _r3 in $(route_names); do
        [ "$(uci -q get "byway.$_r3.enabled")" = "0" ] && continue
        _rn3=$((_rn3 + 1))
    done
    [ "$_rn3" -gt 0 ] && printf "$(_t 'направления %s со своим выходом\n')" "$_rn3"
    return 0
}

# Три опоры обвязки (nft, ip rule, маршрут), резолвер, fakeip, счётчик tproxy.
status_plumb() {
    # Точная форма: подстрока `inet byway` совпадала и с `inet byway_block`,
    # таблицей запрета, которую block_on ставит как раз без обвязки.
    printf "$(_t 'таблица nft %s\n')" "$(nft list table inet "$TABLE" >/dev/null 2>&1 && _t есть || _t НЕТ)"
    printf "$(_t 'ip rule     %s\n')" "$(ip rule show 2>/dev/null | grep -qE "$(rule_re)" && _t есть || _t НЕТ)"
    # Правило без маршрута: помеченный пакет уходит в main и наружу настоящим
    # адресом, а строки выше при этом говорят «есть».
    printf "$(_t 'маршрут     %s\n')" "$(ip route show table "$RT_TABLE" 2>/dev/null | grep -q '^local default' && _t есть || _t НЕТ)"
    printf "$(_t 'dnsmasq ->  %s\n')" "$(uci -q get "$DNSSEC.server" 2>/dev/null || _t провайдер)"
    if [ -n "$_p" ]; then
        # Домен -- из своего списка: чужой тестовый давал «не выдаётся» на
        # рабочем туннеле.
        _d=$(plain_domains "$(merged_domains)" | head -1)
        if [ -n "$_d" ]; then
            _r=$(nslookup "$_d" 127.0.0.1 2>/dev/null | awk '/^Address/{print $NF}' | grep -E "^$(fakeip_re)" | head -1)
            [ -n "$_r" ] && printf "$(_t 'fakeip      %s -> %s\n')" "$_d" "$_r" || printf "$(_t 'fakeip      НЕ выдаётся на %s\n')" "$_d"
        fi
        # Только правила tproxy: счётчики QUIC и закрытого порта перехвата
        # считали бы тот же пакет второй раз.
        _c=$(nft list table inet "$TABLE" 2>/dev/null | grep 'tproxy' | grep -oE "packets [0-9]+" | awk '{s+=$2} END{print s+0}')
        printf "$(_t "в tproxy    %s пакетов\n")" "$_c"
    fi
    return 0
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
