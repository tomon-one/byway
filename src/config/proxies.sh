# Аутбаунды: разбор ключа, транспорт, защита и блок JSON -- в ucode
# (uc/outbound.uc); здесь вызов и eval его команд: N_*, блок, сообщения по
# порядку (как у разбора ключа).

# Метка исходящих для «VPN для программ на роутере» -- числом, пока перехват
# на shell. Последняя строка: self_mark печатает жалобы в тот же вывод.
ob_env_mark() {
    if [ "$(u router_via_vpn)" = "1" ]; then self_mark_dec | tail -1; fi
}

# Один ключ: N_*, блок PB, адреса сервера OB_HOSTS. 1 -- тег, 2 -- ссылка
# (пусто -- ключ или свой конфиг из настроек), 3 -- quiet: без сообщений
# разбора.
ob_eval() {
    xray_ver_num >/dev/null
    _obm=$(ob_env_mark)
    _obo=$(BW_URL=${2:-} BW_SNI=${N_SNI:-} BW_WSHOST=${N_WSHOST:-} \
           BW_XRAYVER=$XRAYVER BW_XRAY=$XRAY BW_SELFMARK=$_obm \
           bw_uc outbound "$1" "${3:-}") || die "аутбаунд не собрался: сбой ucode"
    eval "$_obo"
}

# Аутбаунды целиком: PROXIES, VPN_HOSTS, OBSERVATORY, BALANCERS,
# PROXY_TARGET, LAST_TARGET, PROXY_KEYIDX, _n, N_*. SKIP_KEYS -- ключи
# автовыбора, которые отверг сам движок (повтор сборки в cmd_gen).
build_proxies() {
    xray_ver_num >/dev/null
    _obm=$(ob_env_mark)
    _obo=$(BW_SKIP=${SKIP_KEYS:-} BW_SNI=${N_SNI:-} BW_WSHOST=${N_WSHOST:-} \
           BW_XRAYVER=$XRAYVER BW_XRAY=$XRAY BW_SELFMARK=$_obm \
           bw_uc proxies) || die "аутбаунд не собрался: сбой ucode"
    eval "$_obo"
}
