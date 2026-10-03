# dnsmasq на DNS-вход Xray и обратно; снимок прежних резолверов.

CANARY=/use-application-dns.net/

# -- dnsmasq ----------------------------------------------------------------
# Резолвер уводится на DNS-вход Xray. noresolv обязателен: без него dnsmasq
# шлёт запрос и провайдеру, берёт первый ответ, и часть доменов получает
# настоящий адрес вместо fakeip -- маршрут работает через раз, и не видно.
# Прежние значения -- в /etc/byway/dns-saved, откат их возвращает. Кэш dnsmasq
# не обнуляется: пул fakedns на 131 тыс. адресов не вытесняется, но таблица не
# переживает рестарт Xray -- старт службы сбрасывает кэш по HUP.
DNSSEC="dhcp.@dnsmasq[0]"

# Снимок dnsmasq -- в файл, не в UCI: `uci commit byway` дёргает procd-триггер
# перезагрузки службы и пишет во флеш на каждый цикл plumb off/on (ubi
# 43.7 МБ). Файл в /etc/byway переживает перезагрузку и внесён в keep-список
# прошивки.
DNSSAVE=$LISTS/dns-saved

dns_save_read() {   # $1 -- noresolv | server
    [ -f "$DNSSAVE" ] || return 0
    case "$1" in
      noresolv) sed -n '1s/^noresolv=//p' "$DNSSAVE" ;;
      server)   sed -n 's/^server=//p' "$DNSSAVE" ;;
      listen)   sed -n 's/^listen=//p' "$DNSSAVE" ;;
    esac
}

# На кого нацелен РАБОТАЮЩИЙ dnsmasq: 0 -- какой-то процесс поднят с нашим
# адресом, 1 -- конфиги прочитаны, адреса нет, 2 -- не знаю (процессов нет или
# конфиг не прочитался). Читается файл из `-C` командной строки процесса (у
# ujail он после `--`), не UCI: наша правка UCI -- некоммиченная дельта и на
# запущенный процесс не влияет. Процессов может быть несколько (гостевой
# экземпляр), HUP конфиг не перечитывает. Лишний рестарт -- 9 с без DNS,
# пропущенный -- дом без DNS, поэтому на «не знаю» вызывающие рестартуют.
dns_live_ok() {   # $1 -- наш адрес
    # Процессов нет -- «не знаю»: dnsmasq остановлен чужой рукой (LuCI держит
    # его выключенным 9 с), а ответ «не наш» оставил бы в его конфиге наш адрес
    # без движка.
    _dpids=$(pgrep -x dnsmasq 2>/dev/null || true)
    [ -n "$_dpids" ] || return 2
    _dseen=0
    for _dpid in $_dpids; do
        _dcf=$(tr '\0' '\n' < "/proc/$_dpid/cmdline" 2>/dev/null |
               awk 'p { print; exit } /^-C$/ { p = 1 }')
        [ -n "$_dcf" ] && [ -r "$_dcf" ] || continue
        _dseen=1
        # if, а не `&& return`: несовпадение при set -e выходит из скрипта.
        if grep -qx "server=$1" "$_dcf" && grep -qx "no-resolv" "$_dcf"; then
            return 0
        fi
    done
    [ "$_dseen" = "1" ] || return 2
    return 1
}

# HUP чистит кэш и перечитывает hosts, не роняя сокеты; рестарт -- 9 с без DNS
# (замер 2026-09-07). Сброс после рестарта движка обязателен: таблица fakedns в
# памяти Xray (claude.ai был 198.18.68.107, стал 198.19.231.105).
dns_flush() {
    killall -HUP dnsmasq 2>/dev/null || true
}

dns_up() {
    _l=$(dns_addr)
    if [ ! -f "$DNSSAVE" ]; then
        {
            printf 'noresolv=%s\n' "$(uci -q get "$DNSSEC.noresolv" 2>/dev/null || echo 0)"
            for s in $(uci -q get "$DNSSEC.server" 2>/dev/null); do
                # Свой адрес в снимок не пишем, но только его, а не всю петлю:
                # чужой резолвер на 127.* (https-dns-proxy, stubby) терялся бы
                # навсегда. Если dns_listen сменили без снимка, прежний наш
                # адрес попадёт как чужой.
                [ "$s" = "$_l" ] && continue
                printf 'server=%s\n' "$s"
            done
            # Свой адрес отдельной строкой: по нему, а не по текущей настройке,
            # dns_down решает, наша ли правка в dnsmasq (после смены dns_listen
            # они расходятся).
            printf 'listen=%s\n' "$_l"
        } > "$DNSSAVE"
    fi
    # Доменные записи server=/дом/адрес остаются: это раздельный резолв своей
    # сети.
    for s in $(uci -q get "$DNSSEC.server" 2>/dev/null); do
        case "$s" in
          /*) ;;
          *) uci -q del_list "$DNSSEC.server=$s" 2>/dev/null || true ;;
        esac
    done
    uci add_list "$DNSSEC.server=$_l"
    # Канарейка: NXDOMAIN на use-application-dns.net выключает DoH у Firefox
    # (иначе он идёт мимо byway); `server=/имя/` без адреса даёт NXDOMAIN.
    _dnew=0
    case " $(uci -q get "$DNSSEC.server" 2>/dev/null) " in
      *" $CANARY "*) ;;
      *) uci add_list "$DNSSEC.server=$CANARY"; _dnew=1 ;;
    esac
    uci set "$DNSSEC.noresolv=1"
    # Не коммитим: дельта в /tmp/.uci умирает с tmpfs. Закоммиченная правка
    # переживала потерю питания и sysupgrade при мёртвом Xray, и дом оставался
    # с резолвером в пустоту. Плата: «Сохранить» на странице DHCP в LuCI
    # закоммитит и нашу дельту -- тогда `byway plumb off`. Рестарт -- только
    # если есть что менять (9 с без DNS у дома), кэш сбросит HUP. Новую строку
    # server dnsmasq читает лишь при рестарте: после HUP канарейка не вставала
    # (боевой, 2026-10-02).
    if dns_live_ok "$_l" && [ "$_dnew" = 0 ]; then
        dns_flush
    elif [ "${DNS_DEFER_RESTART:-0}" = 1 ]; then
        # Следом block_off снимает файл запрета и перезапускает dnsmasq сам:
        # один перезапуск вместо двух (по девять секунд без DNS у дома).
        :
    else
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
    fi
}

dns_down() {
    # revert снимает некоммиченную дельту без записи во флеш.
    uci -q revert dhcp 2>/dev/null || true

    # Дельту могли закоммитить со стороны («Сохранить» в LuCI) -- тогда
    # возвращаем явно. Свой адрес ищем среди значений списка (uci get отдаёт их
    # через пробел) и берём из снимка, не из текущей настройки: после смены
    # dns_listen они расходятся.
    _ours=$(dns_save_read listen)
    [ -n "$_ours" ] || _ours=$(dns_addr)
    case " $(uci -q get "$DNSSEC.server" 2>/dev/null) " in
      *" $_ours "*)
        # Снимок один, при первом подъёме: заведённые позже доменные записи
        # delete снёс бы.
        _dcur=$(uci -q get "$DNSSEC.server" 2>/dev/null || true)
        uci -q delete "$DNSSEC.server" 2>/dev/null || true
        _dseen=" "
        for s in $(dns_save_read server); do
            case "$_dseen" in *" $s "*) continue ;; esac
            _dseen="$_dseen$s "
            uci add_list "$DNSSEC.server=$s"
        done
        # Доменные записи, появившиеся после снимка, возвращаем; остальное
        # решает снимок.
        for s in $_dcur; do
            case "$s" in "$CANARY") continue ;; /*) ;; *) continue ;; esac
            case "$_dseen" in *" $s "*) continue ;; esac
            _dseen="$_dseen$s "
            uci add_list "$DNSSEC.server=$s"
        done
        if [ "$(dns_save_read noresolv)" = "1" ]; then
            uci set "$DNSSEC.noresolv=1"
        else
            uci -q delete "$DNSSEC.noresolv" 2>/dev/null || true
        fi
        uci commit dhcp
        ;;
    esac

    rm -f "$DNSSAVE" 2>/dev/null || true

    # Зеркально dns_up: резолвер не наш -- рестарт чистая потеря (plumb off на
    # роутере без обвязки дёргал DNS дома), кэш сбрасываем всё равно. «Не знаю»
    # (2) считаем нашим: пропущенный рестарт хуже лишнего.
    _dlo=0; dns_live_ok "$_ours" || _dlo=$?
    if [ "$_dlo" != "1" ]; then
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
    else
        dns_flush
    fi
}

dnsmasq_confdir() {
    _cdir=$(grep -h '^conf-dir=' /var/etc/dnsmasq.conf.* 2>/dev/null |
            head -1 | cut -d= -f2- | cut -d, -f1)
    # `if` и return 0, а не `[ ] && printf`: код 1 при ненайденном каталоге
    # через присваивание у вызывающего убивает byway под set -e.
    if [ -n "$_cdir" ] && [ -d "$_cdir" ]; then printf '%s' "$_cdir"; fi
    return 0
}
