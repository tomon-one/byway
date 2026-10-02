# streamSettings аутбаунда: транспорт, защита (tls, reality), flow и mux.

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
           warn "mkcp идёт поверх UDP, а в РФ UDP душат первым делом"
           # header и seed у mKCP: до 26.1.23 работают; 26.1.31–26.6.27
           # отвергают («removed feature», конфиг не собирается); 26.9.x
           # принимают и молча не применяют -- без маскировки сервер не
           # ответит. С 26.1.31 не пишем и говорим (замена -- finalmask).
           _k=""
           if [ -n "$N_HDR" ]; then _k="\"header\": { \"type\": \"$N_HDR\" }"; fi
           if [ -n "$N_SEED" ]; then
               [ -n "$_k" ] && _k="$_k, "
               _k="$_k\"seed\": \"$N_SEED\""
           fi
           xray_ver_num >/dev/null
           if [ -n "$_k" ] && [ "${XRAYVER:-0}" -ge 260131 ]; then
               warn "header и seed у mkcp удалены в Xray-core с 26.1.31 и в конфиг не пишутся: сервер с маскировкой mKCP не ответит; замена на сервере и в ключе — finalmask (mkcp-original, mkcp-aes128gcm)"
               _k=""
           fi
           if [ -n "$_k" ]; then
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
               _fm=", \"finalmask\": { \"udp\": [ { \"type\": \"salamander\", \"settings\": { \"password\": $J_OBFSPW } } ] }"
           fi
           STREAM="\"network\": \"hysteria\", \"hysteriaSettings\": { \"version\": 2, \"auth\": $J_PASS }$_fm" ;;

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
