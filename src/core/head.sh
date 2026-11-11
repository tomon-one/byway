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
BYWAY_NUM="0.4.1"
BYWAY_NAME="Ice Road"
BYWAY_VERSION="$BYWAY_NUM ($BYWAY_NAME)"
# Откуда берутся обновления; чужая сборка меняет одно место.
BYWAY_REPO="tomon-one/byway"
# Открытый ключ подписи выпусков (usign/signify, byway-release.pub): им
# byway update и установщик проверяют SHA256SUMS выпуска. Тот же -- в
# install.sh (BYWAY_PUBKEY), править парой.
BYWAY_PUBKEY="RWQ9r7vQihS1LvQHytsWrPqBkUalRDrj6JBUInbi7KXlUUPHBMzFmvJl"
# Версия Xray-core, на которой byway прогнан целиком: её ставит `byway engine
# tested`. Та же в install.sh (XRAY_TESTED) -- править парой.
XRAY_TESTED=26.11.9
# Суммы SHA2-256 архивов этой версии по сборкам: .dgst лежит рядом с архивом
# на GitHub, а эти -- в подписанном выпуске byway. Вписывает
# scripts/pc/xray-sums.py; тот же блок -- в install.sh.
XRAY_TESTED_SUMS="linux-32=225343a01db48e23c1d3091e7fa45971b0d12c20943927846a4a87da374e384d
linux-64=b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82
linux-arm32-v6=955be2b84854ba566b2afc6c20186967e5a0ce7b2078e0f4e9a99e3aac662f38
linux-arm32-v7a=19c51e08a6562705fb1cb032a84fd87df21d7e27b194f035be7e754dbe3a97b3
linux-arm64-v8a=64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be
linux-mips32=4ceb213ad7cd8c1fc9250bb886e730665cddb9dfe891291b09231a204f8ba6ef
linux-mips32le=793dc40029283eb9ccead188b05abf0d34b64aab16ad1f6eadd204963a54837b
linux-mips64=5dfa670184e3174e9d1a585116c2abff9049992dec5dfd763b067a53030153ed
linux-mips64le=bc84f436a76c429e5bab46ef0c2338ee67d049ec5f9b7676611ead2bc0276f77
linux-riscv64=296884b8601ee95dba31e6664c6121d80e33697382a1f564f05b028e61601a84"

CONF=/etc/config/byway
LISTS=/etc/byway
OUT=$LISTS/config.json
# Журнал обращений движка -- свой файл в памяти, не syslog: сотня строк в
# минуту вытесняет из кольца в 256 КБ всё остальное за 20 минут. Усекают
# cmd_stat и сторож cmd_watch. Каталог -- root 755 (init): файл пишет движок
# от byway, но заменить его ссылкой не может -- в общем /tmp подменённый на
# ссылку журнал root обрезал бы и отдавал chown'ом по ссылке.
ACCESS=/var/run/byway/access.log
# apk с OpenWrt 25.12, opkg на прежних: подсказка не должна давать
# команду чужого менеджера.
PKG_FIX="apk update && apk add"
if ! command -v apk >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then
    PKG_FIX="opkg update && opkg install"
fi
