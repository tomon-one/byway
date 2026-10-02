#!/bin/sh
#
# byway -- раздельное туннелирование на OpenWrt, ядро Xray (замена podkop).
# Путь трафика: dnsmasq -> DNS-вход Xray -> FakeDNS отдаёт адрес из пула для
# доменов списка -> nft метит трафик на этот пул в tproxy -> вход Xray со
# сниффингом достаёт исходный домен -> правило маршрутизации шлёт его в
# аутбаунд ключа. Всё прочее идёт напрямую.
# Списки -- файлы в /etc/byway, а не инлайн в UCI: правка файла действует
# после `byway gen`. Службой управляет /etc/init.d/byway, он и зовёт plumb
# (nft, маршрут, dnsmasq). Список команд печатает `byway` без аргументов
# (99-main.sh).

set -e

# Версия -- вручную, В МОМЕНТ ВЫПУСКА: main идёт впереди тега, номер на нём --
# последнего выпуска. Иначе README ссылается на тег, которого нет, и
# установка одной строкой отвечает 404.
# Имя -- опознавательный знак сборки, одно английское на все языки, не
# переводить. Ряд по минорам: 0.0 Desire Path, 0.1 Portage, 0.2 Causeway,
# 0.3 Ford, 0.4 Ice Road, 0.5 Trail, 0.6 Bypass, 0.7 Country Lane, 0.8 Old
# Road.
# Автообновление ходит только внутри минорной версии (cmd_watch).
BYWAY_NUM="0.2.4"
BYWAY_NAME="Causeway"
BYWAY_VERSION="$BYWAY_NUM ($BYWAY_NAME)"
# Откуда берутся обновления; чужая сборка меняет одно место.
BYWAY_REPO="tomon-one/byway"
# Версия Xray-core, на которой byway прогнан целиком: её ставит `byway engine
# tested`. Та же в install.sh (XRAY_TESTED) -- править парой.
XRAY_TESTED=26.9.30

CONF=/etc/config/byway
LISTS=/etc/byway
OUT=$LISTS/config.json
# Журнал обращений движка -- свой файл в памяти, не syslog: сотня строк в
# минуту вытесняет из кольца в 256 КБ всё остальное за 20 минут. Усекают
# cmd_stat и сторож cmd_watch.
ACCESS=/tmp/byway-access.log
# Путь к движку -- из UCI, чтобы держать рядом пакетный Xray и свежий ручной
# и переключаться одной командой.
# Значение пришло снаружи (UCI правит панель): запускать от root по нему
# нельзя без проверки (так устроены CVE luci-app-travelmate и samba4;
# валидатор панели не защита). Порядок: каталог (в системные пишет только
# root), исполняемость, и лишь затем версия.
xray_ok() {
    case "$1" in
        /usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/bin/*|/sbin/*) ;;
        *) return 1 ;;
    esac
    case "$1" in *..*) return 1 ;; esac
    [ -f "$1" ] && [ -x "$1" ] || return 1
    # Имя xray* и ELF -- до запуска: xray_bin=/sbin/reboot с панели
    # перезагружал роутер на каждом вызове byway.
    case "${1##*/}" in xray*) ;; *) return 1 ;; esac
    head -c 4 "$1" 2>/dev/null | grep -q ELF || return 1
    "$1" version 2>/dev/null | head -1 | grep -qi "^Xray " || return 1
}

# || true обязателен: uci -q get на незаданной опции даёт 1, и под set -e
# присваивание молча убивает скрипт.
XRAY=$(uci -q get byway.main.xray_bin || true)
# Жалоба отложена: путь проверяется раньше, чем заведён словарь (_t), и
# напечатанное здесь осталось бы русским. Печатается в 01-core.sh.
XRAY_REJECTED=""
if [ -n "$XRAY" ] && ! xray_ok "$XRAY"; then
    XRAY_REJECTED=$XRAY
    XRAY=""
fi

# Версия движка числом: 26.7.28 -> 260728, 1.8.3 -> 10803. Нумерация Xray
# менялась, сравнение по числам её переживает.
# Нужна, потому что Go молча отбрасывает незнакомые поля JSON, и `run -test`
# старого Xray (1.8.3 на OpenWrt 22.03) принимает конфиг с потерянным полем.
# Звать только как команду, число читать из XRAYVER: в $(...) присваивание
# кэша теряется в подоболочке, и бинарник запускается на каждый аутбаунд.
XRAYVER=""
xray_ver_num() {
    if [ -z "$XRAYVER" ]; then
        _xvs=$("$XRAY" version 2>/dev/null | head -1 | awk '{print $2}' | tr -cd '0-9.')
        if [ -n "$_xvs" ]; then
            XRAYVER=$(printf '%s' "$_xvs" | awk -F. '{ printf "%d", ($1 * 10000) + ($2 * 100) + $3 }')
        fi
        # Не определилась -- считаем современной, старую форму не пишем.
        [ -n "$XRAYVER" ] || XRAYVER=999999
    fi
    printf '%s' "$XRAYVER"
}
[ -n "$XRAY" ] || XRAY=$(command -v xray || echo /usr/bin/xray)

# Подсказки к отказам движка, текст которых не говорит, что делать;
# $1 -- вывод run -test.
# vless и trojan без TLS к публичному адресу Xray-core отвергает с 26.7.11
# (validateOutboundTransportSecurity; частный адрес -- исключение).
xray_hint() {
    case "$1" in
      *"without TLS"*)
        warn "  Xray-core с 26.7.11 не пускает vless и trojan без TLS или reality к публичному адресу"
        warn "  нужен ключ с security=tls или reality; без шифрования транспорта — только сервер в частной сети" ;;
      *'"allowInsecure"'*)
        warn "  Xray-core с 26.3.27 не даёт отключать проверку сертификата сервера (allowInsecure)"
        warn "  нужен отпечаток сертификата в ключе (pcs= или pinSHA256=) либо настоящий сертификат на сервере" ;;
    esac
}

# apk с OpenWrt 25.12, opkg на прежних: подсказка не должна давать
# команду чужого менеджера.
PKG_FIX="apk update && apk add"
if ! command -v apk >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then
    PKG_FIX="opkg update && opkg install"
fi
