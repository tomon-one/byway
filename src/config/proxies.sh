# Аутбаунды целиком: один ключ, автовыбор (balancer), свой конфиг.

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
            # Метку для «VPN для программ на роутере» в чужой JSON не вписываем
            # (комментарии в нём ucode не разберёт) -- говорим, что дописать.
            if [ "$(u router_via_vpn)" = "1" ] && ! printf '%s' "$N_RAW" | grep -q '"mark"'; then
                warnf "свой конфиг: включено «VPN для программ на роутере», а метки в нём нет — если адрес сервера попадёт в списки, соединение движка к нему уйдёт в перехват по кругу; дописать в streamSettings поле sockopt.mark = %s" "$(self_mark_dec)"
            fi
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
