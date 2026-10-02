# Конфиг Xray: cmd_gen и его шаги gen_*, транспорт и защита (build_stream),
# аутбаунды автовыбора. $OUT меняется, только если ядро приняло конфиг
# (run -test). probe, show, check -- проверки без боевого конфига.

# Имя хоста из строки резолвера, пусто для адреса. Имени нужен bootstrap: иначе
# движок спросит имя сервера у него же самого.
dns_host() {   # 1 -- строка вида https://ЧТО-ТО/путь
    _dh=${1#*://}; _dh=${_dh%%/*}
    # Литерал IPv6 пишется в скобках -- это адрес, а не имя.
    case "$_dh" in \[*) return 0 ;; esac
    _dh=${_dh%%:*}
    case "$_dh" in
      *[!0-9.]*) printf '%s' "$_dh" ;;
    esac
}

# Адрес DNS-входа с умолчанием: поле в панели можно очистить, а голое `u
# dns_listen` тогда пусто -- сторож каждые 5 минут пересобирает обвязку, а
# dns_down не возвращает резолвер провайдеру.
dns_addr() {
    _da=$(u dns_listen)
    printf '%s' "${_da:-127.0.0.42}"
}

# Годится ли пул по смыслу, а не только по форме. Пул в приватном диапазоне
# мёртв молча: цепочка nft отсекает приватное первым правилом, блокировка Xray
# его перечисляет, rebind_protection dnsmasq вырезает его из ответов, а проба
# plumb on спрашивает движок напрямую и проходит. Пул уже списка -- выдача идёт
# по кругу, и соединение уходит на чужой домен.
pool_sane() {   # 1 -- пул вида a.b.c.d/len
    _pn=${1%/*}; _pl=${1#*/}
    case "$_pl" in ''|*[!0-9]*) warn "пул $1 без длины маски -- взято умолчание" >&2; return 1 ;; esac
    if [ "$_pl" -lt 8 ] || [ "$_pl" -gt 30 ]; then
        warnf "пул %s: маска /%s не годится -- взято умолчание" "$1" "$_pl" >&2
        return 1
    fi
    # Сравнение по первому октету (172, 169, 192, 100 -- по второму): опасные
    # диапазоны выровнены по октету.
    _o1=${_pn%%.*}; _r=${_pn#*.}; _o2=${_r%%.*}
    # 240.0.0.0/4 -- весь диапазон 240-255, а не края. Список тот же, что в
    # RESERVED и в правиле блокировки движка: править все три вместе.
    case "$_o1" in
      0|10|127|22[4-9]|23[0-9]|24[0-9]|25[0-5])
        warnf "пул %s лежит в приватном или зарезервированном -- он мёртв: цепочка nft отсекает такие адреса первым же правилом" "$1" >&2
        return 1 ;;
      172) [ "$_o2" -ge 16 ] && [ "$_o2" -le 31 ] && {
             warnf "пул %s лежит в 172.16/12 -- он мёртв" "$1" >&2; return 1; } ;;
      192) [ "$_o2" = 168 ] && {
             warnf "пул %s лежит в 192.168/16 -- он мёртв" "$1" >&2; return 1; } ;;
      169) [ "$_o2" = 254 ] && {
             warnf "пул %s лежит в 169.254/16 -- он мёртв" "$1" >&2; return 1; } ;;
      100) [ "$_o2" -ge 64 ] && [ "$_o2" -le 127 ] && {
             warnf "пул %s лежит в 100.64/10 -- он мёртв" "$1" >&2; return 1; } ;;
    esac
    return 0
}

# Число адресов в пуле: для poolSize движка и для предупреждения «список
# длиннее пула».
pool_size() {   # 1 -- пул вида a.b.c.d/len
    _psl=${1#*/}
    case "$_psl" in ''|*[!0-9]*) _psl=15 ;; esac
    awk -v l="$_psl" 'BEGIN {
        if (l < 1 || l > 32) l = 15
        n = 2 ^ (32 - l) - 2
        # Нижнего ограничителя ЗДЕСЬ нет. Стоял `if (n < 16) n = 16`, и на
        # масках /29 и /30 объявленная ёмкость оказывалась вчетверо больше
        # настоящей: единственная защита от «пул уже списка» сравнивается
        # именно с этим числом и на таких масках не срабатывала никогда, а
        # пары «домен-адрес» вытеснялись из кэша на 16 мест над пулом из 4.
        # Соединение к домену A уходило на хост домена B, без единой ошибки
        # где бы то ни было. Найдено четвёртым аудитом, заход 3.
        if (n < 1) n = 1
        printf "%d", n
    }'
}

fakeip_re() {
    _fp=$(u fakeip_pool); _fp=${_fp:-198.18.0.0/15}
    case "$_fp" in
        198.18.0.0/15) printf '198\.1[89]\.' ;;
        *) printf '%s\.' "$(echo "$_fp" | cut -d. -f1-2 | sed 's/\./\\./g')" ;;
    esac
}

# Порт входа для собственного трафика роутера; пусто -- не заворачивать
# (выключено или порт занят другим входом byway). Одна функция на конфиг движка
# и правила nft: при расхождении правила вели в никуда. Включение только по
# «1»: на конфиге без ключа заворот включаться сам не должен.
redir_port() {
    [ "$(u router_via_vpn)" = "1" ] || return 0
    _rdp=$(val_or redirect_port "$(u redirect_port)" '^[0-9]{1,5}$' 1604 "$1")
    port_ok "$_rdp" || _rdp=1604
    _rdt=$(u tproxy_port); _rdt=${_rdt:-1602}
    _rdl=$(u local_proxy_port); _rdl=${_rdl:-1603}
    if [ "$_rdp" = "$_rdt" ] || [ "$_rdp" = "$_rdl" ]; then
        # >&2: ответ функции забирают подстановкой, жалоба из stdout попала бы
        # в конфиг на место номера порта.
        warnf "порт %s занят другим входом byway — свой трафик роутер в туннель не пошлёт" "$_rdp" >&2
        return 0
    fi
    printf '%s' "$_rdp"
}

# Список -> строки JSON-массива. Строка из списка попадает в конфиг как есть,
# поэтому пропускаются только буквы, цифры, . - : / _ до 253 знаков: кавычки
# и обратной косой в наборе нет, выйти из JSON-строки нечем (экранирование
# busybox awk не принимает). Отброшенное -- в $BADLIST, его называет cmd_gen.
list_to_json() {
    awk -v pfx="$2" -v bad="$BADLIST" '
      { sub(/\r$/, "") }
      /^[[:space:]]*$/          { next }
      /^[[:space:]]*(\/\/|#)/   { next }
      { gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if (!length($0)) next
        if (length($0) > 253)              { print $0 >> bad; next }
        # Форма проверяется по тому, ЧЕМ будет запись, а не одним общим
        # набором знаков. Прежний набор [A-Za-z0-9._:/-] пропускал и
        # «/d8d/s.com», и «full:example.com»: byway приписывает свой префикс
        # domain:, такая запись становилась «domain:full:example.com», ни с
        # чем не совпадала никогда и лежала в списке как живая. Молча
        # мёртвая запись хуже отвергнутой -- отвергнутые byway называет
        # вслух при сборке.
        #
        # Интервалы {2,} не используются намеренно: в awk старых сборок
        # busybox их может не быть, а [A-Za-z][A-Za-z]+ выражает то же.
        if (pfx ~ /^domain:/) {
            v = $0
            # geosite: и ext: не принимаются, и это не лень. Обе требуют
            # файла данных -- geosite.dat либо своего списка, -- которого
            # byway не поставляет, а Xray без указанного файла не стартует
            # вовсе. Человек получил бы «byway перестал собирать конфиг»
            # вместо строки про одну негодную запись.
            if (v ~ /^(geosite|ext):/)     { print $0 >> bad; next }
            pre = ""
            if (v ~ /^(domain|full|keyword|regexp):/) {
                pre = substr(v, 1, index(v, ":"))
                v = substr(v, index(v, ":") + 1)
                if (!length(v))            { print $0 >> bad; next }
            }
            if (pre == "regexp:") {
                # Единственная форма, где обратная косая и кавычка законны по
                # смыслу. Значит их не отвергают, а экранируют по правилам
                # JSON -- иначе кавычка закрыла бы строку и дописала свои
                # поля в конфиг, ровно как это делал extra.
                #
                # По знаку, а не gsub: в строке замены у gsub обратная косая
                # имеет своё значение, и «удвоить косую» пишется там четырьмя
                # уровнями экранирования, которые никто потом не прочтёт.
                esc = ""
                for (k = 1; k <= length(v); k++) {
                    ch = substr(v, k, 1)
                    if (ch == "\\" || ch == "\"") esc = esc "\\"
                    esc = esc ch
                }
                v = esc
            } else if (pre == "keyword:") {
                if (v !~ /^[A-Za-z0-9._-]+$/) { print $0 >> bad; next }
            } else {
                # domain:, full: и запись без префикса -- обычный домен.
                if (v !~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/ ||
                    v !~ /\.[A-Za-z][A-Za-z]+$/ ||
                    v ~ /\.\./)            { print $0 >> bad; next }
                if (pre == "") pre = pfx
            }
            if (n++) printf ",\n"
            printf "        \"%s%s\"", pre, v
            next
        } else {
            # Подсети. Та же форма, что у set_elements для nft, включая
            # проверку чисел: расходиться им нельзя, иначе запись уходит в
            # конфиг движка и не уходит в правила ядра. Одной регулярки мало
            # -- она пропускает и 999.1.2.3, и /33.
            ok = 1
            if ($0 ~ /:/) {
                # IPv6. Строгую форму проверяет set_elements6 -- она решает,
                # что уйдёт в ядро; здесь хватает грубой, потому что дальше
                # строку разбирает сам Xray. Без этой ветки годная подсеть
                # IPv6 уходила в список отброшенных И не попадала в правило
                # маршрутизации вовсе: перехваченный по ней трафик движок
                # отдавал наружу напрямую, то есть обещание «подсети в
                # туннель» для v6 не выполнялось молча.
                if ($0 !~ /^[0-9a-fA-F:]+(\/[0-9]{1,3})?$/) { print $0 >> bad; next }
            } else {
                if ($0 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) ok = 0
                else {
                    np = split($0, oc, /[.\/]/)
                    for (i = 1; i <= 4; i++) if (oc[i] + 0 > 255) ok = 0
                    if (np == 5 && oc[5] + 0 > 32) ok = 0
                }
                if (!ok)                   { print $0 >> bad; next }
            }
        }
        if (n++) printf ",\n"
        printf "        \"%s%s\"", pfx, $0 }
      END { if (!n) printf "" }
    ' "$1"
}

# STREAM и SECURITY из разобранных полей. Зовётся и генератором, и проверкой
# ноды: проверяется ровно тот транспорт, что пойдёт в бой.
build_stream() {
    # При своём конфиге собирать нечего: он уже целиком написан человеком.
    if [ "$N_PROTO" = "raw" ]; then
        STREAM=""; SECURITY=""; FLOWJ=""; MUXJ=""
        OUTBOUND=""
        return 0
    fi
    stream_transport
    stream_security
    FLOWJ=""
    # if, а не «[ ] && ...»: при пустом значении та конструкция вернула бы 1, и
    # set -e молча убил бы скрипт.
    if [ -n "$N_FLOW" ]; then
        # Vision -- только голый TCP с TLS или Reality; на ws, grpc и прочих
        # Xray конфиг принимает, а падает в бою.
        case "$N_TYPE" in
          tcp|raw) ;;
          *) warnf "flow=%s с транспортом %s не работает: Xray-core примет конфиг и сломается в бою" "$N_FLOW" "$N_TYPE" ;;
        esac
        FLOWJ=", \"flow\": \"$N_FLOW\""
    fi

    # После FLOWJ: аутбаунд входит в блок пользователя vless.
    build_outbound

    # mux схлопывает клиентские соединения в несколько к ноде: на роутере узкое
    # место процессор, а полсотни TLS-сессий -- полсотни наборов криптографии.
    # В поставке включён (8, замер в etc-config-byway), выключает 0. С flow mux
    # несовместим: Vision сам делит поток.
    MUXJ=""
    # val_or: значение уходит в JSON без кавычек и приходит снаружи
    # (EXPORT_KEYS, панель).
    _mux=$(val_or mux_concurrency "$(u mux_concurrency)" \
           '^[0-9]{1,3}$' 0 "$(_t 'конфига движка')")
    if [ -n "$_mux" ] && [ "$_mux" != "0" ]; then
        if [ -n "$N_FLOW" ]; then
            warnf "mux отключён: он не сочетается с flow=%s (Vision делит поток сам)" "$N_FLOW"
        elif [ "$N_TYPE" = "xhttp" ] || [ "$N_TYPE" = "grpc" ] || [ "$N_TYPE" = "hysteria" ]; then
            # У xhttp свой xmux, у grpc multiMode: второй слой только добавляет
            # блокировку начала очереди (xhttp, 2026-09-03: 896 мс с mux, 861
            # без).
            warnf "mux отключён: у транспорта %s своё мультиплексирование, второй слой поверх только вредит" "$N_TYPE"
        elif [ "$N_PROTO" = "wireguard" ]; then
            # У wireguard потока нет, делить нечего.
            warn "mux к wireguard не применяется: у него нет потока, который можно делить"
        else
            MUXJ=" \"mux\": { \"enabled\": true, \"concurrency\": $_mux },"
        fi
    fi
}

# STREAM: настройки транспорта по N_TYPE.
stream_transport() {
    case "$N_TYPE" in
      # host отдельным полем, не в headers: Xray 26 ругается на старую форму
      # (deprecated). Но wsSettings.host появилось к 1.8.24; у 1.8.3 (фид
      # OpenWrt 22.03) поле отбрасывается молча, Host остаётся адресом
      # соединения, CDN отвечает 404/1003. Отсюда развилка.
      ws)  xray_ver_num >/dev/null
           if [ "$XRAYVER" -lt 10824 ]; then
             STREAM="\"network\": \"ws\", \"wsSettings\": { \"path\": \"$N_PATH\", \"headers\": { \"Host\": \"$N_WSHOST\" } }"
           else
             STREAM="\"network\": \"ws\", \"wsSettings\": { \"path\": \"$N_PATH\", \"host\": \"$N_WSHOST\" }"
           fi ;;

      # raw -- новое имя tcp, бинарник принимает оба. headerType=http включает
      # обфускацию под HTTP.
      tcp|raw)
           if [ "$N_HDR" = "http" ]; then
             STREAM="\"network\": \"tcp\", \"tcpSettings\": { \"header\": { \"type\": \"http\", \"request\": { \"path\": [ \"$N_PATH\" ], \"headers\": { \"Host\": [ \"$N_WSHOST\" ] } } } }"
           else
             STREAM="\"network\": \"tcp\""
           fi ;;

      kcp)
           # У mKCP удалены не транспорт, а поля header и seed (`run -test` на
           # 26.7.28: «mkcp header & seed has been removed»).
           warn "mkcp идёт поверх UDP, а в РФ UDP душат первым делом"
           # Поля пишем, только если они есть в ссылке: на 26.3.27 они
           # работают, а подставленный `none` валил любую kcp-ноду на свежем
           # движке.
           _k=""
           if [ -n "$N_HDR" ]; then _k="\"header\": { \"type\": \"$N_HDR\" }"; fi
           if [ -n "$N_SEED" ]; then
               [ -n "$_k" ] && _k="$_k, "
               _k="$_k\"seed\": \"$N_SEED\""
           fi
           if [ -n "$_k" ]; then
               warn "header и seed у mkcp свежие Xray-core удалили (замена: finalmask/udp header-*, mkcp-original, mkcp-aes128gcm) -- оставлены как в ссылке; если движок их отвергнет, конфиг не заменится"
               STREAM="\"network\": \"kcp\", \"kcpSettings\": { $_k }"
           else
               STREAM="\"network\": \"kcp\""
           fi ;;

      grpc)
           _g=""
           if [ "$N_MODE" = "multi" ]; then _g=", \"multiMode\": true"; fi
           if [ -n "$N_AUTH" ]; then _g="$_g, \"authority\": \"$N_AUTH\""; fi
           STREAM="\"network\": \"grpc\", \"grpcSettings\": { \"serviceName\": \"$N_SVC\"$_g }" ;;

      h2|http)
           # Удалён весь транспорт: движок отвергает конфиг и называет замену.
           # Версию не пишем: у выпусков 26.4-26.7 заметок нет.
           warn "HTTP/2 из Xray-core удалён, замена: xhttp в режиме stream-one"
           STREAM="\"network\": \"$N_TYPE\", \"httpSettings\": { \"path\": \"$N_PATH\", \"host\": [ \"$N_WSHOST\" ] }" ;;

      quic)
           # Тоже удалён; замена -- xhttp поверх H3.
           warn "QUIC из Xray-core удалён, замена: xhttp stream-one поверх H3; в РФ QUIC блокируют первым делом"
           _qs=${N_QSEC:-none}
           _qh=${N_HDR:-none}
           STREAM="\"network\": \"quic\", \"quicSettings\": { \"security\": \"$_qs\", \"key\": \"$N_QKEY\", \"header\": { \"type\": \"$_qh\" } }" ;;

      httpupgrade)
           # Версия появления не проверена: предупреждение, не отказ (у 1.8.3
           # транспорта нет).
           xray_ver_num >/dev/null
           [ "$XRAYVER" -lt 10824 ] &&
               warn "движок старый: транспорт httpupgrade он может не знать, и тогда конфиг соберётся, а туннель не встанет"
           STREAM="\"network\": \"httpupgrade\", \"httpupgradeSettings\": { \"path\": \"$N_PATH\", \"host\": \"$N_WSHOST\" }" ;;

      xhttp)
           # На старом движке xhttp не «хуже», а не существует: поле отбросится
           # молча. Отказ вместо конфига, который нечем объяснить.
           xray_ver_num >/dev/null
           if [ "$XRAYVER" -lt 10824 ]; then
               dief "движку %s транспорт xhttp неизвестен (нужен Xray-core 1.8.24 или новее) — обновить: byway engine tested, либо взять ключ на ws" \
                    "$("$XRAY" version 2>/dev/null | head -1 | cut -d' ' -f1-2)"
           fi
           # extra -- вложенный JSON, в ссылке в процентной кодировке;
           # подставляем как есть, битый поймает run -test в cmd_gen.
           _m=""
           if [ -n "$N_MODE" ]; then _m=", \"mode\": \"$N_MODE\""; fi
           if [ -n "$N_EXTRA" ]; then _m="$_m, \"extra\": $N_EXTRA"; fi
           STREAM="\"network\": \"xhttp\", \"xhttpSettings\": { \"path\": \"$N_PATH\", \"host\": \"$N_WSHOST\"$_m }" ;;

      hysteria)
           # Есть с 26.1.13, но схема hysteriaSettings менялась (up/down и
           # udphop ушли в finalmask к 26.9.9): пишем общие поля version и
           # auth. Нижняя граница 26.3.27 проверена прогоном.
           xray_ver_num >/dev/null
           if [ "$XRAYVER" -lt 260327 ]; then
               dief "hysteria2 нужен Xray-core 26.3.27 или новее, а стоит %s — обновить: byway engine tested" \
                    "$("$XRAY" version 2>/dev/null | head -1 | cut -d' ' -f2)"
           fi
           warn "hysteria2 идёт поверх QUIC (UDP), а в РФ его ограничивают первым делом"
           _fm=""
           if [ -n "$N_OBFS" ]; then
               # salamander в finalmask/udp -- с 26.7.11, раньше обфускации у
               # hysteria не было.
               if [ "$XRAYVER" -lt 260711 ]; then
                   dief "obfs=salamander у hysteria2 нужен Xray-core 26.7.11 или новее, а стоит %s — обновить: byway engine tested" \
                        "$("$XRAY" version 2>/dev/null | head -1 | cut -d' ' -f2)"
               fi
               _fm=", \"finalmask\": { \"udp\": [ { \"type\": \"salamander\", \"settings\": { \"password\": \"$N_OBFSPW\" } } ] }"
           fi
           STREAM="\"network\": \"hysteria\", \"hysteriaSettings\": { \"version\": 2, \"auth\": \"$N_PASS\" }$_fm" ;;

      # У wireguard транспорта нет (UDP свой); в streamSettings остаётся метка
      # self_sockopt.
      wireguard) STREAM="" ;;

      *)   dief "транспорт %s не поддержан — есть ws, tcp/raw, kcp, grpc, httpupgrade, xhttp, hysteria" "$N_TYPE" ;;
    esac
    return 0
}

# SECURITY: tls, reality или none по N_SEC.
stream_security() {
    case "$N_SEC" in
      tls)     _a=""
               # В два шага: вложенные кавычки в sed в подстановке в двойных
               # кавычках рвут разбор (2026-09-03).
               if [ -n "$N_ALPN" ]; then
                 _alist=$(printf '%s' "$N_ALPN" | sed 's/,/", "/g')
                 _a=", \"alpn\": [ \"$_alist\" ]"
               fi
               # allowInsecure ядро с 26.3.27 отвергает (там -- с 2026-06-01, с
               # 26.6.27 -- без условий). Замена -- pinnedPeerCertSha256 или
               # verifyPeerCertByName (сверено по исходникам 26.3.27-26.9.30).
               xray_ver_num >/dev/null
               if [ "$N_INSEC" = "1" ] || [ "$N_INSEC" = "true" ]; then
                 if [ "$XRAYVER" -lt 260327 ]; then
                   # Политика нового ядра и на старом: отказ без явного
                   # разрешения; с отпечатком точнее сказать «нужно 26.3.27+».
                   [ "$(u allow_insecure)" = "1" ] || [ -n "$N_PIN$N_VCN" ] ||
                     die "в ключе отключена проверка сертификата (allowInsecure): соединение может подменить любой на пути. Для своего сервера с самоподписанным сертификатом: uci set byway.main.allow_insecure=1 && uci commit byway && /etc/init.d/byway reload"
                   warn "allowInsecure=1: проверка сертификата сервера отключена, соединение можно подменить"
                   _a="$_a, \"allowInsecure\": true"
                 elif [ -z "$N_PIN" ] && [ -z "$N_VCN" ]; then
                   die "в ключе отключена проверка сертификата (allowInsecure или insecure), а Xray-core с 26.3.27 так не умеет: нужен отпечаток сертификата сервера (pcs= или pinSHA256=) либо настоящий сертификат на сервере"
                 fi
               fi
               if [ -n "$N_PIN" ] || [ -n "$N_VCN" ]; then
                 if [ "$XRAYVER" -lt 260327 ]; then
                   dief "проверка сертификата по отпечатку (pcs, vcn) нужна Xray-core 26.3.27 или новее, а стоит %s — обновить: byway engine tested" \
                        "$("$XRAY" version 2>/dev/null | head -1 | cut -d' ' -f2)"
                 fi
                 if [ -n "$N_PIN" ]; then _a="$_a, \"pinnedPeerCertSha256\": \"$N_PIN\""; fi
                 if [ -n "$N_VCN" ]; then _a="$_a, \"verifyPeerCertByName\": \"$N_VCN\""; fi
               fi
               # Отпечаток браузера только если есть: у hysteria (QUIC) его
               # нет.
               _f=""
               if [ -n "$N_FP" ]; then _f=", \"fingerprint\": \"$N_FP\""; fi
               SECURITY="\"security\": \"tls\", \"tlsSettings\": { \"serverName\": \"$N_SNI\"$_f$_a }" ;;
      reality)
               # spiderX и mldsa65Verify проверены на бинарнике: мусор в
               # значении даёт ошибку именно про них, поля реализованы.
               _r=""
               if [ -n "$N_SPX" ]; then _r=", \"spiderX\": \"$N_SPX\""; fi
               if [ -n "$N_PQV" ]; then _r="$_r, \"mldsa65Verify\": \"$N_PQV\""; fi
               SECURITY="\"security\": \"reality\", \"realitySettings\": { \"serverName\": \"$N_SNI\", \"fingerprint\": \"$N_FP\", \"publicKey\": \"$N_PBK\", \"shortId\": \"$N_SID\"$_r }" ;;
      none)    # vless и trojan без шифрования к публичному адресу ядро с
               # 26.7.11 отвергает само; на старом -- то же решение здесь:
               # uuid или пароль и весь туннель видны любому на пути.
               case "$N_PROTO" in vless|trojan)
                 xray_ver_num >/dev/null
                 if [ "$XRAYVER" -lt 260711 ] && [ "$(u allow_insecure)" != "1" ]; then
                   case "$N_HOST" in
                     10.*|192.168.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
                     *) die "ключ vless или trojan без TLS к публичному адресу: ключ и трафик видны любому на пути. Нужен ключ с security=tls или reality; разрешить всё же: uci set byway.main.allow_insecure=1 && uci commit byway && /etc/init.d/byway reload" ;;
                   esac
                 fi ;;
               esac
               SECURITY="\"security\": \"none\"" ;;
      *)       dief "security=%s не поддержан" "$N_SEC" ;;
    esac
    return 0
}

# Объект аутбаунда целиком. Для своего конфига -- написанное человеком плюс
# тег: без него правила не найдут аутбаунд.
proxy_block() {
    _tag=${1:-proxy}
    if [ "$N_PROTO" = "raw" ]; then
        # "tag" -- последним полем: на повторе ключа Xray берёт последний (`run
        # -dump`, 26.9.30), а `run -test` дубль не замечает.
        printf '%s' "$N_RAW" | awk -v t="$_tag" '
            { s = s $0 "\n" }
            END {
                n = 0
                for (i = length(s); i > 0; i--) if (substr(s, i, 1) == "}") { n = i; break }
                if (n == 0) { printf "%s", s; exit }
                head = substr(s, 1, n - 1); tail = substr(s, n)
                b = head; sub(/[[:space:]]+$/, "", b)
                sep = (substr(b, length(b), 1) == "{") ? " " : ", "
                printf "%s%s\"tag\": \"%s\" %s", b, sep, t, tail
            }' 
    else
        # Только непустые части: у wireguard транспорта нет, и «{ %s, %s }»
        # дало бы «{ , …}».
        _ss=$STREAM
        if [ -n "$SECURITY" ]; then _ss="${_ss:+$_ss, }$SECURITY"; fi
        _so=$(self_sockopt)
        if [ -z "$_ss" ]; then _so=${_so#, }; fi
        printf '{ "tag": "%s", %s,%s "streamSettings": { %s%s } }' \
            "$_tag" "$OUTBOUND" "$MUXJ" "$_ss" "$_so"
    fi
}

# Метка на исходящих; пусто при выключенном заворачивании. Для своего конфига
# (N_PROTO=raw) метку не ставим: лезть в чужой JSON вслепую опаснее, `sockopt`
# человек допишет сам (сказано в подсказке к настройке).
self_sockopt() {
    # По настройке, а не по redir_port: та ещё жалуется на порт, а зовём мы эту
    # функцию из трёх мест.
    [ "$(u router_via_vpn)" = "1" ] || return 0
    printf ', "sockopt": { "mark": %s }' "$(self_mark_dec)"
}

# Аутбаунды: обычные режимы дают один с тегом proxy; urltest -- по одному на
# ключ (proxy-N) и балансировщик leastPing, куда идут правила. Схема проверена
# на 26.7.11 (observatory, balancers, balancerTag).
build_proxies() {
    _mode=$(u conn_mode)
    OBSERVATORY=""
    BALANCERS=""
    PROXY_TARGET='"outboundTag": "proxy"'
    # Остаток правил: напрямую (списки) или в туннель (all).
    if [ "$(u list_mode)" = "all" ]; then
        LAST_TARGET=$PROXY_TARGET
    else
        LAST_TARGET='"outboundTag": "direct"'
    fi

    VPN_HOSTS=""
    if [ "$_mode" != "urltest" ]; then
        if [ -n "${1:-}" ]; then parse_node "$1"; else parse_node; fi
        build_stream
        PROXIES=$(proxy_block)
        # Свой конфиг: адрес ноды внутри чужого JSON, N_HOST = «-»; в правило
        # он шёл как ip "-/32", и движок отвергал конфиг.
        if [ "$N_PROTO" = "raw" ]; then
            VPN_HOSTS=""
            warn "свой конфиг: адрес сервера лежит внутри чужого JSON, byway его не знает и из перехвата не исключит — проверить, что адрес сервера не попал в списки, иначе туннель замкнётся сам на себя"
        else
            VPN_HOSTS=$N_HOST
        fi
        return 0
    fi

    _keys=$(u node_urls)
    [ -n "$_keys" ] || die "выбран автовыбор, но ни одного ключа не добавлено"

    PROXIES=""
    _n=0
    xray_ver_num >/dev/null     # версия -- один раз, подоболочки её наследуют
    for _k in $_keys; do
        # Подоболочка: parse_node на плохом ключе зовёт die (exit), и один
        # негодный ключ из десяти валил бы весь gen. build_stream там же:
        # отказы по версии ядра тоже через die. Настоящий разбор -- после, в
        # текущей оболочке.
        if ! _kerr=$( ( parse_node "$_k" && build_stream ) 2>&1 >/dev/null ); then
            warnf "ключ пропущен: %s" "$(printf '%s' "$_kerr" | tail -1 | tr -d '\033' | sed 's/\[[0-9;]*m//g; s/^ *\[x\] *//')"
            continue
        fi
        parse_node "$_k"
        build_stream
        _b=$(proxy_block "proxy-$_n")
        VPN_HOSTS="$VPN_HOSTS $N_HOST"
        if [ -n "$PROXIES" ]; then PROXIES="$PROXIES,
    $_b"; else PROXIES="    $_b"; fi
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] || die "ни один ключ не разобрался"

    # Идёт в `"probeInterval": "'$_iv'"`: кавычка в значении дописала бы в
    # конфиг что угодно.
    _iv=$(val_or probe_interval "$(u probe_interval)" '^[0-9]{1,4}[smh]$' 3m "$(_t 'конфига движка')")
    OBSERVATORY='"observatory": { "subjectSelector": [ "proxy-" ], "probeUrl": "https://www.google.com/generate_204", "probeInterval": "'$_iv'" },'
    BALANCERS='"balancers": [ { "tag": "auto", "selector": [ "proxy-" ], "strategy": { "type": "leastPing" } } ],'
    PROXY_TARGET='"balancerTag": "auto"'
    [ "$(u list_mode)" = "all" ] && LAST_TARGET=$PROXY_TARGET
    N_LABEL=$(_f 'автовыбор из %s' "$_n")
}

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
    trap '[ -n "$XP" ] && kill $XP 2>/dev/null; : > "$CFG" 2>/dev/null; : > "$LOG" 2>/dev/null; : > /tmp/byway-probe.out 2>/dev/null' EXIT INT TERM
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
    kill $XP 2>/dev/null
    wait $XP 2>/dev/null
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
}

cmd_gen() {
    # Замок: панель и cron могут позвать gen одновременно, а черновик один.
    _lock=/var/run/byway-gen.lock
    take_lock "$_lock" "$(_t 'сборка конфига')" || die "другая сборка конфига не закончилась за 30 секунд"
    # Ловушка -- подстраховка: замок снимается явно в конце каждой ветки (в
    # живом gen EXIT-ловушка его не снимала, и следующая сборка ждала 30 с).
    trap 'rm -rf "$_lock" 2>/dev/null; true' EXIT INT TERM

    [ -f "$CONF" ] || dief "нет %s" "$CONF"
    [ -x "$XRAY" ] || die "xray не найден"
    mkdir -p "$LISTS"

    D=$LISTS/domains.lst
    S=$(merged_subnets)
    # Объединённый список -- один раз на сборку: читается трижды (DNS, маршрут,
    # отчёт).
    MERGED=$(merged_domains)
    gen_routes
    [ -f "$D" ] || dief "нет списка доменов %s" "$D"
    [ -f "$S" ] || warnf "нет списка подсетей %s — правило по адресам не будет создано" "$S"
    gen_dns
    gen_inbounds
    gen_log
    gen_outbounds
    gen_dns_route

    # Черновик в память, не во флеш (43.7 МБ): живёт секунды, а на неудачной
    # сборке оставался бы файл с uuid и правами 0644.
    TMP=/tmp/byway-config.new.json
    # Сначала rm, потом создание под umask 077: `: >` усекал бы существующий
    # файл с его правами и чужими открытыми дескрипторами. Имя предсказуемо,
    # /tmp общий, внутри uuid: сосед (dnsmasq) мог создать файл 0666 заранее и
    # читать конфиг; chmod после записи не спасает.
    rm -f "$TMP" 2>/dev/null || true
    (umask 077; : > "$TMP") 2>/dev/null || true
    gen_json

    # Один прогон движка, не три: из вывода берутся и предупреждения, и причина
    # отказа.
    _test=$("$XRAY" run -test -c "$TMP" 2>&1) && _testok=1 || _testok=0
    if [ "$_testok" = "1" ]; then
        # Предупреждения движка не глотать: Xray помечает транспорт устаревшим
        # за версию-другую до удаления, другого заблаговременного сигнала нет.
        # h2 и quic прошли путь warning -> удаление; ws и httpupgrade сейчас в
        # warning. Предупреждение может касаться части транспорта (kcp: только
        # поля) -- читать целиком.
        printf '%s\n' "$_test" |
          grep -i "deprecated\|will be removed\|migrate to" |
          sed 's/.*errors: //' | cut -c1-96 | sort -u |
          while IFS= read -r _w; do warnf "движок: %s" "$_w"; done

        # Отброшенные записи называем вслух и до сравнения с рабочим:
        # молчаливая потеря выглядит как «byway не работает с этим доменом».
        # Считаем уникальные: список читается дважды (DNS и маршрут).
        _bad=$(sort -u "$BADLIST" 2>/dev/null | grep -c . || true)
        if [ "${_bad:-0}" -gt 0 ]; then
            warnf "записей отброшено как неподходящие: %s" "$_bad"
            sort -u "$BADLIST" 2>/dev/null | head -3 | sed 's/^/    /'
            warn "  причина: не похоже ни на домен (буквы, цифры, дефис и точки; последняя часть — не короче двух букв), ни на подсеть IPv4, либо длиннее 253 знаков"
        fi
        # Не изменилось -- рабочий не трогаем: панель и procd зовут gen при
        # каждом «Сохранить и применить», это две записи во флеш на нажатие.
        if cmp -s "$TMP" "$OUT"; then
            rm -f "$TMP" 2>/dev/null || true
            rm -rf "$_lock" 2>/dev/null || true
            say "конфиг не изменился, рабочий оставлен как есть"
            sayf "  доменов %s, подсетей %s" "$(count_list "$MERGED")" "$(count_list "$S")"
            return 0
        fi
        # Место -- до подмены: обрыв записи оставил бы на месте рабочего
        # половину конфига.
        _need=$(( $(wc -c < "$TMP") / 1024 + 32 ))
        _have=$(df -k "$LISTS" 2>/dev/null | awk 'NR==2{print $4}')
        [ "${_have:-999999}" -ge "$_need" ] ||
            dief "на флеше свободно %s КБ, для конфига нужно %s -- рабочий не тронут" \
                 "${_have:-0}" "$_need"
        mv "$TMP" "$OUT"
        # В конфиге uuid ключа: читать должен только root.
        chmod 600 "$OUT" 2>/dev/null || true
        sayf "конфиг собран и проверен движком: %s (%s байт)" "$OUT" "$(wc -c < "$OUT")"
        _own=$(count_list "$D")
        _all=$(count_list "$MERGED")
        if [ "$_all" -gt "$_own" ]; then
            sayf "  доменов %s (свои %s + пресеты), подсетей %s" "$_all" "$_own" "$(count_list "$S")"
        else
            sayf "  доменов %s, подсетей %s" "$_own" "$(count_list "$S")"
        fi
        if [ "$(u conn_mode)" = "urltest" ]; then
            sayf "  подключение: %s — Xray-core выбирает рабочий ключ по задержке" "${N_LABEL}"
        else
            _lb=${N_LABEL:-$N_HOST}
            sayf "  подключение: %s (%s:%s), транспорт %s, защита %s" "$_lb" "$N_HOST" "$N_PORT" "$N_TYPE" "$N_SEC"
        fi
        # Ширина -- по объединённому списку: одна строка 0.0.0.0/0 молча
        # превращает режим «по спискам» в полный туннель, да ещё хуже all --
        # правило «русские зоны напрямую» есть только в нём.
        net_warn "$(merged_subnets)"
        sayf "  пул fakeip %s, DNS-вход %s:53, tproxy %s, прокси роутера 127.0.0.1:%s" "$POOL" "$DNS_LISTEN" "$TP_PORT" "$LOCAL_PORT"
        rm -rf "$_lock" 2>/dev/null || true
    else
        warnf "движок отверг конфиг, черновик остался в %s:" "$TMP"
        printf '%s\n' "$_test" | tail -5 | sed 's/^/    /'
        xray_hint "$_test"
        rm -rf "$_lock" 2>/dev/null || true
        exit 1
    fi
}

# Направления со своим выходом: ноды, правила и хосты (ROUTE_*), общий список
# MAINDOM без их доменов.
gen_routes() {
    # До главного ключа: разбор ссылки пишет в общие N_*, и главный должен
    # разобраться последним, иначе сводка расскажет про чужую ноду. Пояснение
    # внутри ROUTE_RULES: без направлений оно не должно попасть в конфиг.
    ROUTE_OUT=""; ROUTE_HOSTS=""; ROUTE_N=0
    ROUTE_RULES="
      // Направления идут ПЕРЕД общими правилами: Xray берёт первое
      // совпавшее, и домен, попавший и сюда, и в общий список, уходит
      // в свою ноду, а не в основную."
    for _rn in $(route_names); do
        [ "$(uci -q get "byway.$_rn.enabled")" = "0" ] && continue
        _rlb=$(uci -q get "byway.$_rn.label" || true)
        _rf=$ROUTES_DIR/$_rn.lst
        if [ ! -s "$_rf" ]; then
            warnf "направление «%s»: список %s пуст, пропущено" "$_rn" "$_rf"
            continue
        fi
        _rurl=$(route_key "$_rlb" || true)
        if [ -z "$_rurl" ]; then
            warnf "направление «%s»: ключа с меткой «%s» среди добавленных нет" "$_rn" "$_rlb"
            continue
        fi
        # Подоболочка: негодный ключ не должен ронять сборку остальных.
        if ! ( parse_node "$_rurl" && build_stream ) >/dev/null 2>&1; then
            warnf "направление «%s»: ключ не разбирается, пропущено" "$_rn"
            continue
        fi
        parse_node "$_rurl" >/dev/null 2>&1
        build_stream
        ROUTE_OUT="$ROUTE_OUT
$(proxy_block "route-$_rn"),"
        ROUTE_HOSTS="$ROUTE_HOSTS $N_HOST"

        # Через list_to_json, как главный список: route_list отсеивает только
        # «не IPv4», и кавычка внутри записи закрывала бы массив domain и
        # дописывала правила в конфиг движка (JSON верен, run -test принимает).
        # Файлы направлений пишет роль панели, а конфиг исполняет root.
        _rdt=/tmp/byway-route-dom.$$
        route_list "$_rf" dom > "$_rdt" 2>/dev/null || : > "$_rdt"
        _rd=$(list_to_json "$_rdt" "domain:")
        rm -f "$_rdt" 2>/dev/null || true
        [ -n "$_rd" ] && ROUTE_RULES="$ROUTE_RULES
      { \"type\": \"field\", \"domain\": [
$_rd
        ], \"outboundTag\": \"route-$_rn\" },"
        # Подсети тоже через list_to_json: прямая печать не проверяла октеты и
        # маску, а 10.0.0.0/33 останавливала gen -- и не применялась ни одна
        # настройка.
        _rst=/tmp/byway-route-net.$$
        route_list "$_rf" net > "$_rst" 2>/dev/null || : > "$_rst"
        _rs=$(list_to_json "$_rst" "")
        rm -f "$_rst" 2>/dev/null || true
        [ -n "$_rs" ] && ROUTE_RULES="$ROUTE_RULES
      { \"type\": \"field\", \"ip\": [
$_rs
        ], \"outboundTag\": \"route-$_rn\" },"
        ROUTE_N=$((ROUTE_N + 1))
    done
    [ "$ROUTE_N" = 0 ] && ROUTE_RULES=""

    # Общее правило -- без доменов направлений (в fakedns они нужны, во втором
    # правиле лишние). grep -Fvxf, не comm: comm в busybox нет.
    MAINDOM=$MERGED
    if [ "$ROUTE_N" -gt 0 ]; then
        MAINDOM=/tmp/byway-domains-main.lst
        _rall=/tmp/byway-domains-routes.lst
        : > "$_rall"
        for _rn2 in $(route_names); do
            [ "$(uci -q get "byway.$_rn2.enabled")" = "0" ] && continue
            [ -f "$ROUTES_DIR/$_rn2.lst" ] && route_list "$ROUTES_DIR/$_rn2.lst" dom >> "$_rall"
        done
        grep -Fvxf "$_rall" "$MERGED" > "$MAINDOM" 2>/dev/null || cp "$MERGED" "$MAINDOM"
        : > "$_rall"
    fi
    [ "$ROUTE_N" -gt 0 ] && sayf "направлений со своим выходом: %s" "$ROUTE_N"
    return 0
}

# Резолверы: пул fakeip, основной и запасной upstream, bootstrap.
gen_dns() {
    # val_or: эти настройки уходили в конфиг движка сырыми (`"port": $TP_PORT`
    # даже без кавычек), входят в EXPORT_KEYS, и значением с `", ...` можно
    # было задать всю конфигурацию Xray, исполняемую от root; `run -test`
    # проверяет только синтаксис. Описка в порте расходила конфиг движка и nft.
    POOL=$(val_or fakeip_pool "$(u fakeip_pool)" \
           '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' 198.18.0.0/15 "$(_t 'конфига движка')")
    pool_sane "$POOL" || POOL=198.18.0.0/15
    DNS_UP=$(val_or dns_upstream "$(u dns_upstream)" \
             '^(https|tcp|udp|tls|quic)://[A-Za-z0-9._:/?=&%+-]+$' \
             https://8.8.8.8/dns-query "$(_t 'конфига движка')")

    # Запасной резолвер: Xray идёт к следующему серверу по порядку, когда
    # предыдущий молчит или отказал. С одним молчащим запрос гибнет. Стоит выше
    # fakedns: пустой ответ DoH считается неудачей. Домен без A-записи (_dmarc)
    # всё равно получает fakeip -- пусты оба. Умолчание -- другой провайдер
    # (8.8.8.8 и 8.8.4.4 за одним AS), отключает none.
    _du2=$(u dns_upstream2)
    case "$_du2" in
      none|off|-)
        DNS_UP2="" ;;
      *)
        DNS_UP2=$(val_or dns_upstream2 "$_du2" \
                  '^(https|tcp|udp|tls|quic)://[A-Za-z0-9._:/?=&%+-]+$' \
                  https://1.1.1.1/dns-query "$(_t 'конфига движка')") ;;
    esac
    # Тот же адрес дважды -- не запас, а лишняя строка в конфиге.
    [ "$DNS_UP2" = "$DNS_UP" ] && DNS_UP2=""

    # bootstrap: кем разрешать имя самого резолвера. Имя DoH-сервера byway
    # умеет спросить только у него же: круг, дом без DNS молча. Bootstrap --
    # простой резолвер строго для этих имён (domains); skipFallback не пускает
    # спрашивать сам сервер. Имя нужно провайдерам с anycast (dns.nextdns.io).
    _bh=""
    for _u in "$DNS_UP" "$DNS_UP2"; do
        [ -n "$_u" ] || continue
        _h=$(dns_host "$_u")
        [ -n "$_h" ] && _bh="$_bh${_bh:+, }\"full:$_h\""
    done
    DNSBOOT=""
    if [ -n "$_bh" ]; then
        _bs=$(val_or dns_bootstrap "$(u dns_bootstrap)" \
              '^([0-9]{1,3}(\.[0-9]{1,3}){3}|(tcp|udp)://[0-9.]{7,15})(:[0-9]{1,5})?$' \
              "" "$(_t 'конфига движка')")
        if [ -n "$_bs" ]; then
            DNSBOOT='
      { "address": "'"$_bs"'", "domains": [ '"$_bh"' ], "skipFallback": true },'
        else
            # Громкий отказ с возвратом к рабочему: имя без bootstrap -- дом
            # без DNS при зелёном отчёте.
            warn "резолвер задан именем, а bootstrap не задан — разрешать имя нечем, взяты поставочные адреса"
            warn "  вписать: uci set byway.main.dns_bootstrap=77.88.8.8 && uci commit byway"
            DNS_UP=https://8.8.8.8/dns-query
            DNS_UP2=https://1.1.1.1/dns-query
        fi
    fi

    DNS_UP2LINE=""
    [ -n "$DNS_UP2" ] && DNS_UP2LINE='
      "'"$DNS_UP2"'",'
    return 0
}

# Адреса и порты входов, вход собственного трафика роутера (redir-in), развилка
# direct по версии Xray.
gen_inbounds() {
    DNS_LISTEN=$(val_or dns_listen "$(dns_addr)" \
                 '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' 127.0.0.42 "$(_t 'конфига движка')")
    TP_PORT=$(val_or tproxy_port "$(u tproxy_port)" '^[0-9]{1,5}$' 1602 "$(_t 'конфига движка')")
    port_ok "$TP_PORT" || TP_PORT=1602
    # Порт прокси для самого роутера. Слушает только петлю.
    LOCAL_PORT=$(val_or local_proxy_port "$(u local_proxy_port)" \
                 '^[0-9]{1,5}$' 1603 "$(_t 'конфига движка')")
    port_ok "$LOCAL_PORT" || LOCAL_PORT=1603
    # Вход для собственного трафика роутера: prerouting ловит только мосты, а
    # то, что роутер шлёт сам, идёт через output мимо, хотя резолвер уже отдал
    # fakeip («Operation not permitted»: byway update тянет файлы с github).
    # redirect, не tproxy: tproxy в output ядро не умеет; исходный адрес движок
    # берёт через SO_ORIGINAL_DST. Только TCP: у UDP исходный адрес после
    # подмены не узнать.
    # Петлю закрывает метка на исходящих сокетах движка (self_mark):
    # неопознанный пакет движок выпускает на тот же fakeip, и правило
    # заворачивало бы его обратно.
    REDIR_IN=""
    # Метка на исходящих direct и dns-out; пусто при выключенном заворачивании.
    SELFSO=""
    [ "$(u router_via_vpn)" = "1" ] && SELFSO=", \"streamSettings\": { \"sockopt\": { \"mark\": $(self_mark_dec) } }"
    # С 26.9.8 domainStrategy у direct живёт в sockopt (freedom.domainStrategy
    # движок переносит сам с «deprecated»). Удалят -- поле отбросится молча, и
    # direct отдаст домен системному резолверу, то есть обратно в dnsmasq.
    # Старым движкам sockopt-поле не заменяло своё, отсюда развилка.
    xray_ver_num >/dev/null
    DIRECT_SET=", \"settings\": { \"domainStrategy\": \"UseIP\" }"
    _dso=""
    if [ "$XRAYVER" -ge 260908 ]; then
        DIRECT_SET=""
        _dso="\"domainStrategy\": \"UseIP\""
    fi
    [ "$(u router_via_vpn)" = "1" ] && _dso="${_dso:+$_dso, }\"mark\": $(self_mark_dec)"
    DIRECTSO=""
    [ -n "$_dso" ] && DIRECTSO=", \"streamSettings\": { \"sockopt\": { $_dso } }"
    RD_PORT=$(redir_port "$(_t 'конфига движка')")
    # Вход двухсемейный, пока в output есть правило для fakeip6: ядро
    # подставляет ::1 для локального пакета, и на [::1]:1604 никто не слушал
    # (busybox wget падал, а на нём обновление списков).
    if v6on; then RD_LISTEN="::"; else RD_LISTEN=127.0.0.1; fi
    if [ -n "$RD_PORT" ]; then
        REDIR_IN=',
    {
      "tag": "redir-in",
      "listen": "'"$RD_LISTEN"'",
      "port": '"$RD_PORT"',
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "followRedirect": true },
      "sniffing": { "enabled": true, "destOverride": [ "fakedns", "http", "tls" ], "metadataOnly": false, "routeOnly": false }
    }'
    fi
    return 0
}

# Уровень журнала и журнал обращений Xray.
gen_log() {
    LOGLVL=$(u log_level)
    case "$LOGLVL" in
      debug|info|warning|error|none) ;;
      *) [ -n "$LOGLVL" ] && warnf "уровень журнала «%s» не годится, взят warning" "$LOGLVL"
         LOGLVL=warning ;;
    esac

    # Журнал обращений Xray отдельный от журнала ошибок и включён по умолчанию,
    # поэтому свой файл в памяти, а не syslog: буфер 256 КБ держал 20 минут,
    # cmd_stat раз в час недосчитывал две трети соединений. syslog -- для жалоб
    # движка, hostapd и netifd.
    case "$LOGLVL" in
      # Подробные уровни тоже в файл: отладку начинают, когда нужна история, а
      # syslog её вытесняет первой.
      info|debug) ACCESSLOG=', "access": "'"$ACCESS"'"' ;;
      # Для cmd_stat («чем пользуются»): при выключенном сборе журнал не нужен,
      # при включённом без него экран пуст. В режиме «всё через VPN» сбора нет:
      # журнал писал бы адрес каждого соединения дома.
      *)          if [ "$(u show_usage)" = "1" ] && [ "$(u list_mode)" != "all" ]; then
                      ACCESSLOG=', "access": "'"$ACCESS"'"'
                  else
                      ACCESSLOG=', "access": "none"'
                      # Усекаем, не удаляем: движок держит файл открытым и
                      # писал бы в удалённый невидимо.
                      : > "$ACCESS" 2>/dev/null || true
                  fi ;;
    esac
    return 0
}

# Размер пула fakedns, предупреждение о длинном списке, аутбаунды.
gen_outbounds() {
    # poolSize -- потолок пар «домен-адрес». Литерал 65535 при настраиваемом
    # пуле: у /15 (131 070 адресов) половина не использовалась, а список
    # длиннее 65 535 не помещался. Вытесненная из LRU пара отдаёт адрес другому
    # домену: соединение уходит к чужому хосту без ошибки.
    POOL_SIZE=$(pool_size "$POOL")
    _dcount=$(count_list "$MERGED"); _dcount=${_dcount:-0}
    if [ "$_dcount" -gt "$POOL_SIZE" ]; then
        warnf "доменов %s, а адресов в пуле %s — часть будет вытесняться и уводить соединения к чужому хосту. Расширить пул (byway.main.fakeip_pool) либо укоротить список" \
              "$_dcount" "$POOL_SIZE"
    fi

    : > "$BADLIST" 2>/dev/null || true
    build_proxies
    # Ноды направлений тоже в исключения: иначе петля.
    VPN_HOSTS="$VPN_HOSTS $ROUTE_HOSTS"
    return 0
}

# Пул fakeip для v6, стратегия запросов, DNS через туннель.
gen_dns_route() {
    # Домены списка на резолвер не попадают: их отдаёт fakedns локально,
    # настоящий адрес узнаёт нода. Настройка решает судьбу остальных запросов:
    # с домашнего адреса или через ноду.
    # Пул массивом: FakeDnsObject принимает и объект, и список
    # (infra/conf/fakedns.go). При v6 стратегия обязана быть UseIP: UseIPv4v6 у
    # Xray нет, UseIPv4 не отдаёт AAAA.
    FAKEDNS6=""; QSTRAT=UseIPv4; BLOCK6=""; TP_LISTEN=0.0.0.0
    if v6on; then
        _p6=$(val_or fakeip6_pool "$(u fakeip6_pool)" \
              '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$POOL6_DEF" "$(_t 'конфига движка')")
        FAKEDNS6=", { \"ipPool\": \"$_p6\", \"poolSize\": $POOL_SIZE }"
        QSTRAT=UseIP
        TP_LISTEN="::"
        # Тот же пул -- и в правило блокировки, по той же причине, что и у v4.
        BLOCK6=", \"::1/128\", \"fe80::/10\", \"$_p6\""
    fi
    DNSTAG=""; DNSHOSTS=""; DNSRULE=""
    if [ "$(u dns_route)" = "tunnel" ]; then
        # Круг: чтобы открыть соединение к ноде, Xray узнаёт её адрес, а запрос
        # ушёл бы в ещё не существующий туннель. Поэтому адрес ноды разрешается
        # при сборке и кладётся в конфиг статически (смена адреса --
        # пересборка, сказано в панели). Ключу с адресом вместо имени это не
        # нужно.
        _hh=""
        for _h in $VPN_HOSTS; do
            case "$_h" in *[a-zA-Z]*) ;; *) continue ;; esac
            # Три попытки: при рестарте системный резолвер указывает на наш
            # вход (BYWAY_KEEP_DNS), а движок уже остановлен. Один nslookup с
            # dief ронял gen, start_service поднимал прежний конфиг, а plumb on
            # клал правила по новым настройкам -- половины расходились молча
            # при зелёных проверках.
            _ip=$(a_of "$_h")
            # Мимо dnsmasq вовсе: наружу роутер ходит, сломан только вход.
            [ -n "$_ip" ] || _ip=$(a_of "$_h" 8.8.8.8)
            # Последняя опора -- адрес из прежнего конфига: устаревший лучше
            # несобравшегося.
            [ -n "$_ip" ] || _ip=$(sed -n 's/.*"'"$_h"'"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' \
                                   "$OUT" 2>/dev/null | head -1)
            [ -n "$_ip" ] || dief "адрес сервера %s не разрешился — без него DNS через туннель не собрать (запросы к серверу ушли бы в сам туннель); проверить интернет и DNS роутера" "$_h"
            _hh="$_hh${_hh:+, }\"$_h\": \"$_ip\""
        done
        [ -n "$_hh" ] && DNSHOSTS="\"hosts\": { $_hh },"
        DNSTAG=', "tag": "dns-query"'
        # Перевод строки в значении: пустая настройка оставила бы пустую строку
        # посреди массива правил.
        DNSRULE='
      { "type": "field", "inboundTag": [ "dns-query" ], '"$PROXY_TARGET"' },'
    fi
    return 0
}

# Шаблон конфига Xray целиком, запись в $TMP.
gen_json() {
    {
      cat <<HEAD
{
  "log": { "loglevel": "$LOGLVL"$ACCESSLOG },

  "fakedns": [ { "ipPool": "$POOL", "poolSize": $POOL_SIZE }$FAKEDNS6 ],

  "dns": {
    $DNSHOSTS
    "servers": [$DNSBOOT
      "$DNS_UP",$DNS_UP2LINE
      {
        "address": "fakedns",
        "domains": [
HEAD
      # Через файл: список в переменной ash -- 9,5 МБ на потолке пресета (200
      # 000 доменов), при подстановке вдвое больше, а на 240 МБ рядом работает
      # движок, и OOM убил бы его.
      _fdf=/tmp/byway-fakedns.json
      list_to_json "$MERGED" "domain:" > "$_fdf" 2>/dev/null || : > "$_fdf"
      # Запятая -- только если перед ней что-то есть: на пустом списке «[ ,
      # "full:…" ]» движок отвергал конфиг целиком.
      [ -s "$_fdf" ] && { cat "$_fdf"; printf ',\n'; } || true
      rm -f "$_fdf" 2>/dev/null || true
      # Проба -- и сюда: без fakeip клиент ушёл бы мимо перехвата, и проверка
      # судила бы не о туннеле.
      printf '          "full:%s"' "$PROBE_DOMAIN"
      cat <<MID

        ]
      }
    ],
    "queryStrategy": "$QSTRAT"$DNSTAG
  },

  "inbounds": [
    {
      "tag": "dns-in",
      "listen": "$DNS_LISTEN",
      "port": 53,
      "protocol": "dokodemo-door",
      "settings": { "address": "$DNS_LISTEN", "port": 53, "network": "tcp,udp" }
    },
    {
      "tag": "tproxy-in",
      // 0.0.0.0, а не петля: tproxy НЕ переписывает адрес назначения, пакет
      // доходит до сокета с исходным 198.18.x.x. Сокет, привязанный к
      // 127.0.0.1, такой пакет не поймает никогда — правила срабатывают,
      // счётчик растёт, наружу не идёт ничего. Стоило часа 2026-09-03.
      // При включённом IPv6 -- "::" вместо "0.0.0.0": отсутствие поля и
      // "0.0.0.0" у Xray значат СТРОГО IPv4 (infra/conf/xray.go, AnyIP), и
      // пакет v6 до сокета не дошёл бы вовсе. Сокет на "::" двухсемейный,
      // пока sockopt.V6Only не выставлен, -- перехват IPv4 не теряется.
      "listen": "$TP_LISTEN",
      "port": $TP_PORT,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": true, "destOverride": [ "fakedns", "http", "tls", "quic" ], "metadataOnly": false, "routeOnly": false }
    },
    {
      // Прокси для САМОГО РОУТЕРА. Правила nft стоят в prerouting и ловят
      // только трафик из мостов; собственный трафик роутера идёт через
      // output и до tproxy не доходит. Значит роутер не может достучаться
      // ни до одного домена из списка -- его резолвер честно отдаёт адрес
      // из пула, а маршрута туда нет.
      //
      // Ломало это не абстракцию, а дело: zms-pin.sh и штатные обновлялки
      // списков zapret тянут файлы с github, а github в списке.
      //
      // Вход остаётся и при включённом заворачивании (router_via_vpn): он
      // работает без единого правила в ядре и потому годится там, где
      // правил ещё нет или они запрещены -- в том числе самому обновлению
      // byway, которому надо скачать себя новым до того, как правила
      // переложат.
      //
      // ⚠️ Обратных кавычек в этом комментарии быть не может. Он идёт в
      // конфиг из heredoc БЕЗ кавычек у метки, то есть оболочка разбирает
      // его как обычную строку: команду в обратных кавычках она ВЫПОЛНИТ, и
      // вывод команды уедет в середину JSON. Так и вышло 2026-09-07 --
      // движок отверг конфиг с «invalid character », а byway при каждой
      // сборке лез в сеть за новой версией себя.
      //
      // Пользоваться так:
      //   https_proxy=http://127.0.0.1:$LOCAL_PORT curl ...
      //   busybox wget по https через прокси не ходит
      // Маршрутизация обычная: домен из списка уйдёт через ноду, прочее
      // напрямую.
      "tag": "local-in",
      "listen": "127.0.0.1",
      "port": $LOCAL_PORT,
      "protocol": "http",
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls" ], "metadataOnly": false, "routeOnly": false }
    }$REDIR_IN
  ],

  "outbounds": [
$PROXIES,$ROUTE_OUT
    { "tag": "direct", "protocol": "freedom"$DIRECT_SET$DIRECTSO },
    { "tag": "dns-out", "protocol": "dns"$SELFSO },
    { "tag": "block", "protocol": "blackhole" }
  ],

  $OBSERVATORY

  "routing": {
    $BALANCERS
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": [ "dns-in" ], "outboundTag": "dns-out" },$DNSRULE$ROUTE_RULES
MID
      if [ "$(u list_mode)" = "all" ]; then
        # Режим «всё через VPN»: списки не участвуют, направление задаёт
        # последнее правило, исключение одно -- сам сервер VPN: иначе его адрес
        # ушёл бы в тот же ещё не поднятый VPN, и соединение не встаёт без
        # ошибки в журнале.
        # Русские зоны мимо туннеля: банки, госуслуги и маркетплейсы через VPN
        # ломаются. .рф -- пуникодом (xn--p1ai): в DNS и SNI идёт он.
        if [ "$(u ru_direct)" = "1" ]; then
          printf '      { "type": "field", "domain": [ "domain:ru", "domain:su", "domain:xn--p1ai" ], "outboundTag": "direct" },\n'
        fi

        for _h in $VPN_HOSTS; do
          # Не похожее на имя или адрес движок отвергнет вместе со всем
          # конфигом.
          case "$_h" in
            ''|-|*[!A-Za-z0-9.:_-]*) continue ;;
          esac
          case "$_h" in
            *[a-zA-Z]*) printf '      { "type": "field", "domain": [ "full:%s" ], "outboundTag": "direct" },\n' "$_h" ;;
            *)          printf '      { "type": "field", "ip": [ "%s/32" ], "outboundTag": "direct" },\n' "$_h" ;;
          esac
        done
      else
        # Пустой список -- не повод писать правило с пустым массивом: Xray
        # такой конфиг отвергает.
        # Через файл: список печатается дважды (fakedns и здесь), а в
        # переменной ash на потолке пресета это 9,5 МБ, при подстановке вдвое
        # больше -- на 240 МБ, где рядом работает движок.
        _djf=/tmp/byway-dom.json
        list_to_json "$MAINDOM" "domain:" > "$_djf" 2>/dev/null || : > "$_djf"
        # Домен-проба -- всегда, даже при пустом списке: через него проверка
        # «трафик проходит» смотрит всю цепочку и не зависит от меняющегося
        # списка. example.com закреплён IANA под примеры, заворот его ничего не
        # стоит.
        printf '      { "type": "field", "domain": [\n'
        [ -s "$_djf" ] && { cat "$_djf"; printf ',\n'; }
        printf '          "full:%s"\n' "$PROBE_DOMAIN"
        printf '        ], %s },\n' "$PROXY_TARGET"
        rm -f "$_djf" 2>/dev/null || true
        if [ -f "$S" ] && [ "$(count_list "$S")" -gt 0 ]; then
          printf '      { "type": "field", "ip": [\n'
          list_to_json "$S" ""
          printf '\n        ], %s },\n' "$PROXY_TARGET"
        fi
      fi
      cat <<MID2
MID2
      cat <<END
      // Приватное и зарезервированное -- в блок, и ОБЯЗАТЕЛЬНО до direct.
      // Без этого вход tproxy работал открытым форвардером: клиент из
      // гостевой сети открывал соединение на любой адрес пула и первым же
      // пакетом слал «Host: 192.168.1.1». Сниффер подменял назначение на
      // то, что написал клиент, а наружу шёл САМ РОУТЕР -- то есть мимо
      // forward-цепочки, где гостей режет reject. Изоляция гостевой сети
      // обходилась целиком.
      //
      // Сюда же входит сам пул fakeip: соединение на порт входа замыкалось
      // на этот же вход и порождало витки без ограничителя, пока не кончатся
      // дескрипторы.
      // Пул подставляется переменной, а не литералом: он настраивается в
      // панели, и со своим значением защита от петли перечисляла бы чужой
      // диапазон, а нужный оставляла открытым.
      { "type": "field", "ip": [
          "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
          "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
          "$POOL", "224.0.0.0/4", "240.0.0.0/4"$BLOCK6
        ], "outboundTag": "block" },
      { "type": "field", "network": "tcp,udp", $LAST_TARGET }
    ]
  }
}
END
    } > "$TMP"
    return 0
}

cmd_show() {
    [ -f "$OUT" ] || die "конфиг не собран, собрать: byway gen"
    sayf "%s — %s байт" "$OUT" "$(wc -c < "$OUT")"
    # Счётчики -- первыми: ради них команду зовут. Считаем по источнику: список
    # печатается в конфиг дважды (fakedns и маршрут), и счёт по «"domain:»
    # завышал вдвое, непостоянно (зависит от записей с префиксом).
    printf "$(_t '    доменов в правиле: %s\n')" "$(count_list "$(merged_domains)")"
    printf "$(_t '    подсетей:          %s\n')" "$(count_list "$(merged_subnets)")"
    grep -oE '"(tag|protocol|network|security|address|ipPool)": *"[^"]*"' "$OUT" |
      grep -viE 'uuid|id"' | sed 's/^/    /' | head -20
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
