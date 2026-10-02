# cmd_plumb on|off|close -- единственный вход для службы и сторожа, под замком.

cmd_plumb() {
    # Замок: у обвязки пять хозяев (старт службы, её фоновый цикл до 65 с,
    # reload, сторож из cron, консоль) и общая дельта UCI dhcp с правилами
    # ядра. return, а не die: cmd_watch зовёт через `if`, exit оборвал бы весь
    # прогон сторожа.
    _plock=/var/run/byway-plumb.lock
    take_lock "$_plock" "$(_t 'настройка перехвата')" || {
        warn "перехват уже настраивается другим запуском -- пропущено"
        return 1
    }
    trap 'rm -rf "$_plock" 2>/dev/null; true' EXIT INT TERM
    case "${1:-}" in
      on)
        plumb_fwrule
        # Метку «сняли намеренно» снимаем сразу: иначе неудачный подъём
        # оставлял сторожа запертым.
        rm -f "$PLUMB_DOWN" 2>/dev/null || true
        plumb_wait
        if [ $_i -ge 15 ]; then
            # Возвращаем dnsmasq провайдеру: иначе он остался бы с
            # закоммиченной правкой.
            dns_down
            # Закрыть до сообщения: между ними страница ушла бы мимо туннеля.
            block_on
            # return, а не dief: сюда сторож заходит чаще всего (движок жив, но
            # не отвечает), а exit обрывал бы весь его прогон -- журнал,
            # списки, автообновление.
            warnf "Xray-core не отвечает на %s:53 — перехват не включён, dnsmasq возвращён провайдеру" "$_l"
            rm -rf "$_plock" 2>/dev/null || true
            return 1
        fi

        # Сначала -c, и только потом снос старой таблицы: опечатка в подсетях
        # не должна оставить роутер без обвязки. Правила -- в переменной, не в
        # файле: фиксированное имя в общем /tmp открывается дважды (проверка и
        # применение видят разное) и пишет по симлинку, а занять его может
        # не-root (dnsmasq).
        _rules=$(nft_ruleset)
        # return 1, а не die: сторож зовёт через `if`, exit убил бы весь его
        # прогон.
        printf '%s\n' "$_rules" | nft -c -f - || {
            # Резолвер -- провайдеру, запрет -- по настройке, как в соседних
            # ветках отказа. На пути stop --keep-dns dnsmasq остаётся на нас, и
            # без правил дом получал бы подставные адреса без перехвата.
            warn "правила не приняты ядром, перехват не включён"
            dns_down
            block_on
            rm -rf "$_plock" 2>/dev/null || true
            return 1
        }
        # Маршрут до правил: его отказ не должен оставлять таблицу nft
        # (2026-09-03: правила легли, маршрута нет, подсети ушли в tproxy в
        # никуда).
        route_up

        # Таблицу сносит и кладёт сам набор, одной транзакцией. Итог укладки
        # читается: `nft -c` доказывает разбор, а не применение, и между
        # проверкой и укладкой идёт route_up -- чужой процесс (fw4, hotplug)
        # мог изменить таблицы. Без проверки дом получал подставные адреса без
        # правил перехвата.
        _nfte=""
        _nfte=$(printf '%s\n' "$_rules" | nft -f - 2>&1) || _nfte=${_nfte:-отказ без сообщения}
        if [ -n "$_nfte" ]; then
            warnf "правила не легли в ядро — %s" \
                  "$(printf '%s' "$_nfte" | head -2 | tr '\n' ' ')"
            # Маршрут снимаем: без правил он остался бы висеть в таблице 100.
            route_down
            # nft -f -- одна транзакция: при отказе прежняя таблица остаётся и
            # метит пакеты, а route_down снял правило и маршрут -- помеченным
            # ехать некуда (домены глохнут, подсети идут мимо туннеля).
            # Осиротевшую таблицу сносим.
            if nft list table inet "$TABLE" >/dev/null 2>&1; then
                _delerr=$(nft delete table inet "$TABLE" 2>&1 || true)
                [ -n "$_delerr" ] &&
                    warnf "прежняя таблица не снялась — %s" "$_delerr"
            fi
            # Резолвер -- провайдеру, запрет -- по настройке (как выше).
            dns_down
            block_on
            rm -rf "$_plock" 2>/dev/null || true
            return 1
        fi
        dns_up
        block_off
        rm -rf "$_plock" 2>/dev/null || true
        sayf "перехват включён: таблица inet %s, правило fwmark, dnsmasq -> %s" "$TABLE" "$(dns_addr)"
        ;;
      off)
        # Метка PLUMB_DOWN -- первым действием: dns_down рестартует dnsmasq
        # (секунды), и сторож в это окно видел «обвязки нет при живом движке» и
        # поднимал её поверх незаконченного снятия. --service метку не ставит:
        # если следующий старт провалится, сторож остался бы заперт до
        # перезагрузки. Флаги ищем во всей строке аргументов, не в $2 и $3.
        _pf=" $* "
        case "$_pf" in
          *" --service "*) ;;
          *) : > "$PLUMB_DOWN" 2>/dev/null || true ;;
        esac
        nft delete table inet $TABLE 2>/dev/null || true
        route_down
        # --keep-dns ставит рестарт службы, где следом идёт подъём: dnsmasq
        # вниз и обратно -- два окна по 9 с без DNS. Если движок не встанет,
        # plumb on сам зовёт dns_down. Отключить руками: byway plumb off
        case "$_pf" in
          *" --keep-dns "*) dns_flush ;;
          *) dns_down ;;
        esac
        # Запрет снимается вместе с обвязкой (иначе `plumb off` выглядел бы
        # поломкой интернета), кроме --keep-block: при мёртвом движке сторож
        # снимает обвязку, а запрет снимет ветка «движок вернулся». Флаг, а не
        # --service: после остановки службы запертый дом оставлять нельзя.
        case "$_pf" in
          *" --keep-block "*) ;;
          *) block_off ;;
        esac
        rm -rf "$_plock" 2>/dev/null || true
        case "$_pf" in
          *" --keep-dns "*) say "перехват снят, резолвер оставлен на месте" ;;
          *)                say "перехват снят, dnsmasq возвращён" ;;
        esac
        ;;
      close)
        # Закрыть, не поднимая обвязку (start_service при on_failure=closed).
        # Иначе после перезагрузки запрет встаёт лишь после ожидания движка (до
        # 15 с трижды), а dnsmasq уже отдаёт настоящие адреса: утечка ровно в
        # момент, ради которого запрет и включают.
        block_on
        ;;
      *) die "byway plumb on|off|close" ;;
    esac
}

# Шаг plumb on: правило firewall byway-tproxy сверяется с меткой (нет --
# заводится).
plumb_fwrule() {
        # Правило с меткой пишет установщик один раз, а метка настраивается:
        # после смены зона с input REJECT (гостевая) перестаёт пропускать
        # помеченный трафик, а doctor считает правила, не значение. Сверка --
        # до укладки своей таблицы: перезагрузка firewall сносит ruleset
        # целиком.
        _fwm=$(nft_val mark "$(u mark)" '^0x[0-9a-fA-F]{1,8}$' 0x100000)
        _fwr=$(uci -q get firewall.bywaytproxy.mark 2>/dev/null || true)
        # Правила нет (удалили, сброс firewall) -- заводим как установщик: без
        # него гостевая зона теряет туннель.
        if [ -z "$(uci -q get firewall.bywaytproxy 2>/dev/null)" ]; then
            uci -q set firewall.bywaytproxy=rule
            uci -q set firewall.bywaytproxy.name='byway-tproxy'
            uci -q set firewall.bywaytproxy.src='*'
            uci -q set firewall.bywaytproxy.proto='all'
            uci -q set firewall.bywaytproxy.mark="$_fwm/$_fwm"
            uci -q set firewall.bywaytproxy.target='ACCEPT'
            uci commit firewall
            /etc/init.d/firewall reload >/dev/null 2>&1 || true
            say "правила firewall для помеченного трафика не было — заведено заново"
            _fwr="$_fwm/$_fwm"
        fi
        if [ -n "$_fwr" ] && [ "$_fwr" != "$_fwm/$_fwm" ]; then
            sayf "метка сменилась (%s -> %s) — правило firewall переписывается" \
                 "$_fwr" "$_fwm/$_fwm"
            uci -q set firewall.bywaytproxy.mark="$_fwm/$_fwm"
            uci commit firewall
            /etc/init.d/firewall reload >/dev/null 2>&1 || true
        fi
    return 0
}

# Шаг plumb on: ждёт, пока Xray ответит на DNS-входе (до 15 с); _i=15 -- отказ.
plumb_wait() {
        # Xray должен отвечать до любой правки: dns_up уводит весь резолв на
        # его вход с noresolv, и при мёртвом Xray дом остался бы без DNS.
        _l=$(dns_addr)
        # Проба -- домен из объединённого списка: FakeDNS отвечает локально,
        # без WAN, так что меряется Xray, а не канал. Посторонний домен не
        # годился: его нет в fakedns ни в одном режиме.
        _probe=$(plain_domains "$(merged_domains)" | head -1)
        _i=0
        _gone=0
        while [ $_i -lt 15 ]; do
            if [ -n "$_probe" ]; then
                nslookup "$_probe" "$_l" 2>/dev/null | grep -qE "$(fakeip_re)" && break
            else
                # Списка нет -- достаточно, что резолвер отвечает.
                nslookup example.com "$_l" >/dev/null 2>&1 && break
            fi
            # Процесса движка нет пять проб подряд -- он падает при старте,
            # досиживать срок незачем: на рестарте дом без DNS, пока движок не
            # ответит. Пять, а не один: на холодной загрузке procd поднимает
            # движок не сразу.
            if [ -z "$(xray_pid)" ]; then
                _gone=$((_gone + 1))
                if [ "$_gone" -ge 5 ]; then
                    warn "движок не запущен — перехват не включён, ожидание прервано"
                    _i=15
                    break
                fi
            else
                _gone=0
            fi
            _i=$((_i + 1)); sleep 1
        done
    return 0
}
