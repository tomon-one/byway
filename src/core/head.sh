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
# (ui/main.sh).

set -e

# Версия -- вручную, В МОМЕНТ ВЫПУСКА: main идёт впереди тега, номер на нём --
# последнего выпуска. Иначе README ссылается на тег, которого нет, и
# установка одной строкой отвечает 404.
# Имя -- опознавательный знак сборки, одно английское на все языки, не
# переводить. Ряд по минорам: 0.0 Desire Path, 0.1 Portage, 0.2 Causeway,
# 0.3 Ford, 0.4 Ice Road, 0.5 Trail, 0.6 Bypass, 0.7 Country Lane, 0.8 Old
# Road.
# Автообновление ходит только внутри минорной версии (cmd_watch).
BYWAY_NUM="0.3.0"
BYWAY_NAME="Ford"
BYWAY_VERSION="$BYWAY_NUM ($BYWAY_NAME)"
# Откуда берутся обновления; чужая сборка меняет одно место.
BYWAY_REPO="tomon-one/byway"
# Открытый ключ подписи выпусков (usign/signify, byway-release.pub): им
# byway update и установщик проверяют SHA256SUMS выпуска. Тот же -- в
# install.sh (BYWAY_PUBKEY), править парой.
BYWAY_PUBKEY="RWQ9r7vQihS1LvQHytsWrPqBkUalRDrj6JBUInbi7KXlUUPHBMzFmvJl"
# Версия Xray-core, на которой byway прогнан целиком: её ставит `byway engine
# tested`. Та же в install.sh (XRAY_TESTED) -- править парой.
XRAY_TESTED=26.9.30
# Суммы SHA2-256 архивов этой версии по сборкам: .dgst лежит рядом с архивом
# на GitHub, а эти -- в подписанном выпуске byway. Вписывает
# scripts/pc/xray-sums.py; тот же блок -- в install.sh.
XRAY_TESTED_SUMS="linux-32=277ffde84d86cb593ae9c3d144b11a5e4c80ba579fdfe6fe09830e04c85d04aa
linux-64=f851110beaff16e78d643f0ccfd9524b4a44dfd59bae3e34bb52bba378f7690e
linux-arm32-v6=15828543cffe24e628c43b25d4a31627ad29ef916f8b77fab69feb8b3a7ac4b6
linux-arm32-v7a=0b9719471c7c69752857714e9711d4da57cf38a6beb75dcddfb21425f7919908
linux-arm64-v8a=9886f077f9fd8e6713b84c377c1c7db4e53b9bfa8c276a5bd12561139522b473
linux-mips32=8e753eaad5147115a327c7084a2f26aee42149c0f16a962a04ea103a055db555
linux-mips32le=c41a4d7b7fafbf3ea345eef0b51c3dd68f4894e15069c19f3432670b13cbc160
linux-mips64=444f3f78274030c431ea40599f8ed38da3a180e57afd5ff2b7fd79b904e018db
linux-mips64le=387cd3e5b825b56b63551ead5c3786e1108321cf1aa4ec0907ec56ec44b48726
linux-riscv64=8c489f330f5155d335a31577780e94d98459425844f200d65a664edfe871a924"

CONF=/etc/config/byway
LISTS=/etc/byway
OUT=$LISTS/config.json
# Журнал обращений движка -- свой файл в памяти, не syslog: сотня строк в
# минуту вытесняет из кольца в 256 КБ всё остальное за 20 минут. Усекают
# cmd_stat и сторож cmd_watch. Каталог -- root 755 (init): файл пишет движок
# от byway, но заменить его ссылкой не может -- в общем /tmp подменённый на
# ссылку журнал root обрезал бы и отдавал chown'ом по ссылке.
ACCESS=/var/run/byway/access.log
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
# напечатанное здесь осталось бы русским. Печатается в core/lang.sh.
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
