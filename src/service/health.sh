# byway health и проверки связи для сторожа и замены ядра (tunnel_ok, alive_ok
# -- пока на shell: их зовут watch и engine).

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
# Служба, VPN, трафик, DNS строками «ключ<таб>состояние<таб>подробность» --
# в ucode (uc/status.uc, cmd_health).
cmd_health() {
    BW_OUT=$OUT BW_XRAY=$XRAY BW_PROBE=$PROBE_DOMAIN bw_uc health
}
