# Запрет «Не пускать мимо VPN»: dnsmasq и nft закрывают список, пока нет туннеля.

# ── kill switch ────────────────────────────────────────────────────────────
# Закрытая модель (on_failure): без туннеля нет и доступа к списку. Домены --
# через dnsmasq (address=/домен/ в его каталоге добавок, тот в памяти): без
# движка резолвер отдаёт настоящие адреса, по адресу домен не узнать.
# Подсети -- правилами nft. Каталог добавок берётся из конфига dnsmasq: в имени
# хеш секции UCI (/tmp/dnsmasq.cfg01411c.d), после сброса он другой.
BLOCK_MARK=/tmp/byway-blocked

block_on() {
    # Открытая модель: запрет, оставшийся от закрытой, снимается здесь. Иначе
    # переключение на open при падающем движке его не снимало: подъём не
    # проходит, сторож снимает обвязку с --keep-block (Д-2, 2026-10-04).
    if [ "$(u on_failure)" = "open" ]; then
        [ -f "$BLOCK_MARK" ] && block_off
        return 0
    fi
    _ifs=$(eff_ifs)
    _ifl=$(echo "$_ifs" | awk '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1?", ":""), $i}')
    # Стоящий запрет пересобирается на месте, если сменились режим, сети, IPv6
    # или списки.
    _bsig=$( { u list_mode; echo "$_ifs"; v6on && echo v6; cat "$(merged_domains)" "$(merged_subnets)" 2>/dev/null; } | md5sum | cut -c1-32)
    # И стоит ли он в ядре: чужой `nft flush ruleset` снимал таблицу, а запрет
    # по файлам в /tmp числился стоящим.
    if [ -f "$BLOCK_MARK" ] && [ "$(cat "$BLOCK_MARK.sig" 2>/dev/null)" = "$_bsig" ] &&
       block_intact; then
        return 0
    fi
    printf '%s\n' "$_bsig" > "$BLOCK_MARK.sig"

    # Режим «всё через VPN» закрывается отдельным правилом, не выжимкой из
    # списков: в этом режиме поставочные списки пусты, запрет не закрыл бы
    # ничего, а статус сообщил бы «доступ закрыт». Цепляется к forward, не к
    # output: движок должен достучаться до ноды, LuCI и ssh идут через input.
    # oifname пропускает свои мосты. Цепочка `forward`, не `fwd`: fwd
    # зарезервировано в nft, и ядро отвергает всю таблицу.
    if [ "$(u list_mode)" = "all" ]; then
        # Остаток режима списков (имена) здесь не нужен.
        _cdir=$(dnsmasq_confdir)
        if [ -n "$_cdir" ] && [ -f "$_cdir/byway-block.conf" ]; then
            rm -f "$_cdir/byway-block.conf"
            /etc/init.d/dnsmasq restart >/dev/null 2>&1
        fi
        # Прелюдия table/delete -- замена одной транзакцией (см. nft_ruleset).
        _nfterr=$(nft -f - 2>&1 <<NFTA || true
table inet ${TABLE}_block
delete table inet ${TABLE}_block
table inet ${TABLE}_block {
	set privnets {
		type ipv4_addr
		flags interval
		elements = { $RESERVED }
	}
	chain forward {
		type filter hook forward priority filter - 5; policy accept;
		iifname != { $_ifl } return
		oifname { $_ifl } return
		ip daddr @privnets return
		counter reject
	}
}
NFTA
)
        [ -n "$_nfterr" ] && warnf "«не пускать мимо VPN»: ядро не приняло правило — %s" \
            "$(printf '%s' "$_nfterr" | head -2 | tr '\n' ' ')"
        if nft list table inet "${TABLE}_block" >/dev/null 2>&1; then
            printf 'all\n' > "$BLOCK_MARK"
            printf 'table\n' > "$BLOCK_MARK.parts"
            # Не «весь трафик»: цепочка отсекает сети вне byway.main.interface.
            warn "туннеля нет, и трафик перечисленных сетей мимо VPN закрыт: так велит настройка «не пускать мимо VPN». Сети вне byway.main.interface запрет не закрывает"
        else
            # Молчать здесь нельзя: человек включил запрет и вправе знать, что
            # его нет.
            printf 'none\n' > "$BLOCK_MARK"; rm -f "$BLOCK_MARK.parts" 2>/dev/null
            warn "«не пускать мимо VPN»: ядро не приняло правило запрета — трафик идёт НАПРЯМУЮ"
        fi
        return 0
    fi
    block_dns
    block_nets
    if [ -n "$_nets" ] || [ -n "$_nets6" ]; then
        _nfterr=$(nft -f - 2>&1 <<NFTB || true
table inet ${TABLE}_block
delete table inet ${TABLE}_block
table inet ${TABLE}_block {$_b4set$_b6set
	chain forward {
		type filter hook forward priority filter - 5; policy accept;
		iifname != { $_ifl } return$_b4rule$_b6rule
	}
}
NFTB
)
        [ -n "$_nfterr" ] && warnf "«не пускать мимо VPN»: подсети закрыть не вышло — %s" \
            "$(printf '%s' "$_nfterr" | head -2 | tr '\n' ' ')"
        nft list table inet "${TABLE}_block" >/dev/null 2>&1 && _bl_net=1
    else
        nft delete table inet "${TABLE}_block" 2>/dev/null || true
    fi
    # Строка про закрытый доступ -- только когда есть что закрывать.
    if [ "${_bl_dom:-0}" -gt 0 ] || [ "${_bl_net:-0}" = 1 ]; then
        printf 'lists\n' > "$BLOCK_MARK"
        { [ "${_bl_dom:-0}" -gt 0 ] && echo conf; [ "${_bl_net:-0}" = 1 ] && echo table; } > "$BLOCK_MARK.parts"
        warnf "туннеля нет, и доступ к списку закрыт: доменов %s, подсети %s" \
              "$_bl_dom" "$([ "${_bl_net:-0}" = 1 ] && _t да || _t нет)"
    else
        printf 'none\n' > "$BLOCK_MARK"; rm -f "$BLOCK_MARK.parts" 2>/dev/null
        warn "«не пускать мимо VPN» включено, но закрывать нечего: списки пусты — трафик идёт НАПРЯМУЮ"
    fi
}

# Шаг block_on: домены списка закрываются через dnsmasq (address=/имя/).
block_dns() {
    _bl_dom=0
    _bl_net=0
    _cdir=$(dnsmasq_confdir)
    if [ -z "$_cdir" ]; then
        warn "«не пускать мимо VPN»: не найден каталог конфигов dnsmasq — домены закрыть нечем"
    else
        _bf=$_cdir/byway-block.conf
        # Через plain_domains, не сырым awk: формы Xray (`full:`, `domain:`)
        # писались в dnsmasq буквально -- файл проходит `--test`, но
        # закрывается несуществующий домен. keyword: и regexp: именем закрыть
        # нельзя (dnsmasq сопоставляет суффиксом) -- об этом говорим вслух.
        _bl_src=$(merged_domains)
        _bl_all=$(grep -cvE '^[[:space:]]*(//|#|$)' "$_bl_src" 2>/dev/null || true)
        _bl_all=${_bl_all:-0}
        # `address=/имя/` без адреса -- NXDOMAIN на любой тип; с 0.0.0.0
        # закрывалась лишь A, а AAAA и HTTPS dnsmasq 2.86+ уходили провайдеру
        # (2026-10-02).
        plain_domains "$_bl_src" |
          awk '{ printf "address=/%s/\n", $0 }' > "$_bf.new"
        # Синтаксис проверяем до подмены: битый файл не даст dnsmasq подняться.
        _bl_dom=$(grep -c . "$_bf.new" 2>/dev/null || true); _bl_dom=${_bl_dom:-0}
        if [ "$_bl_all" -gt "$_bl_dom" ]; then
            warnf "«не пускать мимо VPN»: %s записей списка нельзя закрыть по имени (keyword:, regexp: и подобные) — они останутся ОТКРЫТЫМИ" \
                  "$((_bl_all - _bl_dom))"
        fi
        if cmp -s "$_bf.new" "$_bf"; then
            rm -f "$_bf.new"
        elif dnsmasq --test -C "$_bf.new" >/dev/null 2>&1; then
            mv "$_bf.new" "$_bf"
            /etc/init.d/dnsmasq restart >/dev/null 2>&1
        else
            _bl_dom=0
            rm -f "$_bf.new"
            warn "«не пускать мимо VPN»: dnsmasq не принял список — домены остались ОТКРЫТЫМИ"
        fi
    fi
    return 0
}

# Шаг block_on: наборы подсетей v4 и v6 для таблицы запрета.
block_nets() {
    _nets=$(set_elements "$(merged_subnets)")
    # Подсети v6 закрываются тоже: при включённом заворачивании они
    # перехватываются, а закрывались только v4 -- запрет обещал больше, чем
    # делал.
    _nets6=""
    if v6on; then _nets6=$(set_elements6 "$(merged_subnets)"); fi
    _b4set=""; _b4rule=""
    if [ -n "$_nets" ]; then
        _b4set="
	set blocked {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $_nets }
	}"
        _b4rule="
		ip daddr @blocked counter reject"
    fi
    _b6set=""; _b6rule=""
    if [ -n "$_nets6" ]; then
        _b6set="
	set blocked6 {
		type ipv6_addr
		flags interval
		auto-merge
		elements = { $_nets6 }
	}"
        _b6rule="
		ip6 daddr @blocked6 counter reject"
    fi
    return 0
}

block_off() {
    _cdir=$(dnsmasq_confdir)
    if [ -n "$_cdir" ] && [ -f "$_cdir/byway-block.conf" ]; then
        rm -f "$_cdir/byway-block.conf"
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
    fi
    nft delete table inet "${TABLE}_block" 2>/dev/null || true
    rm -f "$BLOCK_MARK" "$BLOCK_MARK.sig" "$BLOCK_MARK.parts" 2>/dev/null || true
}

# Стоит ли запрет в ядре и в dnsmasq -- по списку частей, записанному при
# укладке. Списка нет (запрет от прежней версии) -- судить нечем, верим файлу.
block_intact() {
    [ -f "$BLOCK_MARK.parts" ] || return 0
    for _bp in $(cat "$BLOCK_MARK.parts" 2>/dev/null); do
        case "$_bp" in
          table) nft list table inet "${TABLE}_block" >/dev/null 2>&1 || return 1 ;;
          conf)  _bcd=$(dnsmasq_confdir)
                 [ -n "$_bcd" ] && [ -f "$_bcd/byway-block.conf" ] || return 1 ;;
        esac
    done
    return 0
}
