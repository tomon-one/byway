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
XRAY_TESTED=26.10.21
# Суммы SHA2-256 архивов этой версии по сборкам: .dgst лежит рядом с архивом
# на GitHub, а эти -- в подписанном выпуске byway. Вписывает
# scripts/pc/xray-sums.py; тот же блок -- в install.sh.
XRAY_TESTED_SUMS="linux-32=dde802c3c932aa1b8cdc5010de81b54719ff5e334f7c4800354825ed6c9d68b6
linux-64=0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978
linux-arm32-v6=cbc12722c484c022f9e31593bd29d5cd4593c98397514ebfc3289953eeb36a64
linux-arm32-v7a=89978508fa2ebb4a1e661f2c6ed51d241c4091b3cd17f4c65fdf20baae7dedac
linux-arm64-v8a=d1304946c486d98e6b886e9b931eaaaebb23835b30e217638037b7f2721d4e9c
linux-mips32=3de6ee6a5142fb1372334ad1411f61f1b0a3f9d622a748a6080a29dc007ba207
linux-mips32le=1e9953aecee4024d9da6427a42929817b53d1660f5122ec6b22629e11cab4012
linux-mips64=b87d3fefa9add100dd9eab8504c1ce81a9f057dfe9dc906f28eb4fb5798833f5
linux-mips64le=44e45c2fd113d6a96d63872717348b5c29a86fe15a6bd3abb3395f2d8b6ef7c2
linux-riscv64=3045051037f5f543bd9e4787f331de9e8c83db0a072a26e49ef88512da5bfd48"

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
