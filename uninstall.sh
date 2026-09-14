#!/bin/sh
#
# Удаление byway с OpenWrt.
#
# Установщик кладёт этот файл на роутер как `byway-uninstall`, поэтому
# зовут его по имени, а не через `sh`:
#
#     byway-uninstall            снять byway, настройки и списки оставить
#     byway-uninstall --purge    снять всё, включая ключ и списки
#     DRY_RUN=1 byway-uninstall  показать, что было бы сделано, не делая
#
# Порядок здесь важнее содержания. byway уводит dnsmasq на свой DNS-вход, и
# если сначала удалить программу, а потом спохватиться, дом останется с
# резолвером, указывающим в пустоту: без DNS вообще, без автоматического
# выхода, чинить только руками из локальной сети.
#
# Поэтому первым делом -- вернуть dnsmasq, и только потом всё остальное.
#
# Сухой прогон не роскошь: удаление проверяют по-настоящему ровно один раз и
# на работающем роутере. Так порядок шагов виден заранее.

set -e

# Язык берётся из настройки byway -- той самой, что выбрали при установке.
# Словарь внутри файла: --purge сносит /etc/byway вместе со словарями byway,
# и последние строки удаления читались бы уже не на том языке.
case "$(uci -q get byway.main.lang 2>/dev/null)" in en) LANG_EN=1 ;; *) LANG_EN=0 ;; esac

t() {
    [ "$LANG_EN" = 1 ] || { printf %s "$1"; return 0; }
    case "$1" in
      "── 1. Сеть возвращается в исходное ──") printf %s "── 1. The network goes back to how it was ──" ;;
      "byway уже нет — следы убираются вручную") printf %s "byway is gone already — the leftovers are cleaned by hand" ;;
      "обвязку снять не вышло с первого раза -- повтор через пять секунд") printf %s "removing the plumbing failed on the first try -- retrying in five seconds" ;;
      "обвязка НЕ снята: правила nft, маршрут и резолвер могли остаться. Снять руками: byway plumb off") printf %s "the plumbing is NOT removed: nft rules, the route and the resolver may have stayed. Remove by hand: byway plumb off" ;;
      "dnsmasq всё ещё смотрит в byway — исправляется") printf %s "dnsmasq still points at byway — fixing that" ;;
      "dnsmasq возвращён провайдеру") printf %s "dnsmasq is back on the provider" ;;
      "── 2. Служба ──") printf %s "── 2. The service ──" ;;
      "остановлена и снята с автозапуска") printf %s "stopped and removed from autostart" ;;
      "── 3. Задачи cron ──") printf %s "── 3. Cron jobs ──" ;;
      "убрать из crontab строки, показанные выше") printf %s "remove the crontab lines shown above" ;;
      "задачи byway убраны") printf %s "the byway jobs are removed" ;;
      "── 4. Правило firewall ──") printf %s "── 4. The firewall rule ──" ;;
      "правило для гостевой сети убрано") printf %s "the rule for the guest network is removed" ;;
      "── 5. Файлы ──") printf %s "── 5. Files ──" ;;
      "очистить кэш меню LuCI:") printf %s "clear the LuCI menu cache:" ;;
      "программа и панель удалены") printf %s "the program and the panel are removed" ;;
      "пути убраны из keep-списка прошивки") printf %s "the paths are removed from the firmware keep-list" ;;
      "── 6. Настройки и списки ──") printf %s "── 6. Settings and lists ──" ;;
      "удалены, включая ключ VPN") printf %s "removed, the VPN key included" ;;
      "── 6. Настройки и списки ОСТАВЛЕНЫ ──") printf %s "── 6. Settings and lists are KEPT ──" ;;
      "    /etc/config/byway и /etc/byway/ на месте") printf %s "    /etc/config/byway and /etc/byway/ are still there" ;;
      "    удалить вместе с ключом: byway-uninstall --purge") printf %s "    remove them together with the key: byway-uninstall --purge" ;;
      "это был сухой прогон — на роутере ничего не изменилось") printf %s "that was a dry run — nothing on the router changed" ;;
      "Готово. Интернет работает, туннеля нет.") printf %s "Done. The internet works, there is no tunnel." ;;
      "Что НЕ трогалось: движок Xray-core, zapret, настройки сети.") printf %s "What was NOT touched: the Xray-core engine, zapret, your network settings." ;;
      "Что НЕ трогалось: zapret, настройки сети.") printf %s "What was NOT touched: zapret, your network settings." ;;
      "движок удалён: %s шт.") printf %s "the core is removed: %s file(s)" ;;
      "движок по своему пути оставлен: %s") printf %s "the core at your own path is left alone: %s" ;;
      "движок из прошивки оставлен -- он мог стоять до byway и нужен не только ему") printf %s "the core from the firmware is left alone -- it may predate byway and may be used by something else" ;;
      "  снять вручную: %s") printf %s "  remove by hand: %s" ;;
      "было бы сделано:") printf %s "would be done:" ;;
      "СУХОЙ ПРОГОН: ничего не меняется") printf %s "DRY RUN: nothing is being changed" ;;
      "вычеркнуть из /etc/sysupgrade.conf строк: ") printf %s "strike out of /etc/sysupgrade.conf lines: " ;;
      *) printf %s "$1" ;;
    esac
}

_say()  { printf '\033[1;32m[*]\033[0m %s\n' "$1"; }
_warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
say()  { _say  "$(t "$1")"; }
warn() { _warn "$(t "$1")"; }
sayf()  { _f=$(t "$1"); shift; _say  "$(printf "$_f" "$@")"; }

DRY=${DRY_RUN:-0}

# Всё, что меняет систему, идёт ЧЕРЕЗ do_ и только через него. Второй ветки
# «а если прогон не сухой» здесь нет намеренно: 2026-09-04 такая ветка
# осталась в шаге 1, определение do_ при правке не вставилось, и «сухой»
# прогон выполнил настоящий plumb off -- дом остался без резолвера. Когда
# другого пути нет, пропавшая функция даёт 127 на первом шаге, до вреда.
do_() {
    if [ "$DRY" = "1" ]; then
        printf '    \033[2m%s\033[0m %s\n' "$(t 'было бы сделано:')" "$*"
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

[ "$DRY" = "1" ] && warn "СУХОЙ ПРОГОН: ничего не меняется"

# Пакетный менеджер -- ради ОДНОГО совета: чем снять движок из прошивки.
# Глагол у них разный: `apk del`, но `opkg remove`. Совет с чужим глаголом
# не работает, и на этом уже обжигались с `opkg add`.
PKG=""
command -v apk  >/dev/null 2>&1 && PKG=apk
[ -z "$PKG" ] && command -v opkg >/dev/null 2>&1 && PKG=opkg
PKG_DEL=del
[ "$PKG" = opkg ] && PKG_DEL=remove

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo
say "── 1. Сеть возвращается в исходное ──"

if [ -x /usr/local/bin/byway ]; then
    # ⚠️ Итог ЧИТАЕМ. Обёртка do_ глушит и вывод, и код возврата, а plumb off
    # может не сделать ничего и вернуть единицу -- например на занятом замке
    # обвязки. Тогда правила nft, маршрут и резолвер оставались висеть, а
    # удаление докладывало об успехе. Найдено третьим аудитом 2026-09-07.
    if [ "${DRY_RUN:-0}" = "1" ]; then
        do_ /usr/local/bin/byway plumb off
    elif /usr/local/bin/byway plumb off >/dev/null 2>&1; then
        :
    else
        warn "обвязку снять не вышло с первого раза -- повтор через пять секунд"
        sleep 5
        /usr/local/bin/byway plumb off >/dev/null 2>&1 ||
            warn "обвязка НЕ снята: правила nft, маршрут и резолвер могли остаться. Снять руками: byway plumb off"
    fi
else
    warn "byway уже нет — следы убираются вручную"
    # ВОЗВРАЩАЕМ прежние адреса, а не стираем список. Стереть целиком можно
    # ровно в одном случае -- когда есть снимок и в нём записано, что именно
    # вернуть. Снимка чаще всего НЕТ: обычная уборка удаляет его последней
    # строкой возврата, и та же уборка --purge приходит вторым запуском уже
    # без него. Прежняя редакция в этом случае удаляла список и коммитила
    # пустоту во флеш: пропадали и апстримы, вписанные руками, и раздельный
    # резолв вида server=/nas.lan/192.168.1.5, и гашение канарейки Firefox.
    # Интернет не падал (noresolv снят, dnsmasq уходит на resolv.conf.auto),
    # поэтому связать пропажу с удалением byway было нечем -- а скрипт в этот
    # самый момент печатает «настройки сети не трогались».
    _mine=$(uci -q get byway.main.dns_listen 2>/dev/null || true)
    [ -n "$_mine" ] || _mine=127.0.0.42
    if [ -f /etc/byway/dns-saved ]; then
        # ⚠️ Запоминаем ТЕКУЩИЙ список до удаления: в нём могли появиться
        # доменные записи (server=/nas.lan/192.168.1.5), заведённые уже после
        # снимка -- руками или на странице DHCP. В снимок они не попали, а
        # возврат по снимку сносил их вместе со всем списком. В самом byway
        # (dns_down) это починено, а сюда, в ручную ветку, правка не доехала.
        # Найдено третьим аудитом 2026-09-07.
        _dcur=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
        do_ uci -q delete dhcp.@dnsmasq[0].server
        _dseen=" "
        for _s in $(sed -n 's/^server=//p' /etc/byway/dns-saved); do
            case "$_dseen" in *" $_s "*) continue ;; esac
            _dseen="$_dseen$_s "
            do_ uci add_list "dhcp.@dnsmasq[0].server=$_s"
        done
        # Возвращаем только доменные записи: всё прочее -- апстримы, и про них
        # решает снимок.
        for _s in $_dcur; do
            case "$_s" in /*) ;; *) continue ;; esac
            case "$_dseen" in *" $_s "*) continue ;; esac
            case "$_s" in *"$_mine"*) continue ;; esac
            _dseen="$_dseen$_s "
            do_ uci add_list "dhcp.@dnsmasq[0].server=$_s"
        done
        if [ "$(sed -n '1s/^noresolv=//p' /etc/byway/dns-saved)" = "1" ]; then
            do_ uci set dhcp.@dnsmasq[0].noresolv=1
        else
            do_ uci -q delete dhcp.@dnsmasq[0].noresolv
        fi
    else
        # Снимка нет -- знаем только СВОЙ адрес и убираем поимённо его.
        # Чужие записи не наши, чтобы их судьбу решать: человек мог держать
        # на петле и свой резолвер (https-dns-proxy, stubby), и снести его
        # заодно значило бы повторить ту же беду с другой стороны.
        do_ uci -q del_list "dhcp.@dnsmasq[0].server=$_mine"
        # noresolv снимаем, только если резолвить стало нечем. Он мог стоять
        # у человека и до byway, вместе с его собственными адресами.
        [ -n "$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)" ] ||
            do_ uci -q delete dhcp.@dnsmasq[0].noresolv
    fi
    do_ uci commit dhcp
    do_ /etc/init.d/dnsmasq restart
    do_ nft delete table inet byway
    do_ nft delete table inet byway_block
    # Добавка dnsmasq от kill switch: без неё домены из списка так и
    # остались бы отвечающими 0.0.0.0 после удаления byway.
    #
    # Каталог спрашиваем у самого dnsmasq, как это делает byway, а не задаём
    # шаблоном. Имя содержит хеш секции UCI (/tmp/dnsmasq.cfg01411c.d) и
    # меняется после сброса; на части прошивок каталог называется просто
    # /tmp/dnsmasq.d, а человек может задать свой через option confdir. На
    # таком роутере зашитый шаблон не находил ничего и шаг проходил молча --
    # а файл продолжал отвечать 0.0.0.0 на весь список доменов и переживал
    # перезагрузку, уже после удаления byway. Объяснить это было нечем:
    # программы нет, правил нет, половина интернета не открывается.
    _cdir=$(grep -h '^conf-dir=' /var/etc/dnsmasq.conf.* 2>/dev/null |
            head -1 | cut -d= -f2- | cut -d, -f1)
    for _bc in "${_cdir:-/нет}/byway-block.conf" \
               /tmp/dnsmasq.*.d/byway-block.conf \
               /tmp/dnsmasq.d/byway-block.conf; do
        [ -f "$_bc" ] && do_ rm -f "$_bc"
    done
    # Правил с меткой может накопиться несколько: ip rule add при каждом
    # подъёме добавляет новое, не заменяя прежнее. Ищем СВОЁ -- по метке, а
    # не по одной таблице: 100 с fwmark занимают и openclash, и passwall,
    # и по «lookup 100» мы бы крутились на чужом правиле, пока не кончатся
    # попытки. `ip rule del` с нашей меткой чужого не тронет.
    # Метку берём из настройки, а не зашитую: она настраивается, и с чужим
    # значением удаление искало бы не своё правило -- оставило бы своё висеть
    # и в следующий раз попыталось бы снять соседское.
    _mk=$(uci -q get byway.main.mark 2>/dev/null || true)
    _mk=${_mk:-0x100000}
    for _i in 1 2 3 4 5; do
        ip rule show 2>/dev/null |
            grep -qE "fwmark $_mk(/$_mk)?[[:space:]]+lookup 100([[:space:]]|$)" || break
        do_ ip rule del fwmark "$_mk/$_mk" lookup 100
        [ "$DRY" = "1" ] && break
    done
    # Точечно, а не flush. Таблица общая: flush стирал бы и `local default`
    # соседа по tproxy, и у него ложился бы весь трафик -- при удалении
    # ЧУЖОЙ программы. Свой маршрут один и известен.
    do_ ip route del local default dev lo table 100
fi

# Проверяем, а не верим на слово: остаться без DNS дороже лишней проверки.
# Условие именно такое: noresolv=1 мог стоять у человека И ДО byway, вместе
# с его собственными резолверами. Признак беды -- НАШ адрес всё ещё в списке
# server, то есть возврат не состоялся.
# `|| true` обязателен: у присваивания код берётся от подстановки, а
# `uci -q get` возвращает единицу, когда опции просто НЕТ -- то есть на
# роутере с настройками по умолчанию. Без него удаление обрывалось
# ровно здесь, сразу после первого шага: файлы, задачи cron, правила
# файрвола и панель оставались на месте, а человек видел молчание и код 1.
# Поймано на стенде 23.05.6, воспроизводится на любой чистой системе.
_lst=" $(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true) "
_own=$(uci -q get byway.main.dns_listen 2>/dev/null || echo 127.0.0.42)
[ -n "$_own" ] || _own=127.0.0.42
if [ "$DRY" != "1" ] && [ "${_lst#* $_own }" != "$_lst" ]; then
    warn "dnsmasq всё ещё смотрит в byway — исправляется"
    # Убираем ТОЛЬКО свой адрес, чужие записи остаются на месте.
    do_ uci -q del_list "dhcp.@dnsmasq[0].server=$_own"
    [ -n "$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)" ] ||
        do_ uci -q delete dhcp.@dnsmasq[0].noresolv
    do_ uci commit dhcp
    do_ /etc/init.d/dnsmasq restart
fi
say "dnsmasq возвращён провайдеру"

echo
say "── 2. Служба ──"
if [ -x /etc/init.d/byway ]; then
    do_ /etc/init.d/byway stop
    do_ /etc/init.d/byway disable
    do_ rm -f /etc/init.d/byway /etc/rc.d/S90byway /etc/rc.d/K10byway
    say "остановлена и снята с автозапуска"
fi

echo
say "── 3. Задачи cron ──"
# Режем по вызову, а не по слову «byway». Голая подстрока уносила и чужие
# строки: ночную копию `tar czf /root/lists.tgz /etc/byway`, свой
# byway-notify.sh. Хватился бы человек в тот день, когда копия понадобилась,
# и связать пропажу с удалением byway месяцем раньше было бы нечем.
# Установщик заводит ровно две задачи, и обе опознаются по вызову.
CRON_RE='^[^#]*/byway[[:space:]]\{1,\}\(watch\|stat\)\([[:space:]]\|$\)'
if crontab -l 2>/dev/null | grep -q "$CRON_RE"; then
    # Показываем вслух ДО удаления, и в сухом прогоне тоже: иначе «задачи
    # byway убраны» не проверить, пока они не понадобились.
    crontab -l 2>/dev/null | grep "$CRON_RE" | sed 's/^/      /'
    if [ "$DRY" = "1" ]; then
        do_ "$(t "убрать из crontab строки, показанные выше")"
    else
        crontab -l 2>/dev/null | grep -v "$CRON_RE" | crontab -
    fi
    do_ /etc/init.d/cron restart
    say "задачи byway убраны"
fi

echo
say "── 4. Правило firewall ──"
if [ -n "$(uci -q get firewall.bywaytproxy 2>/dev/null || true)" ]; then
    do_ uci delete firewall.bywaytproxy
    do_ uci commit firewall
    do_ /etc/init.d/firewall reload
    say "правило для гостевой сети убрано"
fi

echo
say "── 5. Файлы ──"
do_ rm -f /usr/local/bin/byway
# Себя тоже. Удаляем ПОСЛЕДНИМ действием такого рода: файл уже прочитан
# оболочкой целиком, дальше он ей не нужен. Оставленный, он был бы единственным
# следом byway на роутере после удаления.
do_ rm -f /usr/local/bin/byway-uninstall /usr/bin/byway-uninstall
do_ rm -f /usr/bin/byway
do_ rm -rf /www/luci-static/resources/view/byway
do_ rm -rf /www/luci-static/resources/byway
do_ rm -f /usr/share/luci/menu.d/luci-app-byway.json \
          /usr/share/rpcd/acl.d/luci-app-byway.json
for c in /tmp/luci-indexcache*; do
    [ -e "$c" ] || continue
    # `: >`, а не truncate: в busybox этого роутера truncate НЕТ вовсе, а do_
    # глотает ошибку -- кэш меню молча не чистился, и LuCI продолжал
    # показывать пункт уже удалённого приложения. Поймано при выкладке
    # 2026-09-05; install.sh делает это правильно с самого начала.
    if [ "$DRY" = "1" ]; then
        do_ "$(t 'очистить кэш меню LuCI:') $c"
    else
        : > "$c"
    fi
done
do_ /etc/init.d/rpcd restart
say "программа и панель удалены"

# Пути из keep-списка прошивки. Каталог /usr/local/bin/ НЕ убираем: там могут
# лежать чужие скрипты, и заводили его не мы одни. А вот свои файлы в нём --
# убираем поимённо: они только что удалены, и строка на удалённый файл живёт
# в keep-списке вечно.
#
# Выражение бьёт только по нашим строкам целиком, от начала до конца. Чужие
# пути в этом файле переживают sysupgrade, и вычеркнуть их значило бы молча
# потерять чужие настройки при следующей прошивке.
#
# ⚠️ /etc/byway/ вычёркивается ТОЛЬКО при --purge, и это не мелочь. Без него
# уборка сознательно оставляет настройки и списки и говорит об этом вслух.
# Вычеркнув каталог из keep-списка, она отняла бы ровно их при следующей
# прошивке: /etc/config сохраняется сам, а /etc/byway со списками,
# направлениями, пресетами и учётом держится только этой строкой. Человек
# узнал бы об этом после sysupgrade, когда откатываться некуда.
KEEP_RE='^/etc/init\.d/byway$\|^/etc/rc\.d/[SK][0-9]*byway$'
KEEP_RE="$KEEP_RE"'\|^/usr/local/bin/byway$\|^/usr/bin/byway$'
KEEP_RE="$KEEP_RE"'\|^/usr/local/bin/byway-uninstall$\|^/usr/bin/byway-uninstall$'
[ "$PURGE" = "1" ] && KEEP_RE="$KEEP_RE"'\|^/etc/byway/$'
if [ -f /etc/sysupgrade.conf ]; then
    if [ "$DRY" = "1" ]; then
        _kn=$(grep -c "$KEEP_RE" /etc/sysupgrade.conf || true)
        do_ "$(t "вычеркнуть из /etc/sysupgrade.conf строк: ")$_kn"
    else
        # `|| true` обязателен: grep возвращает 1, когда не отобрал ни
        # строки, и на файле, где кроме наших путей ничего нет, `&& mv` не
        # срабатывал -- keep-список оставался с путями к удалённому.
        grep -v "$KEEP_RE" /etc/sysupgrade.conf > /tmp/su.n || true
        mv /tmp/su.n /etc/sysupgrade.conf
    fi
    say "пути убраны из keep-списка прошивки"
fi

echo
if [ "$PURGE" = "1" ]; then
    say "── 6. Настройки и списки ──"
    # ⚠️ Путь к движку читаем ДО удаления настроек: ниже они исчезнут.
    _xb=$(uci -q get byway.main.xray_bin 2>/dev/null || true)
    do_ rm -rf /etc/byway
    do_ uci -q delete byway
    do_ rm -f /etc/config/byway
    do_ uci commit byway
    say "удалены, включая ключ VPN"
    # ── движок ─────────────────────────────────────────────────────────
    #
    # Удаляем ТОЛЬКО то, что положил сам byway: файлы вида
    # /usr/local/bin/xray-<версия> -- это его собственное имя, установщик
    # переименовывает распакованный бинарник именно так. Пакет из прошивки
    # (/usr/bin/xray) не трогаем: его мог поставить кто угодно и пользоваться
    # им может не только byway -- о нём говорим вслух и даём команду.
    #
    # Прежде не удалялось ничего, и это было решением «движок мог стоять до
    # нас». Наполовину верным: в случае /usr/local/bin/xray-* положили его мы
    # и знаем об этом. На роутере с 43 МБ флеша после «полного удаления»
    # оставалось 35 МБ занятыми -- владелец спрашивал об этом дважды.
    _xn=0
    for _xf in /usr/local/bin/xray-*; do
        [ -f "$_xf" ] || continue
        _xn=$((_xn + 1))
        do_ rm -f "$_xf"
    done
    if [ "$_xn" -gt 0 ]; then
        sayf "движок удалён: %s шт." "$_xn"
    fi
    # Свой путь, указанный человеком вручную, не наш -- о нём только говорим.
    case "$_xb" in
      ''|/usr/local/bin/xray-*) : ;;
      *) [ -e "$_xb" ] && warnf "движок по своему пути оставлен: %s" "$_xb" ;;
    esac
    if [ -x /usr/bin/xray ]; then
        warn "движок из прошивки оставлен -- он мог стоять до byway и нужен не только ему"
        warnf "  снять вручную: %s" "${PKG:-apk} ${PKG_DEL:-del} xray-core"
    fi
else
    say "── 6. Настройки и списки ОСТАВЛЕНЫ ──"
    say "    /etc/config/byway и /etc/byway/ на месте"
    say "    удалить вместе с ключом: byway-uninstall --purge"
fi

echo
if [ "$DRY" = "1" ]; then
    warn "это был сухой прогон — на роутере ничего не изменилось"
else
    say "Готово. Интернет работает, туннеля нет."
    if [ "$PURGE" = "1" ]; then
        say "Что НЕ трогалось: zapret, настройки сети."
    else
        say "Что НЕ трогалось: движок Xray-core, zapret, настройки сети."
    fi
fi
