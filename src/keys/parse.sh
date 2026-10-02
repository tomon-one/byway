# Разбор ключа (vless, vmess, trojan, ss, socks, hysteria2, wireguard) в
# переменные N_*. Сам разборщик -- keys/parse.uc, сборка вставляет его в parse_uc.

# Раскодирование процентов; эмодзи -- те же байты UTF-8. Для меток ключей;
# сам ключ раскодирует parse_uc.
pctd() {
    printf '%b' "$(printf '%s' "$1" | sed 's/%/\\x/g')" 2>/dev/null || printf '%s' "$1"
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

    # Разбор -- в ucode, на выходе команды sh: присваивания и те же
    # warn/dief, что печатал разбор на sh. eval -- только вывода parse_uc,
    # значения в нём в одинарных кавычках.
    _pn=$(BW_URL=$URL BW_SNI=${N_SNI:-} BW_WSHOST=${N_WSHOST:-}; export BW_URL BW_SNI BW_WSHOST
          parse_uc) || die "ключ не разобрался: сбой разборщика (ucode)"
    eval "$_pn"

    # Шифрование VLESS (mlkem768x25519plus) -- с Xray-core 25.8.29; форму уже
    # проверил parse_uc, разбор частей -- за ядром (run -test).
    if [ -n "$N_ENC" ] && [ "$N_ENC" != "none" ]; then
        xray_ver_num >/dev/null
        if [ "$XRAYVER" -lt 250829 ]; then
            dief "шифрование VLESS (encryption=mlkem768x25519plus) появилось в Xray-core 25.8.29, а стоит %s — обновить: byway engine tested" \
                 "$("$XRAY" version 2>/dev/null | head -1 | cut -d' ' -f2)"
        fi
    fi

    # Порт идёт в JSON числом без кавычек.
    port_ok "$N_PORT" || dief "порт в ссылке недопустим: %s" "$N_PORT"
}

# Разборщик ссылки на ucode: ссылка -- в BW_URL, на выход -- команды sh.
# Значения из ссылки уходят в конфиг внутрь строк JSON, поэтому кавычка,
# обратная косая и управляющие знаки в них -- отказ (node_json_ok): иначе
# ссылка дописывает в конфиг свои поля (sni=a.com%22%2C%22allowInsecure%22…).
# Ключи приходят из подписок и чужих каналов -- источник не доверенный.
# Подстановка $(...) в прежнем разборе срезала хвостовые переводы строки --
# nl() повторяет это, чтобы поведение не разошлось.
parse_uc() {
    ucode -S - <<'UC'
#@include keys/parse.uc
UC
}
