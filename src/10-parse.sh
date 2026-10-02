# Разбор ключа (vless, vmess, trojan, ss, socks, hysteria2, wireguard) в
# переменные N_* и аутбаунд из них. На диск ничего не пишет.

# ── разбор ссылки ──────────────────────────────────────────────────────────
# Значения из ссылки нигде не печатаются, только уходят в конфиг. Имена полей
# JSON сверены `xray run -test` на бинарнике: Xray молча глотает неизвестные
# поля, поэтому проверялось от обратного -- заведомо неверное значение даёт
# ошибку про это поле. Имена параметров В ССЫЛКЕ -- соглашение клиентов;
# незнакомые ловит предупреждение ниже.
KNOWN_PARAMS="type security sni fp alpn path host headerType seed serviceName mode authority pbk sid spx pqv flow encryption quicSecurity key extra allowInsecure insecure pinSHA256 pcs vcn"
# Параметры hysteria2 и wireguard -- отдельно: у чужой схемы они молча
# проходили бы как известные, а предупреждение нужно, чтобы человек узнал, что
# из ссылки не перенесено.
KNOWN_HY="obfs obfs-password mport"
KNOWN_WG="publickey privatekey secretkey pk peer_pk presharedkey pre_shared_key psk address local_address mtu reserved keepalive"

# base64 в busybox роутера нет: берём coreutils-base64, иначе b64d раскодирует
# awk. Судим запуском, не наличием файла: /bin/base64 бывает ссылкой на
# busybox, в котором апплета нет.
have_base64() { printf x | base64 >/dev/null 2>&1; }

b64d() {
    if have_base64; then
        # SIP002 (ss://) -- base64url без «=»: `base64 -d` такой вход
        # отвергает, а 2>/dev/null прячет отказ, и под set -e разбор убивал
        # byway молча. Добиваем «=» и переводим алфавит сами.
        _b6=$(printf '%s' "$1" | tr -d '\n\r' | tr '_-' '/+')
        case $(( ${#_b6} % 4 )) in
            2) _b6="$_b6==" ;;
            3) _b6="$_b6=" ;;
        esac
        printf '%s' "$_b6" | base64 -d 2>/dev/null || true
    else
        # Тот же результат байт в байт (сверено с base64 -d на busybox и gawk,
        # UTF-8). LC_ALL=C: иначе gawk печатает %c > 127 многобайтно.
        printf '%s' "$1" | tr '_-' '/+' | LC_ALL=C awk '
          BEGIN { a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
                  for (i = 0; i < 64; i++) v[substr(a, i + 1, 1)] = i }
          { s = s $0 }
          END { b = 0; n = 0
                for (i = 1; i <= length(s); i++) {
                  c = substr(s, i, 1)
                  if (c == "=") break
                  if (!(c in v)) continue
                  b = b * 64 + v[c]; n += 6
                  if (n >= 8) { n -= 8; o = int(b / 2 ^ n); b -= o * 2 ^ n; printf "%c", o }
                } }'
    fi
}

# Раскодирование процентов; эмодзи -- те же байты UTF-8.
pctd() {
    printf '%b' "$(printf '%s' "$1" | sed 's/%/\\x/g')" 2>/dev/null || printf '%s' "$1"
}

# Значения из ссылки уходят в JSON внутрь строк без экранирования: кавычка
# закрывает строку и дописывает свои поля (sni=a.com%22%2C%22allowInsecure%22
# %3Atrue… давало конфиг без проверки сертификата, `run -test` его принимал).
# Ключи приходят из подписок и чужих каналов -- источник не доверенный.
# Проверка ПОСЛЕ разбора, не внутри qp: die в $(...) убивает только
# подоболочку, и разбор шёл бы дальше с пустым полем.
node_json_ok() {
    for _pv in "адрес=$N_HOST" "id=$N_UUID" "пароль=$N_PASS" "user=$N_USER" \
               "method=$N_METHOD" "type=$N_TYPE" "security=$N_SEC" \
               "sni=${N_SNI:-}" "fp=$N_FP" "path=$N_PATH" "host=${N_WSHOST:-}" \
               "pbk=$N_PBK" "sid=$N_SID" "flow=$N_FLOW" "mode=$N_MODE" \
               "alpn=$N_ALPN" "headerType=$N_HDR" "seed=$N_SEED" \
               "serviceName=$N_SVC" "authority=$N_AUTH" "spx=$N_SPX" \
               "pqv=$N_PQV" "quicSecurity=$N_QSEC" "key=$N_QKEY" \
               "encryption=$N_ENC" "obfs-password=$N_OBFSPW" "pcs=$N_PIN" \
               "vcn=$N_VCN" "obfs=$N_OBFS" "privatekey=$N_WGKEY" \
               "publickey=$N_WGPUB" "presharedkey=$N_WGPSK" "address=$N_WGADDR" \
               "mtu=$N_WGMTU" "reserved=$N_WGRES" "keepalive=$N_WGKA"; do
        case "$_pv" in
          # Управляющие знаки -- первыми: qpr раскодирует %0A в перевод строки,
          # а проверки формы идут построчным grep -- первая строка проходит,
          # хвост уходит в конфиг (у reserved так дописывался второй peers;
          # Xray берёт последний).
          *[[:cntrl:]]*)
            dief "в поле «%s» ссылки управляющий знак (перевод строки, табуляция): такая ссылка подменяет поля конфига" "${_pv%%=*}" ;;
          *'"'*|*'\'*)
            dief "в поле «%s» ссылки кавычка или обратная косая: значения уходят в конфиг как есть, и такая ссылка подменяет его поля" "${_pv%%=*}" ;;
        esac
    done
}

# Ровно один объект JSON и ничего вокруг. Нужна для extra: он подставляется в
# конфиг ОБЪЕКТОМ, мимо node_json_ok. Значение `{} } }, "settings": {…}`
# закрыло бы xhttpSettings и streamSettings и дописало свой settings с чужим
# адресом без tls: скобки сбалансированы, `run -test` доволен, Xray берёт
# последний из повторных ключей. Вид скобок не различаем -- ядро отвергнет.
json_obj_ok() {
    printf '%s' "$1" | awk '
        { s = s $0 "\n" }
        END {
            d = 0; instr = 0; esc = 0; started = 0; closed = 0; ok = 1
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (instr) {
                    if (esc) esc = 0
                    else if (c == "\\") esc = 1
                    else if (c == "\"") instr = 0
                    continue
                }
                if (c == " " || c == "\t" || c == "\n" || c == "\r") continue
                if (!started) { if (c != "{") { ok = 0; break }
                                started = 1; d = 1; continue }
                if (closed) { ok = 0; break }
                if (c == "\"") { instr = 1; continue }
                if (c == "{" || c == "[") { d++; continue }
                if (c == "}" || c == "]") { d--
                                            if (d < 0) { ok = 0; break }
                                            if (d == 0) closed = 1
                                            continue }
            }
            if (instr || !started || !closed || d != 0) ok = 0
            print ok
        }'
}

parse_node() {
    # Режим «свой конфиг»: вставлен готовый кусок JSON Xray, разбирать нечего
    # (аналог Outbound Config у podkop).
    N_RAW=""
    if [ -z "${1:-}" ] && [ "$(u conn_mode)" = "outbound" ]; then
        N_RAW=$(u outbound_json)
        [ -n "$N_RAW" ] || die "выбран свой конфиг, но он пуст"
        N_PROTO=raw
        N_LABEL=$(u conn_label)
        [ -n "$N_LABEL" ] || N_LABEL=$(_t 'свой конфиг')
        N_TYPE="-"; N_SEC="-"; N_HOST="-"; N_PORT=0
        return 0
    fi

    URL=${1:-$(u node_url)}
    [ -n "$URL" ] || die "ключ не задан"

    N_SCHEME=${URL%%://*}
    case "$N_SCHEME" in
      vless|trojan|socks|vmess|ss|hysteria2|hy2|wireguard|wg) ;;
      # В Xray-core нет исходящего tuic, а hysteria -- только вторая версия
      # (сверено по исходникам 26.9.30).
      hysteria|tuic)
        dief "%s в Xray-core нет; из похожего есть hysteria2" "$N_SCHEME" ;;
      *) dief "неизвестный вид ссылки: %s" "$N_SCHEME" ;;
    esac

    _rest=${URL#*://}

    # Метка после решётки -- имя, обычно с флагом; не секрет.
    N_LABEL=""
    case "$URL" in *#*) N_LABEL=$(pctd "${URL#*#}") ;; esac
    _rest=${_rest%%#*}

    N_UUID=""; N_PASS=""; N_USER=""; N_METHOD=""; N_AID=0
    N_TYPE=tcp; N_SEC=none; N_PATH=/; N_FP=chrome
    N_PBK=""; N_SID=""; N_FLOW=""; N_MODE=""; N_ALPN=""
    N_HDR=""; N_SEED=""; N_SVC=""; N_AUTH=""; N_SPX=""; N_PQV=""
    N_ENC=""; N_QSEC=""; N_QKEY=""; N_EXTRA=""; N_INSEC=""
    N_OBFS=""; N_OBFSPW=""; N_PIN=""; N_VCN=""
    N_WGKEY=""; N_WGPUB=""; N_WGPSK=""; N_WGADDR=""; N_WGMTU=""; N_WGRES=""; N_WGKA=""
    _query=""

    if [ "$N_SCHEME" = "vmess" ]; then
        # vmess://<base64 от JSON>: add, port, id, aid, net, type, host, path,
        # tls, sni, scy.
        _j=$(b64d "$_rest")
        [ -n "$_j" ] || die "vmess-ссылка не раскодировалась"
        jf() { printf '%s' "$_j" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1; }
        N_HOST=$(jf add); N_PORT=$(jf port); N_UUID=$(jf id)
        case "$N_HOST" in *:*) dief "адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя" "$N_HOST" ;; esac
        # aid уходит в конфиг без кавычек -- только число.
        N_AID=$(jf aid); [ -n "$N_AID" ] || N_AID=0
        case "$N_AID" in *[!0-9]*) dief "aid у vmess — не число: %s" "$N_AID" ;; esac
        N_TYPE=$(jf net); [ -n "$N_TYPE" ] || N_TYPE=tcp
        N_PATH=$(jf path); [ -n "$N_PATH" ] || N_PATH=/
        N_WSHOST=$(jf host)
        # type=none клиенты пишут почти всегда; свежее ядро отвергает его как
        # заголовок mkcp, поэтому «нет заголовка» -- пусто.
        N_HDR=$(jf type); [ "$N_HDR" = none ] && N_HDR=""
        [ "$(jf tls)" = "tls" ] && N_SEC=tls
        N_SNI=$(jf sni); [ -n "$N_SNI" ] || N_SNI=${N_WSHOST:-$N_HOST}
        [ -n "$N_WSHOST" ] || N_WSHOST=$N_HOST
        # scy -- шифрование vmess; alpn и fp -- для TLS.
        N_METHOD=$(jf scy)
        case "$N_METHOD" in
          ""|auto|aes-128-gcm|chacha20-poly1305|none|zero) ;;
          *) dief "scy=%s у vmess Xray-core не знает: есть auto, aes-128-gcm, chacha20-poly1305, none, zero" "$N_METHOD" ;;
        esac
        # alpn -- через запятую внутри строки, а jf режет на запятой.
        N_ALPN=$(printf '%s' "$_j" | sed -n 's/.*"alpn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        _v=$(jf fp); [ -n "$_v" ] && N_FP=$_v
        # У vmess имя сервиса gRPC лежит в path (v2rayN и др.). Сырой path, не
        # N_PATH: в нём пустой заменён на «/».
        if [ "$N_TYPE" = "grpc" ]; then N_SVC=$(jf path); fi
        N_PROTO=vmess
        node_json_ok
        # Порт -- единственное поле без кавычек в JSON; vmess и ss возвращаются
        # до общей проверки в конце и проверяют его сами.
        port_ok "$N_PORT" || dief "порт в ссылке недопустим: %s" "$N_PORT"
        return 0
    fi

    if [ "$N_SCHEME" = "ss" ]; then
        # ss://<base64 метод:пароль>@host:port и ss://метод:пароль@host:port; в
        # старой форме в base64 вся ссылка.
        case "$_rest" in *@*) ;; *)
            _rest=$(b64d "${_rest%%\?*}")
            case "$_rest" in *@*) ;; *) die "ss-ссылка не разобралась" ;; esac ;;
        esac
        # Делим по последней «@»: в открытом пароле она законна.
        _ui=${_rest%@*}
        _hp=${_rest##*@}
        # Плагин (obfs-local, v2ray-plugin) Xray-core не запускает, сервер с
        # плагином не ответит -- говорим вслух.
        case "$_hp" in *plugin=*)
            warn "plugin у shadowsocks не переносится: Xray-core плагины не запускает, сервер с плагином не ответит" ;;
        esac
        _hp=${_hp%%\?*}
        _hp=${_hp%%/*}
        case "$_ui" in
          *:*) _plain=$(pctd "$_ui") ;;
          *)   _plain=$(b64d "$_ui") ;;
        esac
        case "$_hp" in \[*) dief "адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя" "$_hp" ;; esac
        N_METHOD=${_plain%%:*}
        N_PASS=${_plain#*:}
        N_HOST=${_hp%%:*}
        N_PORT=${_hp##*:}
        N_PROTO=shadowsocks
        # Порт по умолчанию, как в общей ветке: без порта ${_hp##*:} отдаёт сам
        # адрес, и в конфиг уходило бы "port": example.com.
        if [ "$N_PORT" = "$N_HOST" ]; then N_PORT=443; fi
        node_json_ok
        port_ok "$N_PORT" || dief "порт в ссылке недопустим: %s" "$N_PORT"
        return 0
    fi

    # Остальные схемы -- всё в адресе открытым текстом
    _ui=${_rest%%@*}
    _rest2=${_rest#*@}
    # Без «@» части до неё нет: wg-ссылки Hiddify и hysteria2 без пароля несут
    # всё в параметрах.
    case "$_rest" in *@*) ;; *) _ui="" ;; esac
    _hostport=${_rest2%%\?*}
    # hysteria2 пишет «host:port/?sni=…» -- косая перед вопросом не порт.
    _hostport=${_hostport%%/*}
    # IPv6 не поддержан: [2001:db8::1]:443 резался бы по первому двоеточию.
    case "$_hostport" in \[*) dief "адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя" "$_hostport" ;; esac
    N_HOST=${_hostport%%:*}
    N_PORT=${_hostport##*:}
    if [ "$N_PORT" = "$N_HOST" ]; then N_PORT=443; fi
    _query=${_rest2#*\?}
    if [ "$_query" = "$_rest2" ]; then _query=""; fi

    case "$N_SCHEME" in
      vless)  N_UUID=$_ui; N_PROTO=vless ;;
      trojan) N_PASS=$(pctd "$_ui"); N_PROTO=trojan ;;
      hysteria2|hy2) N_PASS=$(pctd "$_ui"); N_PROTO=hysteria ;;
      wireguard|wg)  N_WGKEY=$(pctd "$_ui"); N_PROTO=wireguard ;;
      socks)  _su=$(pctd "$_ui")
              # Часть клиентов кладёт «логин:пароль» в base64
              # (socks://dXNlcjpwYXNz@…); без расшифровки они пропадали молча.
              case "$_su" in
                *:*|"") ;;
                *) _sd=$(b64d "$_su")
                   case "$_sd" in *:*) _su=$_sd ;; esac ;;
              esac
              N_USER=${_su%%:*}; N_PASS=${_su#*:}
              [ "$N_USER" = "$_su" ] && { N_USER=""; N_PASS=""; }
              N_PROTO=socks ;;
    esac

    # Раскодируем целиком: кавычку, косую и управляющие знаки после разбора
    # отсекает node_json_ok. Частичное раскодирование превращало путь v2rayN
    # `%2F%3Fed%3D2048` в `/%3Fed=2048`: Xray не находил ed, ответ 404.
    qp() { pctd "$(printf '%s' "$_query" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1)"; }
    # Частичное раскодирование -- только для extra: скобки и кавычки там
    # законны, объект проверяет json_obj_ok.
    qp_part() {
        printf '%s' "$_query" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 |
          sed 's/%2F/\//g; s/%3A/:/g; s/%2C/,/g; s/%20/ /g;
               s/%3D/=/g; s/%26/\&/g'
    }
    # extra -- единственный параметр, который по замыслу приходит объектом
    # JSON; раскодируется отдельно и обязан пройти json_obj_ok ниже.
    qp_json() {
        qp_part "$1" | sed 's/%7B/{/g; s/%7D/}/g; s/%22/"/g; s/%5B/[/g; s/%5D/]/g'
    }
    _v=$(qp type);     [ -n "$_v" ] && N_TYPE=$_v
    # trojan без TLS не бывает, клиенты security часто опускают: пустой давал
    # none, и свежее ядро отвергало ключ к публичному адресу.
    [ "$N_PROTO" = "trojan" ] && N_SEC=tls
    _v=$(qp security); [ -n "$_v" ] && N_SEC=$_v
    N_SNI=$(qp sni);   [ -n "$N_SNI" ] || N_SNI=$N_HOST
    _v=$(qp fp);       [ -n "$_v" ] && N_FP=$_v
    _v=$(qp path);     [ -n "$_v" ] && N_PATH=$_v
    N_WSHOST=$(qp host); [ -n "$N_WSHOST" ] || N_WSHOST=$N_HOST
    N_PBK=$(qp pbk); N_SID=$(qp sid); N_FLOW=$(qp flow)
    # flow у trojan в конфиг не пишется, а mux при нём отключался.
    if [ "$N_PROTO" = trojan ] && [ -n "$N_FLOW" ]; then
        warnf "flow=%s у trojan Xray-core не поддерживает — пропущен" "$N_FLOW"; N_FLOW=""
    fi
    N_MODE=$(qp mode); N_ALPN=$(qp alpn); N_HDR=$(qp headerType)
    N_SEED=$(qp seed); N_SVC=$(qp serviceName); N_AUTH=$(qp authority)
    N_SPX=$(qp spx); N_PQV=$(qp pqv); N_ENC=$(qp encryption)
    N_QSEC=$(qp quicSecurity); N_QKEY=$(qp key); N_EXTRA=$(qp_json extra)
    N_INSEC=$(qp allowInsecure); [ -n "$N_INSEC" ] || N_INSEC=$(qp insecure)
    # pcs -- имя у v2rayN, pinSHA256 -- у hysteria2; значение одно и то же.
    N_PIN=$(qp pcs); [ -n "$N_PIN" ] || N_PIN=$(qp pinSHA256)
    N_VCN=$(qp vcn)
    # Без частичного раскодирования: пароли и ключи бывают с любыми знаками.
    # Полный pctd безопасен: результат проходит node_json_ok и образцы ниже.
    qpr() { pctd "$(printf '%s' "$_query" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1)"; }
    # Первый непустой из нескольких имён параметра (v2rayN -- publickey,
    # Hiddify -- peer_pk).
    qpa() { for _qn in "$@"; do _qv=$(qpr "$_qn"); [ -n "$_qv" ] && { printf '%s' "$_qv"; return 0; }; done; return 0; }

    if [ "$N_PROTO" = "hysteria" ]; then
        # Транспорт hysteria всегда под TLS: без tlsSettings ядро не
        # соединяется («tls config is nil»).
        N_TYPE=hysteria; N_SEC=tls
        # uTLS-отпечаток -- для TLS поверх TCP; у QUIC его нет.
        N_FP=""
        [ -n "$N_ALPN" ] || N_ALPN=h3
        # Диапазон портов (mport или «host:20000-30000») Xray-core через
        # hysteriaSettings не берёт; соединение идёт на первый порт.
        case "$N_PORT" in
          *[,-]*) warnf "диапазон портов в ключе не переносится: соединение идёт на порт %s" "${N_PORT%%[,-]*}"
                  N_PORT=${N_PORT%%[,-]*} ;;
        esac
        _v=$(qp obfs)
        case "$_v" in
          ""|none) ;;
          salamander) N_OBFS=salamander; N_OBFSPW=$(qpr obfs-password)
                      [ -n "$N_OBFSPW" ] || die "obfs=salamander без obfs-password: пароль обфускации обязателен" ;;
          *) dief "obfs=%s у hysteria2 не поддержан: в Xray-core есть только salamander" "$_v" ;;
        esac
        if [ -n "$(qp mport)" ]; then
            warn "mport (смена портов) не переносится: соединение идёт на основной порт из ключа"
        fi
    fi

    if [ "$N_PROTO" = "wireguard" ]; then
        N_TYPE=wireguard; N_SEC=none
        [ -n "$N_WGKEY" ] || N_WGKEY=$(qpa privatekey secretkey pk)
        N_WGPUB=$(qpa publickey peer_pk)
        N_WGPSK=$(qpa presharedkey pre_shared_key psk)
        N_WGADDR=$(qpa address local_address | tr -d ' ')
        N_WGMTU=$(qp mtu); N_WGRES=$(qpr reserved | tr -d ' '); N_WGKA=$(qp keepalive)
        # Ключи -- base64 на 32 байта либо hex (ParseWireGuardKey); образец
        # строгий: значение уходит в конфиг.
        wgkey_ok() { printf '%s' "$1" | grep -Eq '^([A-Za-z0-9+/]{43}=|[0-9a-fA-F]{64})$'; }
        wgkey_ok "$N_WGKEY" || die "в ключе wireguard нет закрытого ключа либо он не той формы (base64 на 44 знака либо 64 шестнадцатеричных)"
        wgkey_ok "$N_WGPUB" || die "в ключе wireguard нет публичного ключа сервера (publickey) либо он не той формы"
        [ -z "$N_WGPSK" ] || wgkey_ok "$N_WGPSK" || die "presharedkey в ключе wireguard не той формы"
        # Без своего адреса в туннеле ядро ставит 10.0.0.1, сервер такого
        # клиента не узнаёт, и соединение молча не идёт.
        [ -n "$N_WGADDR" ] || die "в ключе wireguard нет address -- адреса этого клиента в туннеле"
        printf '%s' "$N_WGADDR" | grep -Eq '^[0-9a-fA-F.:]+(/[0-9]{1,3})?(,[0-9a-fA-F.:]+(/[0-9]{1,3})?)*$' ||
            dief "address в ключе wireguard не похож на список адресов: %s" "$N_WGADDR"
        [ -z "$N_WGMTU" ] || printf '%s' "$N_WGMTU" | grep -Eq '^[0-9]{3,4}$' ||
            dief "mtu в ключе wireguard -- не число: %s" "$N_WGMTU"
        [ -z "$N_WGRES" ] || printf '%s' "$N_WGRES" | grep -Eq '^[0-9]{1,3},[0-9]{1,3},[0-9]{1,3}$' ||
            dief "reserved в ключе wireguard -- не три числа через запятую: %s" "$N_WGRES"
        [ -z "$N_WGKA" ] || printf '%s' "$N_WGKA" | grep -Eq '^[0-9]{1,5}$' ||
            dief "keepalive в ключе wireguard -- не число: %s" "$N_WGKA"
    fi
    if [ -n "$N_PIN" ]; then
        printf '%s' "$N_PIN" | grep -Eq '^[0-9a-fA-F:,]+$' ||
            dief "отпечаток сертификата (pcs, pinSHA256) -- не шестнадцатеричный: %s" "$N_PIN"
    fi
    if [ -n "$N_VCN" ]; then
        printf '%s' "$N_VCN" | grep -Eq '^[A-Za-z0-9.,*-]+$' ||
            dief "имя для проверки сертификата (vcn) -- не имя хоста: %s" "$N_VCN"
    fi
    node_json_ok
    # extra идёт в конфиг объектом, мимо проверки на кавычку выше, и
    # проверяется своей.
    if [ -n "$N_EXTRA" ] && [ "$(json_obj_ok "$N_EXTRA")" != "1" ]; then
        die "параметр extra в ссылке -- не один объект JSON: он подставляется в конфиг как есть, и такая ссылка переписывает соседние поля, включая адрес сервера и защиту"
    fi

    case "$N_PROTO" in
      hysteria)  _known="$KNOWN_PARAMS $KNOWN_HY" ;;
      wireguard) _known="$KNOWN_PARAMS $KNOWN_WG" ;;
      *)         _known=$KNOWN_PARAMS ;;
    esac
    for _pn in $(printf '%s' "$_query" | tr '&' '\n' | sed 's/=.*//' | grep . ); do
        case " $_known " in
          *" $_pn "*) ;;
          *) warnf "параметр ссылки «%s» byway в конфиг не переносит — стоит проверить, важен ли он" "$_pn" ;;
        esac
    done

    # Шифрование VLESS (mlkem768x25519plus) -- с Xray-core 25.8.29. Форму
    # проверяем образцом, разбор частей оставляем ядру: run -test отвергнет
    # негодное до подмены рабочего конфига.
    if [ -n "$N_ENC" ] && [ "$N_ENC" != "none" ]; then
        [ "$N_PROTO" = "vless" ] ||
            dief "encryption=%s бывает только у vless" "$N_ENC"
        printf '%s' "$N_ENC" | grep -Eq '^mlkem768x25519plus\.[A-Za-z0-9._+/=-]+$' ||
            dief "encryption=%s не поддержан: Xray-core знает только mlkem768x25519plus" "$N_ENC"
        xray_ver_num >/dev/null
        if [ "$XRAYVER" -lt 250829 ]; then
            dief "шифрование VLESS (encryption=mlkem768x25519plus) появилось в Xray-core 25.8.29, а стоит %s — обновить: byway engine tested" \
                 "$("$XRAY" version 2>/dev/null | head -1 | cut -d' ' -f2)"
        fi
    fi

    # Общая проверка порта: в JSON он идёт числом без кавычек.
    port_ok "$N_PORT" || dief "порт в ссылке недопустим: %s" "$N_PORT"
}

# Блок аутбаунда под свой протокол.
build_outbound() {
    case "$N_PROTO" in
      vless)
        OUTBOUND="\"protocol\": \"vless\", \"settings\": { \"vnext\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT, \"users\": [ { \"id\": \"$N_UUID\", \"encryption\": \"${N_ENC:-none}\"$FLOWJ } ] } ] }" ;;
      hysteria)
        OUTBOUND="\"protocol\": \"hysteria\", \"settings\": { \"version\": 2, \"address\": \"$N_HOST\", \"port\": $N_PORT }" ;;
      wireguard)
        # address -- список через запятую, уже сверенный образцом в parse_node.
        _wa=$(printf '%s' "$N_WGADDR" | sed 's/,/", "/g')
        _wp="\"publicKey\": \"$N_WGPUB\", \"endpoint\": \"$N_HOST:$N_PORT\""
        if [ -n "$N_WGPSK" ]; then _wp="$_wp, \"preSharedKey\": \"$N_WGPSK\""; fi
        if [ -n "$N_WGKA" ]; then _wp="$_wp, \"keepAlive\": $N_WGKA"; fi
        _wo=""
        if [ -n "$N_WGMTU" ]; then _wo=", \"mtu\": $N_WGMTU"; fi
        if [ -n "$N_WGRES" ]; then _wo="$_wo, \"reserved\": [ $N_WGRES ]"; fi
        # noKernelTun: wireguard внутри процесса, не интерфейсом ядра. С
        # 24.11.30 Xray по умолчанию поднимает wg0 через /dev/net/tun: без
        # kmod-tun «CreateTUN failed» (стенд 25.12.5, 2026-10-01), с ним
        # появляется интерфейс, неизвестный маршрутизации. Старые версии поле
        # игнорируют.
        OUTBOUND="\"protocol\": \"wireguard\", \"settings\": { \"noKernelTun\": true, \"secretKey\": \"$N_WGKEY\", \"address\": [ \"$_wa\" ], \"peers\": [ { $_wp } ]$_wo }" ;;
      vmess)
        OUTBOUND="\"protocol\": \"vmess\", \"settings\": { \"vnext\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT, \"users\": [ { \"id\": \"$N_UUID\", \"alterId\": ${N_AID:-0}, \"security\": \"${N_METHOD:-auto}\" } ] } ] }" ;;
      trojan)
        OUTBOUND="\"protocol\": \"trojan\", \"settings\": { \"servers\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT, \"password\": \"$N_PASS\" } ] }" ;;
      shadowsocks)
        OUTBOUND="\"protocol\": \"shadowsocks\", \"settings\": { \"servers\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT, \"method\": \"$N_METHOD\", \"password\": \"$N_PASS\" } ] }" ;;
      socks)
        _su=""
        if [ -n "$N_USER" ]; then
          _su=", \"users\": [ { \"user\": \"$N_USER\", \"pass\": \"$N_PASS\" } ]"
        fi
        OUTBOUND="\"protocol\": \"socks\", \"settings\": { \"servers\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT$_su } ] }" ;;
      *) dief "протокол %s не собран" "$N_PROTO" ;;
    esac
}
