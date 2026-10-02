# Проверка окружения (doctor, разделы doctor_*) и отчёт для обращения
# (report: адреса и имена вымараны, ключа нет).

# ── отчёт для обращения ────────────────────────────────────────────────────
# Ключи настроек в отчёте -- по белому списку: новая настройка с секретом по
# умолчанию закрыта. Про ключ узла печатается форма (схема, транспорт, защита),
# не значение.
REPORT_KEYS="enabled conn_mode list_mode ru_direct preset interface
             fakeip_pool dns_upstream dns_upstream2 dns_bootstrap dns_listen tproxy_port local_proxy_port
             redirect_port router_via_vpn mark self_mark log_level ipv6 fakeip6_pool
             show_usage mux_concurrency probe_interval guard block_quic allow_insecure
             lang xray_bin conn_label"

_d_ok()   { printf '  [ ok ] %s\n' "$(_t "$1")"; }

_d_bad()  { printf '  [ !! ] %s\n' "$(_t "$1")"; [ -n "${2:-}" ] && printf '         %s\n' "$(_t "$2")"; DOCTOR_BAD=$((DOCTOR_BAD + 1)); }

_d_warn() { printf '  [ ?? ] %s\n' "$(_t "$1")"; [ -n "${2:-}" ] && printf '         %s\n' "$(_t "$2")"; }

cmd_doctor() {
    DOCTOR_BAD=0
    printf "$(_t 'byway %s — проверка окружения\n\n')" "$BYWAY_VERSION"
    doctor_system
    doctor_needs
    doctor_updates
    doctor_config
    doctor_dns
    doctor_marks
    doctor_files
    doctor_rivals
    doctor_ports

    printf '\n'
    if [ "$DOCTOR_BAD" -eq 0 ]; then
        say "окружение в порядке"
    else
        warnf "неисправностей: %s — способ лечения указан у каждой" "$DOCTOR_BAD"
        return 1
    fi
}

# ОС, архитектура, свободное место на флеше.
doctor_system() {
    printf "$(_t 'Система\n')"
    if [ -f /etc/openwrt_release ]; then
        _ver=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release)
        _d_ok "$(_f 'OpenWrt: %s' "$_ver")"
    else
        _d_warn "не OpenWrt" "byway рассчитан на OpenWrt, на другом может не работать"
    fi
    _d_ok "$(_f 'архитектура: %s' "$(uname -m)")"
    # Отдельного /overlay может не быть (ram-профили, чистый ext4): df молчит,
    # берётся корень, иначе ложная нехватка места.
    _mnt=/overlay; [ -d /overlay ] || _mnt=/
    _free=$(df -k "$_mnt" 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    [ -n "$_free" ] || _free=$(df -k / 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    if [ "${_free:-0}" -lt 2 ]; then
        _d_bad "$(_f 'свободно на флеше: %s МБ' "${_free}")" "меньше двух мегабайт: списки и конфиг могут не записаться"
    else
        _d_ok "$(_f 'свободно на флеше: %s МБ' "${_free}")"
    fi
    return 0
}

# Включён ли byway, автозапуск, cron, модули ядра, firewall4, Xray, утилиты.
doctor_needs() {
    printf "$(_t '\nЧего требует byway\n')"
    # Включён ли byway и работает ли движок: без этого отчёт на выключенном
    # byway выходил зелёным.
    if [ "$(u enabled)" = "1" ]; then
        if [ -n "$(xray_pid)" ]; then
            _d_ok "$(_t 'byway включён, движок работает')"
        else
            _d_bad "$(_t 'byway включён, но движок не работает')" \
                   "движок не запущен или упал: /etc/init.d/byway restart, затем byway status и logread -e xray"
        fi
    else
        _d_warn "$(_t 'byway выключен настройкой')" \
                "включить: uci set byway.main.enabled=1 && uci commit byway && /etc/init.d/byway restart"
    fi

    # Автозапуск отдельно от enabled: настройка решает, поднимать ли туннель
    # сейчас, rc.d-ссылка -- переживёт ли он перезагрузку. Файл службы
    # проверяется отдельно: `init.d/X enabled` одинаково отвечает отказом на
    # «выключено» и «нет файла».
    if [ ! -x /etc/init.d/byway ]; then
        _d_bad "$(_t 'файла службы нет')" \
               "byway не поднимется ни сейчас, ни после перезагрузки: поставить заново"
    elif /etc/init.d/byway enabled 2>/dev/null; then
        _d_ok "$(_t 'служба в автозапуске')"
    else
        _d_bad "$(_t 'служба НЕ в автозапуске')" \
               "сейчас работает, но после перезагрузки туннеля не будет: /etc/init.d/byway enable"
    fi

    # Задачи cron: сторож обвязки, учёт, обрезка журналов. Если они потеряны
    # при переносе crontab или crond не стартует (при пустом /etc/crontabs),
    # всё молча не работает.
    _cw=$(crontab -l 2>/dev/null | grep -c "byway watch" || true); _cw=${_cw:-0}
    _cs=$(crontab -l 2>/dev/null | grep -c "byway stat" || true); _cs=${_cs:-0}
    if [ "$_cw" -gt 0 ] && [ "$_cs" -gt 0 ]; then
        if pidof crond >/dev/null 2>&1; then
            _d_ok "$(_t 'задачи cron на месте, crond работает')"
        else
            _d_bad "$(_t 'задачи cron есть, но crond не работает')" \
                   "без него не работают ни проверка перехвата раз в 5 минут (byway watch), ни учёт трафика (byway stat), ни обрезка журналов: /etc/init.d/cron enable && /etc/init.d/cron start"
        fi
    else
        _d_bad "$(_f 'в cron не хватает задач byway (watch: %s, stat: %s)' "$_cw" "$_cs")" \
               "переустановить byway либо завести вручную: */5 * * * * /usr/local/bin/byway watch и 7 * * * * /usr/local/bin/byway stat"
    fi
    for _m in nft_tproxy nft_socket; do
        # lsmod не показывает модули, встроенные в ядро: смотреть ещё
        # /sys/module/<имя>.
        if lsmod 2>/dev/null | grep -q "^$_m " || [ -d "/sys/module/$_m" ]; then
            _d_ok "$(_f 'модуль %s' "$_m")"
        else
            _d_bad "$(_f 'нет модуля %s' "$_m")" "$PKG_FIX kmod-nft-tproxy kmod-nft-socket"
        fi
    done
    if command -v fw4 >/dev/null 2>&1; then
        _d_ok "$(_t 'файрвол firewall4')"
    else
        _d_bad "$(_t 'firewall4 не найден — вероятно firewall3, 21.02 и старше')" \
               "byway работает только на firewall4, это OpenWrt 22.03 и новее — на firewall3 правило по метке не встанет"
    fi
    if [ -x "$XRAY" ]; then
        _xv=$("$XRAY" version 2>/dev/null | head -1 | cut -d' ' -f1-2)
        _d_ok "$(_f 'движок: %s (%s)' "$_xv" "$XRAY")"
        if [ -f "$OUT" ] && grep -q '"network": "xhttp"' "$OUT" && eng_dial_bug "$XRAY"; then
            _d_warn "$(_t 'xmux не ограничивает соединения: ядро собрано на Go 1.27')" \
                    "при сбое сервера xhttp открывает сотни соединений: память роутера, риск блокировки адреса. Ядро с -tags http2legacy: docs/engine.md, «Ядро на Go 1.27»"
        fi
    else
        _d_bad "$(_f 'не найден Xray-core (%s)' "$XRAY")" "$(_f '%s xray-core либо задать byway.main.xray_bin' "$PKG_FIX")"
    fi
    for _c in curl nft ip uci; do
        command -v "$_c" >/dev/null 2>&1 && _d_ok "$(_f 'есть %s' "$_c")" ||
            _d_bad "$(_f 'нет %s' "$_c")" "$PKG_FIX $_c"
    done
    # base64 нужен только для vmess и ss, не ошибка. Проверка запуском:
    # /bin/base64 бывает ссылкой на busybox без апплета.
    if have_base64; then
        _d_ok "есть base64 (нужен для ключей vmess и ss)"
    else
        _d_warn "нет base64" "$(_f 'ключи vmess и ss разобрать не выйдет: %s' "$PKG_FIX coreutils-base64")"
    fi
    return 0
}

# Есть ли новая версия, сработает ли автообновление, часовой пояс окна.
doctor_updates() {
    printf "$(_t '\nОбновления\n')"
    # Раздел не выходит пустым заголовком: пустота читается как «проверка не
    # прошла».
    if [ ! -s "$NEWVER" ]; then
        if [ "$(u update_check)" = "0" ]; then
            _d_ok "$(_t 'проверка новых версий выключена')"
        else
            _d_ok "$(_f 'новее %s не найдено' "$BYWAY_NUM")"
        fi
    fi
    if [ -s "$NEWVER" ]; then
        # Важность выпуска -- первым словом описания: красная строка вместо
        # жёлтой.
        case "$(cat "$RELNOTE" 2>/dev/null)" in
          ВАЖНО*|CRITICAL*|!*)
            _d_bad "$(_f 'важное обновление: %s' "$(cat "$NEWVER")")" \
                   "$(cat "$RELNOTE" 2>/dev/null) -- $(_t 'поставить: byway update')" ;;
          *)
            _d_warn "$(_f 'есть новая версия: %s' "$(cat "$NEWVER")")" \
                    "$(cat "$RELNOTE" 2>/dev/null) -- $(_t 'поставить: byway update')" ;;
        esac
    fi
    # Автообновление работает только при сумме от установщика: у ручной копии
    # или своей сборки оно пропускается намеренно (архив перетёр бы чужую
    # правку). Сумму byway себе не пишет: проверка потеряла бы смысл.
    if [ "$(u auto_update)" = "1" ]; then
        if [ ! -f "$BINSUM" ]; then
            _d_warn "$(_t 'автообновление включено, но происхождение файла неизвестно')" \
                    "byway положен не установщиком -- обновление пропускается. Лечится запуском install.sh из поставки"
        elif [ "$(md5sum /usr/local/bin/byway 2>/dev/null | cut -d" " -f1)" != "$(cat "$BINSUM")" ]; then
            _d_warn "$(_t 'автообновление включено, но byway правлен руками')" \
                    "своя правка не будет перетёрта: обновление пропускается намеренно"
        else
            _d_ok "$(_t 'автообновление включено')"
        fi
        # update_check -- независимый тумблер: без суточной проверки NEWVER не
        # пишется, и ставить нечего.
        if [ "$(u update_check)" = "0" ]; then
            _d_warn "автообновление включено, но суточная проверка версий выключена" \
                    "без проверки версий автообновлению нечего ставить — включить: uci set byway.main.update_check=1 && uci commit byway"
        fi
        # Окно берётся по местному времени (date +%H), а OpenWrt по умолчанию в
        # UTC: «04:00» выходит днём (Москва 07:00, Владивосток 14:00). Окно на
        # UTC не переводится -- хуже тем, у кого пояс верный; только
        # предупреждение.
        _tzn=$(uci -q get system.@system[0].zonename 2>/dev/null || true)
        _tzo=$(uci -q get system.@system[0].timezone 2>/dev/null || true)
        _auhd=$(au_hour)
        # Судим по timezone, не по zonename: часы двигает только POSIX-TZ в
        # timezone, а zonename без zoneinfo в образе ничего не меняет.
        # Печатается фактическое смещение.
        case "${_tzo:-UTC}" in
          UTC|""|GMT0|GMT)
            _d_warn "$(_f 'часы роутера идут по UTC (timezone=%s) — окно обновления придётся на %s:00 UTC' "${_tzo:-$(_t 'не задан')}" "$_auhd")" \
                    "у вас это не ночь: в Москве это на три часа позже, во Владивостоке на десять — перезапуск службы среди дня. Лечится в LuCI (Система → Общие настройки → Часовой пояс) либо uci set system.@system[0].timezone=... (именно timezone: zonename часы не двигает)" ;;
          *)
            _d_ok "$(_f 'часы %s (%s, смещение %s), обновление в %s:00 по часам роутера — сейчас %s' \
                       "${_tzn:-$(_t 'без ярлыка')}" "$_tzo" "$(date '+%z' 2>/dev/null || echo '?')" \
                       "$_auhd" "$(date '+%H:%M')")" ;;
        esac
        # Отметка о провалившемся выпуске: причину могли устранить, а этот
        # номер больше не ставится никогда -- человек должен знать.
        _aufv=$(cat "$AUFAIL" 2>/dev/null || true)
        if [ -n "$_aufv" ]; then
            _d_warn "$(_f 'выпуск %s не поднялся и больше не ставится сам' "$_aufv")" \
                    "если причина устранена — поставить вручную: byway update --force"
        fi
    fi
    return 0
}

# Конфигурация, ключ(и), списки, ширина подсетей, пины, IPv6, метки.
doctor_config() {
    printf "$(_t '\nНастройка\n')"
    if [ -f "$CONF" ]; then _d_ok "$(_f 'конфигурация %s' "$CONF")"; else
        _d_bad "$(_f 'нет %s' "$CONF")" "переустановить byway"; fi
    # По режиму, не по node_url: автовыбор читает node_urls, и на рабочем
    # автовыборе doctor советовал вписать ключ в поле, которое режим не читает.
    case "$(u conn_mode)" in
      urltest)
        _kn=$(uci -q get byway.main.node_urls 2>/dev/null | wc -w)
        if [ "${_kn:-0}" -gt 0 ]; then
            _d_ok "$(_f 'ключей для автовыбора: %s' "$_kn")"
        else
            _d_bad "ключи для автовыбора не заданы" "добавить на вкладке «Основное» либо: uci add_list byway.main.node_urls=vless://…"
        fi ;;
      outbound)
        if [ -n "$(u outbound_json)" ]; then
            _d_ok "свой конфиг аутбаунда задан"
        else
            _d_bad "выбран свой конфиг, но он пуст" "вписать кусок JSON на вкладке «Основное»"
        fi ;;
      *)
        case "$(u node_url)" in
          "")            _d_bad "ключ не задан" "вписать на вкладке «Основное» или: uci set byway.main.node_url=vless://…" ;;
          ЗАПОЛНИТЬ*)    _d_bad "ключ не заполнен" "вписать настоящий ключ вместо заглушки" ;;
          *)             _d_ok "$(_f 'ключ задан, режим: %s' "$(u conn_mode)")" ;;
        esac ;;
    esac
    # По объединённому списку (свой, направления, пресеты): по своему файлу
    # пустой список объявлялся и тем, у кого работает пресет.
    _dmerged=$(merged_domains)
    if [ -s "$_dmerged" ]; then
        _dn=$(count_list "$_dmerged")
        _dnown=$(count_list "$LISTS/domains.lst")
        _d_ok "$(_f 'список доменов: %s записей (своих %s)' "$_dn" "${_dnown:-0}")"
    elif [ "$(u list_mode)" = "all" ]; then
        _d_ok "списки не нужны: режим «всё через VPN»"
    else
        _d_warn "список доменов пуст" "через VPN не пойдёт ничего: наполнить или включить пресет"
    fi
    # Ширина подсетей: одна 0.0.0.0/0 молча делает режим «по спискам» полным
    # туннелем, а status и health считают записи, не адреса.
    _sw=$(net_width "$(merged_subnets)")
    _swt=${_sw%% *}; _swb=${_sw##* }
    if [ "${_swt:-0}" -gt 1000000 ] || [ "${_swb:-32}" -le 12 ]; then
        _d_warn "$(_f 'подсети списка: %s адресов, крупнейший блок /%s' "$_swt" "$_swb")" \
                "в туннель уйдёт и чужой трафик, и скорость упадёт: проверить subnets.lst"
    fi
    # Пины /etc/hosts против списка: их ставят и Zapret-Manager, и руками.
    _pin=$(hosts_vs_domains "$_dmerged")
    if [ "${_pin:-0}" -gt 0 ]; then
        _d_warn "$(_f 'пинов в /etc/hosts перебивают записи списка: %s' "$_pin")" \
                "dnsmasq отвечает по пину сам, подставного адреса не будет — эти домены в туннель не пойдут, и запрет «не пускать мимо VPN» их тоже не закроет"
    fi
    # byway держит «всё через VPN» только по IPv4 (`tproxy ip to`): пакет IPv6
    # проходит нетронутым, а клиент по RFC 6724 предпочитает AAAA.
    # Предупреждение нужно и в режиме по спискам: подсети и домены там тоже
    # только IPv4.
    if ip -6 route show default 2>/dev/null | grep -q .; then
        if v6on; then
            # Настройка и правила расходятся молча: правила перекладываются
            # только при подъёме.
            if ip -6 rule show 2>/dev/null | grep -qE "$(rule_re)"; then
                _d_ok "$(_t 'IPv6 поднят и заворачивается наравне с IPv4')"
            else
                _d_bad "$(_t 'IPv6 включён в настройках, но правила для него в ядре нет')" \
                       "переложить правила: byway plumb off && byway plumb on"
            fi
        elif [ "$(u list_mode)" = "all" ]; then
            _d_warn "IPv6 поднят, а перехват только по IPv4" "в режиме «всё через VPN» соединения по IPv6 идут мимо туннеля: выключить IPv6 на WAN либо вернуться к режиму по спискам"
        else
            _d_warn "IPv6 поднят, а перехват только по IPv4" "и домены, и подсети закрывают только IPv4: клиент, получивший AAAA, предпочтёт его и уйдёт напрямую. Выключить IPv6 на WAN -- либо помнить, что подсети сервиса его не покрывают"
        fi
    fi

    # Биты self_mark и mark не должны пересекаться: ip rule ставится с маской,
    # и пакеты движка уйдут в таблицу 100 на петлю при зелёных проверках.
    # self_mark сам берёт другое значение; здесь повтор.
    if [ "$(u router_via_vpn)" = "1" ]; then
        _dsm=$(u self_mark); _dsm=${_dsm:-0x400000}
        _dmk=$(u mark); _dmk=${_dmk:-0x100000}
        case "$_dsm$_dmk" in
          *[!0-9a-fA-FxX]*) ;;
          *) [ "$(( _dsm & _dmk ))" -ne 0 ] &&
               _d_warn "$(_f 'self_mark %s пересекается битами с mark %s' "$_dsm" "$_dmk")" \
                       "byway возьмёт другое значение сам; задать своё: uci set byway.main.self_mark=0x400000" ;;
        esac
    fi
    return 0
}

# dnsmasq на byway, сети вне перехвата, клиенты со своим DNS.
doctor_dns() {
    printf "$(_t '\nПерехват и соседние службы\n')"
    # Вхождением, не равенством: `uci get` списка отдаёт все значения через
    # пробел (так же в стороже).
    case " $(uci -q get "$DNSSEC.server" 2>/dev/null) " in
      *" $(dns_addr) "*) _d_ok "dnsmasq направлен на byway" ;;
      *)
        # На свежей установке движка нет, dnsmasq трогать не надо, а `plumb on`
        # упадёт.
        if [ "$(u enabled)" != "1" ] || [ -z "$(xray_pid)" ]; then
            _d_ok "$(_t 'dnsmasq не тронут — byway ещё не запущен, так и должно быть')"
        else
            _d_warn "dnsmasq не направлен на byway" "правила перехвата сняты: byway plumb on"
        fi ;;
    esac
    # dnsmasq один на все мосты, перехват -- только на перечисленных: сеть вне
    # списка получает fakeip из 198.18/15 и умирает на WAN. Снятая галочка не
    # отправляет сеть напрямую, а отнимает у неё весь список; с роутера всё
    # выглядит исправным.
    _bwif=" $(u interface) "
    _lost=""
    _outside=""
    for _dsec in $(uci show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.]*\)=dhcp$/\1/p'); do
        _dif=$(uci -q get "dhcp.$_dsec.interface" 2>/dev/null || true)
        [ -n "$_dif" ] || continue
        [ "$(uci -q get "dhcp.$_dsec.ignore" 2>/dev/null || true)" = "1" ] && continue
        _dbr=$(uci -q get "network.$_dif.device" 2>/dev/null || true)
        [ -n "$_dbr" ] || _dbr="br-$_dif"
        case "$_bwif" in *" $_dbr "*) continue ;; esac
        # Сеть вне перехвата копится отдельно: в режиме «всё через VPN» это
        # дыра, чем бы она ни резолвила -- гейт `iifname != {…} return` стоит
        # первым и в перехвате, и в запрете.
        _outside="$_outside $_dif"
        # Свой резолвер сети задан через DHCP -- значит наш ей и не достаётся.
        uci -q get "dhcp.$_dsec.dhcp_option" 2>/dev/null | grep -q '6,' && continue
        _lost="$_lost $_dif"
    done
    if [ "$(u list_mode)" = "all" ] && [ -n "$_outside" ]; then
        _d_bad "$(_f 'режим «всё через VPN», а эти сети идут мимо него целиком:%s' "$_outside")" \
               "в этом режиме byway.main.interface -- граница ВСЕЙ защиты, а не только списков: что вне его, то мимо туннеля и мимо запрета «не пускать мимо VPN». Добавить сети в byway.main.interface"
    elif [ -n "$_lost" ]; then
        _d_warn "$(_f 'сети с резолвером byway, но без перехвата:%s' "$_lost")" \
                "их клиенты получат подставной адрес, до туннеля не дойдут и потеряют ВЕСЬ список. Лечится одним из двух: добавить сеть в byway.main.interface либо выдать ей свой DNS через dhcp_option '6,…'"
    else
        _d_ok "$(_t 'перехват и резолвер согласованы по сетям')"
    fi

    # Клиент, резолвящий мимо роутера (Приватный DNS, DoH, чужой резолвер),
    # туннеля не получает: маршрут решает DNS. Перехват 53-го порта byway не
    # ставит -- решение владельца сети.
    if [ "$(u list_mode)" != "all" ]; then
        _d_warn "$(_t 'клиент со своим DNS проходит мимо туннеля')" \
                "маршрут решает DNS: устройство с «Приватным DNS», DoH в браузере или чужим резолвером в настройках уйдёт напрямую, и byway этого не увидит. Лечится либо выключением шифрованного DNS на устройствах, либо перехватом 53-го порта в firewall, либо добавлением к доменам ПОДСЕТЕЙ сервиса: подсеть работает по адресу, а значит и для того, кто спросил адрес не у роутера. Третий способ проще двух первых, но покрывает ТОЛЬКО IPv4: клиент, получивший AAAA, уйдёт мимо подсетей"
    fi
    return 0
}

# Чужие правила firewall по метке byway.
doctor_marks() {
    # Чужое правило по той же метке -- дыра: удаление нашего её не закроет
    # (остаток podkop).
    _mk=$(u mark); _mk=${_mk:-0x100000}
    _other=$(uci show firewall 2>/dev/null | grep -c "mark='$_mk" || true)
    if [ "${_other:-0}" -gt 1 ]; then
        _d_warn "$(_f 'правил firewall с меткой %s: %s' "$_mk" "$_other")" "лишнее оставит дыру после удаления byway — проверить: uci show firewall | grep mark"
    elif [ "${_other:-0}" -eq 0 ]; then
        _d_warn "$(_t 'правила firewall для помеченного трафика нет')" "гостевые и другие зоны с input REJECT остаются без туннеля; byway заводит правило заново при подъёме перехвата: /etc/init.d/byway restart"
    else
        _d_ok "$(_f 'правил firewall с меткой byway: %s' "${_other:-0}")"
    fi
    return 0
}

# Направления, лишние файлы направлений и пресетов, возраст пресетов.
doctor_files() {
    # Направления: ключ по метке мог исчезнуть, список -- опустеть.
    for _r4 in $(route_names); do
        [ "$(uci -q get "byway.$_r4.enabled")" = "0" ] && continue
        _l4=$(uci -q get "byway.$_r4.label" || true)
        if ! route_key "$_l4" >/dev/null 2>&1; then
            _d_bad "$(_f 'направление «%s»: ключа с меткой «%s» нет' "$_r4" "$_l4")" "выбрать существующий ключ либо убрать направление"
        elif [ ! -s "$ROUTES_DIR/$_r4.lst" ]; then
            _d_warn "$(_f 'направление «%s»: список пуст' "$_r4")" "наполнить список либо убрать направление"
        else
            _d_ok "$(_f 'направление «%s» ведёт в «%s»' "$_r4" "$_l4")"
        fi
    done

    # Файл удалённого направления byway не читает, но и не убирает: удаление
    # отдано человеку (файл могли положить заранее).
    for _of in "$ROUTES_DIR"/*.lst; do
        [ -f "$_of" ] || continue
        _on=$(basename "$_of" .lst)
        uci -q get "byway.$_on" >/dev/null 2>&1 && continue
        _d_warn "$(_f 'список «%s» лежит без направления и не читается' "$_on")" "убрать файл, если направление удалено"
    done

    # Снятая галочка пресета оставляет копию во флеше (до 200 тыс. строк на
    # 43.7 МБ; её не убирают ни `byway clear`, ни удаление без --purge).
    # Обратное опаснее: включение не запускает скачивание, а с ним пропадает
    # сверка с хостлистом zapret -- поэтому предупреждение про возраст.
    for _pf2 in "$PRESETS_DIR"/*.lst "$PRESETS_DIR"/*.sub; do
        [ -f "$_pf2" ] || continue
        _pn2=$(basename "$_pf2" .lst); _pn2=${_pn2%.sub}
        case " $(u preset) " in
          *" $_pn2 "*)
            if [ -z "$(find "$_pf2" -mtime -30 2>/dev/null)" ]; then
                _d_warn "$(_f 'готовый список «%s» не обновлялся больше месяца' "$_pn2")" "обновить и заодно свериться с zapret: byway presets"
            fi ;;
          *) _d_warn "$(_f 'готовый список «%s» отключён, а копия лежит во флеше' "$_pn2")" "включить обратно или убрать файл из /etc/byway/presets" ;;
        esac
    done
    return 0
}

# Соседи по ремеслу (podkop, passwall и др.): работают ли рядом.
doctor_rivals() {
    for _nb in podkop:podkop passwall:passwall passwall2:passwall2 \
               openclash:openclash nikki:nikki homeproxy:homeproxy \
               shadowsocks-libev:shadowsocks; do
        _ni=${_nb%%:*}; _nn=${_nb##*:}
        if [ -x "/etc/init.d/$_ni" ]; then
            # `enabled` -- про автозапуск, не про работу: живой процесс важнее.
            # Ещё смотрится след в ядре (таблица nft, правило на таблицу 100):
            # `running` есть не у всякой службы, podkop отвечает «not running»
            # при живом движке.
            _trace=0
            nft list tables 2>/dev/null | grep -qi "[ ]$_ni\$" && _trace=1
            ip rule show 2>/dev/null | grep -q "lookup $RT_TABLE" &&
                [ -z "$(xray_pid)" ] && _trace=1
            if [ "$_trace" = 1 ]; then
                _d_bad "$(_f 'рядом РАБОТАЕТ %s' "$_nn")" "$(_f 'след виден в ядре: своя таблица nft либо правило на таблицу маршрутизации %s. Оставить что-то одно: /etc/init.d/%s stop && /etc/init.d/%s disable' "$RT_TABLE" "$_ni" "$_ni")"
            elif "/etc/init.d/$_ni" running >/dev/null 2>&1; then
                _d_bad "$(_f 'рядом РАБОТАЕТ %s' "$_nn")" "$(_f 'он метит трафик и перехватывает те же порты — оставить что-то одно: /etc/init.d/%s stop && /etc/init.d/%s disable' "$_ni" "$_ni")"
            elif "/etc/init.d/$_ni" enabled 2>/dev/null; then
                _d_warn "$(_f 'рядом включён %s' "$_nn")" "он метит трафик и перехватывает те же порты — оставить что-то одно"
            else
                _d_ok "$(_f '%s установлен, но выключен' "$_nn")"
            fi
        fi
    done
    return 0
}

# Порты tproxy и прокси, заворот трафика роутера, маршрут, дубли ip rule.
doctor_ports() {
    # Порт, метку и таблицу мог занять кто угодно: спрашиваем систему.
    _tp=$(u tproxy_port); _tp=${_tp:-1602}
    _lp2=$(u local_proxy_port); _lp2=${_lp2:-1603}
    # redir_port ругается на столкновение портов: звать раз, не трижды.
    _rdport=$(redir_port "$(_t 'проверки окружения')")
    if [ -n "$_rdport" ]; then _rdpair="$_rdport:$(_t 'вход для трафика роутера')"
    else _rdpair=""; fi
    for _pp in "$_tp:$(_t 'вход tproxy')" "$_lp2:$(_t 'прокси роутера')" ${_rdpair:+"$_rdpair"}; do
        _pn=${_pp%%:*}; _pd=${_pp##*:}
        _who=$(netstat -lnp 2>/dev/null | grep -E "[:.]$_pn[[:space:]]" |
               awk '{print $NF}' | grep -v "^-$" | sort -u | tr '\n' ' ')
        case "$_who" in
          ""|*xray*) _d_ok "$(_f '%s (порт %s) свободен или занят byway' "$_pd" "$_pn")" ;;
          *)         _d_warn "$(_f '%s (порт %s) занят: %s' "$_pd" "$_pn" "$_who")" "сменить порт в настройках byway либо убрать чужую службу" ;;
        esac
    done
    # Заворот включён настройкой, работает цепочкой в ядре: расходятся молча
    # (правила не переложили). Спрашивать только при стоящей обвязке: на свежей
    # установке цепочки нет, и совет «переложить» вреден.
    if [ -n "$_rdport" ] && nft list table inet "$TABLE" >/dev/null 2>&1; then
        if nft list chain inet "$TABLE" output >/dev/null 2>&1; then
            # Цепочка ловит только fakeip, то есть домены объединённого списка:
            # на пустом списке она есть, а заворот не действует (заметнее всего
            # в режиме «всё через VPN»).
            if [ -n "$(plain_domains "$(merged_domains)" | head -1)" ]; then
                _d_ok "$(_t 'роутер ходит к сайтам из списка сам')"
            else
                _d_warn "$(_t 'заворот трафика роутера включён, но список пуст — ловить нечего')" \
                        "заворот работает по доменам списка: наполнить список либо подключить готовый"
            fi
        else
            _d_warn "$(_t 'заворот трафика роутера включён, но цепочки в ядре нет')" \
                    "переложить правила: byway plumb off && byway plumb on"
        fi
    elif [ "$(u router_via_vpn)" != "1" ]; then
        # Без заворота свой трафик роутера перехват не ловит: резолвер отдаёт
        # fakeip, маршрута нет, curl висит до таймаута, busybox wget --
        # «Operation not permitted». byway не задет (ходит через прокси-вход),
        # задеты соседи: обновлялка zapret, Zapret-Manager, чужие скрипты.
        _d_warn "$(_t 'роутер сам до сайтов из списка не достаёт')" \
                "заворот своего трафика выключен: программы на роутере — обновления zapret, свои скрипты — виснут на подставном адресе до таймаута. Включить: uci set byway.main.router_via_vpn=1 && uci commit byway && /etc/init.d/byway reload"
    fi

    # Правило и маршрут снимаются разными руками: сосед, чистящий таблицу 100,
    # уносит маршрут, а правило и nft остаются -- обвязка выглядит исправной.
    if nft list table inet "$TABLE" >/dev/null 2>&1 &&
       ! ip route show table "$RT_TABLE" 2>/dev/null | grep -q '^local default'; then
        _d_bad "$(_f 'в таблице маршрутизации %s нет маршрута local default' "$RT_TABLE")" \
               "переложить правила: byway plumb off && byway plumb on"
    fi

    _rules=$(ip rule show 2>/dev/null | grep -cE "$(rule_re)" || true)
    if [ "${_rules:-0}" -gt 1 ]; then
        _d_warn "$(_f 'правил ip rule на таблицу %s: %s' "$RT_TABLE" "$_rules")" "лишние копятся при перезапусках — снять: byway plumb off && byway plumb on"
    fi
    return 0
}

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
    if ( parse_node >/dev/null 2>&1 ); then
        parse_node >/dev/null 2>&1 || true
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
    logread -e byway 2>/dev/null | tail -30 || true
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
              s/([A-Za-z0-9-]+\.)+[A-Za-z]{2,}/'"$(_t ИМЯ)"'/g' || true
}
