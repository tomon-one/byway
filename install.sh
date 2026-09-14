#!/bin/sh
#
# Установка byway на OpenWrt.
#
# ⚠️ Ни install, ни base64, ни comm в busybox НЕТ. Здесь только cp, chmod и
# mkdir. Проверено на живом роутере: install отвечает «not found».
#
# Два способа запуска, оба рабочие:
#   - из каталога поставки:  sh install.sh
#   - одной строкой:         sh -c "$(wget -O - .../install.sh)"
# Во втором случае рядом со скриптом нет ничего, и он дотягивает остальную
# поставку сам -- с того же тега, что зашит в VER ниже.
#
# На ЧИСТОМ роутере ничего не запускает: без ключа запускать нечего, в конце
# печатается памятка. А вот при установке поверх настроенного byway -- наоборот:
# пересобирает конфиг движка и перезапускает службу, потому что иначе новая
# программа лежит на диске, а работает старая, до самой перезагрузки.
#
# Идемпотентен. Существующие конфигурацию и списки НЕ трогает — повторный
# запуск обновляет только программу и панель.

set -e

# Язык установщика. Словари byway лежат в /etc/byway/lang и появляются только
# в конце установки -- а установщик человек читает ПЕРВЫМ, ещё до того как
# что-то поставлено. Поэтому словарь здесь, внутри файла: скрипт часто
# запускают одной строкой через wget, и рядом с ним нет вообще ничего.
LANG_EN=0

_say()  { printf '\033[1;32m[*]\033[0m %s\n' "$1"; }
_warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
_die()  { printf '\033[1;31m[x]\033[0m %s\n' "$1"; exit 1; }
say()  { _say  "$(t "$1")"; }
warn() { _warn "$(t "$1")"; }
die()  { _die  "$(t "$1")"; }
# Переводится ФОРМАТ, а не готовая строка: подставленное число или путь в
# словаре не найдётся никогда, и сообщение молча осталось бы русским.
sayf()  { _f=$(t "$1"); shift; _say  "$(printf "$_f" "$@")"; }
# Строка БЕЗ значка, но С переводом. Нужна для пунктов меню: у них своё
# выравнивание, и «[*]» перед ними ломает столбик.
#
# ⚠️ Заведена не для красоты. Пункты печатались голым `echo`, а он ничего не
# переводит -- при этом записи в словаре для них лежали и выглядели рабочими.
# То есть английский пользователь читал вопрос по-английски, а варианты
# ответа по-русски. Голый `echo` с русским текстом в этом файле теперь
# допустим ровно в одном месте: в вопросе о языке, который двуязычен сам.
line()  { printf '%s\n' "$(t "$1")"; }
linef() { _f=$(t "$1"); shift; printf "$_f\n" "$@"; }
warnf() { _f=$(t "$1"); shift; _warn "$(printf "$_f" "$@")"; }
dief()  { _f=$(t "$1"); shift; _die  "$(printf "$_f" "$@")"; }


# Словарь. Ключ -- русская строка из кода: пропущенный перевод оставляет
# русский текст, а не пустое место. Всё, чего здесь нет, проходит как есть --
# поэтому команды и пути переводить не требуется, они просто не ключи.
t() {
    [ "$LANG_EN" = 1 ] || { printf %s "$1"; return 0; }
    case "$1" in
      "── Проверка окружения ──") printf %s "── Checking the environment ──" ;;
      "-- по умолчанию:") printf %s "-- default:" ;;
      "── Установка ──") printf %s "── Installing ──" ;;
      "── Готово ──") printf %s "── Done ──" ;;
      "не похоже на OpenWrt — byway рассчитан на него") printf %s "this does not look like OpenWrt — byway is built for it" ;;
      "поставки рядом нет — загрузка с GitHub") printf %s "no delivery next to the script — downloading it from GitHub" ;;
      "тега v%s ещё нет — взята ветка main") printf %s "there is no v%s tag yet — taking the main branch" ;;
      "поставка распакована: %s") printf %s "delivery unpacked: %s" ;;
      "не удалось получить поставку — скачать архив с github.com/%s и запустить install.sh из него") printf %s "could not get the delivery — download the archive from github.com/%s and run install.sh from it" ;;
      "движок записан в настройки: %s") printf %s "the core is recorded in the settings: %s" ;;
      "движок не найден: byway установлен, но служба не поднимется") printf %s "core not found: byway is installed, but the service will not start" ;;
      "  указать путь: uci set byway.main.xray_bin=/путь/к/xray && uci commit byway") printf %s "  set the path: uci set byway.main.xray_bin=/path/to/xray && uci commit byway" ;;
      "движок не поднялся — смотреть: logread -e byway") printf %s "the core did not come up — see: logread -e byway" ;;
      "движок уже указан в настройках: %s") printf %s "the core is already set in the settings: %s" ;;
      "не удалось положить %s — проверить место на флеше и права") printf %s "could not put %s in place — check free flash and permissions" ;;
      "рядом лежит НЕПОЛНАЯ поставка, не хватает:%s") printf %s "the delivery next to the script is INCOMPLETE, missing:%s" ;;
      "  берётся целая с GitHub — то, что лежит рядом, использовано не будет") printf %s "  taking a whole one from GitHub — what is next to the script will not be used" ;;
      "конфиг не пересобрался — движок остаётся на прежнем") printf %s "the config was not rebuilt — the core stays on the previous one" ;;
      "перезапуск службы — туннель прервётся на несколько секунд") printf %s "restarting the service — the tunnel will drop for a few seconds" ;;
      "служба перезапущена на новой версии") printf %s "the service is restarted on the new version" ;;
      "служба не перезапустилась — сделать это руками: /etc/init.d/byway restart") printf %s "the service did not restart — do it by hand: /etc/init.d/byway restart" ;;
      "Обновлено. Если открыта панель — обновить страницу с очисткой кэша (Ctrl+F5).") printf %s "Updated. If the panel is open, reload the page with a cache reset (Ctrl+F5)." ;;
      "нет %s -- установка") printf %s "no %s -- installing" ;;
      "не поставился %s: доставить вручную") printf %s "%s did not install: add it by hand" ;;
      "нет утилиты %s -- это не похоже на рабочий OpenWrt") printf %s "no %s tool -- this does not look like a working OpenWrt" ;;
      "нет модулей ядра:%s -- установка") printf %s "kernel modules missing:%s -- installing" ;;
      "модули так и не встали:%s") printf %s "the modules are still not there:%s" ;;
      "  без них перехват не работает; поставить вручную:") printf %s "  without them interception does not work; install by hand:" ;;
      "не знаю, какой файл выпуска брать для %s") printf %s "I do not know which release file to take for %s" ;;
      "на флеше %s МБ, движку нужно около 25 -- берётся из прошивки") printf %s "%s MB on flash, the core needs about 25 -- taking it from the feed" ;;
      "нет unzip, распаковать нечем") printf %s "no unzip, nothing to unpack with" ;;
      "не удалось спросить у GitHub последнюю версию") printf %s "could not ask GitHub for the latest version" ;;
      "последний выпуск: %s") printf %s "latest release: %s" ;;
      "установка Xray-core %s (%s)") printf %s "installing Xray-core %s (%s)" ;;
      "не скачался") printf %s "download failed" ;;
      "не распаковался") printf %s "unpacking failed" ;;
      "скачанный движок не запускается на этом железе -- берётся из прошивки") printf %s "the downloaded core does not run on this hardware -- taking it from the feed" ;;
      "движок готов: %s") printf %s "core ready: %s" ;;
      "Движок Xray-core не найден. Откуда взять:") printf %s "Xray-core was not found. Where should it come from:" ;;
      "     2) с GitHub -- свежее, около 35 МБ на флеше") printf %s "     2) GitHub -- newer, about 35 MB of flash" ;;
      "     3) никак -- путь укажу сам потом") printf %s "     3) neither -- I will set the path myself later" ;;
      "Выбор") printf %s "Choice" ;;
      "        latest  -- последний СТАБИЛЬНЫЙ выпуск (по умолчанию)") printf %s "        latest  -- the latest STABLE release (default)" ;;
      "        tested  -- на которой byway проверялся: %s") printf %s "        tested  -- the one byway was verified on: %s" ;;
      "                   это ПРЕДВЫПУСК: XTLS помечает так всё свежее стабильного") printf %s "                   it is a PRE-RELEASE: XTLS marks everything newer than stable that way" ;;
      "        26.3.27 -- или любая другая, номером") printf %s "        26.3.27 -- or any other, by number" ;;
      "Версия") printf %s "Version" ;;
      "движок не ставится: указать путь после установки") printf %s "the core is not installed: set the path afterwards" ;;
      "движок не ставится: система не подходит, см. выше") printf %s "the core is not installed: this system does not qualify, see above" ;;
      "система не подходит -- ничего не установлено") printf %s "this system does not qualify -- nothing has been installed" ;;
      "GitHub напрямую не отвечает — его адреса запрашиваются по DoH") printf %s "GitHub does not answer directly — resolving its addresses over DoH" ;;
      "адреса получены — соединение напрямую, минуя подменённый DNS") printf %s "addresses resolved — going direct, bypassing the spoofed DNS" ;;
      "GitHub недоступен, а зеркало запрещено (NO_MIRROR=1) — установка не пойдёт") printf %s "GitHub is unreachable and the mirror is forbidden (NO_MIRROR=1) — the install will not proceed" ;;
      "ни напрямую, ни по адресам из DoH — через зеркало gh-proxy") printf %s "neither directly nor by the DoH addresses — going through the gh-proxy mirror" ;;
      "  это ЧУЖОЙ посредник: он видит, что вы качаете, и может отдать не то.") printf %s "  it is a THIRD PARTY: it sees what you download and may serve you something else." ;;
      "  запретить: NO_MIRROR=1 sh install.sh (тогда установка просто не пойдёт)") printf %s "  to forbid it: NO_MIRROR=1 sh install.sh (the install will then simply not proceed)" ;;
      "ответ «%s» непонятен -- взят вариант 1") printf %s "did not understand the answer «%s» -- taking option 1" ;;
      "     2) с GitHub -- НЕ для этого процессора: MIPS выкладывают только с аппаратной плавающей точкой") printf %s "     2) from GitHub -- NOT for this CPU: MIPS is published hard-float only" ;;
      "на этом процессоре сборка с GitHub не запустится: MIPS там только с аппаратной плавающей точкой, а сопроцессора здесь нет") printf %s "the GitHub build will not run on this CPU: MIPS is published hard-float only, and there is no FPU here" ;;
      "  из прошивки приезжает та же версия, собранная softfloat") printf %s "  the feed ships the same version built soft-float -- taking that one" ;;
      "Движок Xray-core. Какую версию поставить:") printf %s "Xray-core. Which version to install:" ;;
      "     1) проверенную с byway -- %s  (по умолчанию)") printf %s "     1) the one verified with byway -- %s  (default)" ;;
      "     2) самую свежую, включая предвыпуски") printf %s "     2) the newest one, pre-releases included" ;;
      "     3) самую свежую стабильную") printf %s "     3) the newest stable one" ;;
      "     4) никакую -- путь укажу сам потом") printf %s "     4) none -- I will set the path myself later" ;;
      "     либо впишите номер версии, например 26.3.27") printf %s "     or type a version number, for example 26.3.27" ;;
      "версия: %s") printf %s "version: %s" ;;
      "ответ «%s» непонятен -- взята проверенная версия") printf %s "did not understand the answer «%s» -- taking the verified version" ;;
      "не удалось спросить у GitHub номер версии -- берётся из прошивки") printf %s "could not ask GitHub for a version number -- taking the firmware one" ;;
      "Движок Xray-core. На этом процессоре сборки с GitHub не запускаются,") printf %s "Xray-core. Builds from GitHub do not run on this CPU," ;;
      "поэтому он берётся из прошивки:") printf %s "so it is taken from the firmware:" ;;
      "     1) поставить из прошивки  -- по умолчанию") printf %s "     1) install from the firmware  -- default" ;;
      "     2) никакой -- путь укажу сам потом") printf %s "     2) none -- I will set the path myself later" ;;
      "непонятный номер версии «%s»") printf %s "unclear version number «%s»" ;;
      "установка xray-core из прошивки") printf %s "installing xray-core from the feed" ;;
      "Xray-core не поставился из прошивки") printf %s "Xray-core did not install from the firmware" ;;
      "  и указать путь: uci set byway.main.xray_bin=/путь/к/xray") printf %s "  and point byway at it: uci set byway.main.xray_bin=/path/to/xray" ;;
      "Поставить base64? Нужен только для ключей vmess:// и ss://") printf %s "Install base64? Needed only for vmess:// and ss:// keys" ;;
      "  весь вывод пакетного менеджера: cat %s") printf %s "  the package manager said it all here: cat %s" ;;
      "не поставился: ключи vmess и ss разобрать не выйдет") printf %s "did not install: vmess and ss keys will not parse" ;;
      "base64 не ставится -- ключи vless, trojan и socks работают без него") printf %s "base64 is skipped -- vless, trojan and socks keys work without it" ;;
      "на разделе изменений %s МБ, а движку нужно около 30 -- сюда он не встанет") printf %s "%s MB on the overlay partition, and the engine needs about 30 -- it will not fit here" ;;
      "  это не поправить настройкой: нужен роутер с большим флешем либо extroot на USB") printf %s "  no setting fixes this: you need a router with more flash, or extroot on USB" ;;
      "на флеше меньше 2 МБ свободно") printf %s "less than 2 MB free on flash" ;;
      "и главное: у роутера нет маршрута наружу — почти всё выше поэтому") printf %s "and the main thing: the router has no default route — that explains most of the above" ;;
      "  проверить: ifstatus wan, ip route, ip link") printf %s "  check: ifstatus wan, ip route, ip link" ;;
      "и главное: наружу не пускает — почти всё выше поэтому") printf %s "and the main thing: something blocks the way out — that explains most of the above" ;;
      "  проверить: firewall, ping 1.1.1.1, traceroute") printf %s "  check: firewall, ping 1.1.1.1, traceroute" ;;
      "и главное: DNS не отвечает — почти всё выше поэтому") printf %s "and the main thing: DNS does not answer — that explains most of the above" ;;
      "  проверить: cat /etc/resolv.conf, /etc/init.d/dnsmasq restart") printf %s "  check: cat /etc/resolv.conf, /etc/init.d/dnsmasq restart" ;;
      "в cron легло НЕ ВСЁ — проверить: crontab -l") printf %s "not everything made it into cron — check: crontab -l" ;;
      "  нет задачи byway watch: не будет ни проверки версии, ни обновления списков") printf %s "  the byway watch job is missing: no version check and no list updates" ;;
      "  нет задачи byway stat: учёт использования собираться не будет") printf %s "  the byway stat job is missing: usage accounting will not be collected" ;;
      "firewall4 не найден, а byway работает только на нём — это OpenWrt 22.03 и новее") printf %s "firewall4 is not present, and byway runs on nothing else — that means OpenWrt 22.03 or newer" ;;
      "  на 21.02 и старше файрволом заведует firewall3 с iptables: другой механизм,") printf %s "  on 21.02 and older the firewall is firewall3 on iptables: a different machine," ;;
      "  правило по метке туда не встанет, и туннель не получат ни гости, ни зоны") printf %s "  a mark-based rule will not go in there, and neither guests nor zones with an" ;;
      "  с политикой input REJECT. Половина работающего byway хуже честного отказа.") printf %s "  input REJECT policy would get the tunnel. Half a byway is worse than a plain no." ;;
      "  своя версия: cat /etc/openwrt_release") printf %s "  your own version: cat /etc/openwrt_release" ;;
      "  ${PKG:-apk} update && ${PKG:-apk} ${PKG_ADD:-add} xray-core -- либо положить бинарник вручную") printf %s "  ${PKG:-apk} update && ${PKG:-apk} ${PKG_ADD:-add} xray-core -- or drop the binary in by hand" ;;
      "  uci set byway.main.xray_bin=/путь/к/xray && uci commit byway") printf %s "  uci set byway.main.xray_bin=/path/to/xray && uci commit byway" ;;
      "не хватает %s условий — доставить перечисленное и запустить снова") printf %s "%s conditions are missing — install what is listed and run again" ;;
      "всё на месте") printf %s "everything is in place" ;;
      "программа и служба") printf %s "the program and the service" ;;
      "программа и служба, автозапуск включён") printf %s "the program and the service, autostart enabled" ;;
      "служба не встала в автозапуск -- после перезагрузки туннеля не будет; поправить: /etc/init.d/byway enable") printf %s "the service did not get into autostart -- after a reboot there will be no tunnel; fix: /etc/init.d/byway enable" ;;
      "конфигурация уже есть, остаётся без изменений") printf %s "the configuration already exists and is left alone" ;;
      "конфигурация создана из шаблона") printf %s "the configuration is created from the template" ;;
      "списки на месте") printf %s "the lists are in place" ;;
      "словари перевода: %s") printf %s "translation dictionaries: %s" ;;
      "панель LuCI: Сервисы → Byway") printf %s "LuCI panel: Services → Byway" ;;
      "каталога luci рядом нет — панель не установлена") printf %s "there is no luci directory next to the script — the panel is not installed" ;;
      "пути внесены в keep-список прошивки") printf %s "the paths are added to the firmware keep-list" ;;
      "byway доступен по имени из любой оболочки") printf %s "byway is available by name from any shell" ;;
      "задачи в cron: журнал состояния и учёт использования") printf %s "cron jobs: the state log and the usage count" ;;
      "правило firewall для помеченного трафика создано") printf %s "the firewall rule for marked traffic is created" ;;
      *) printf %s "$1" ;;
    esac
}

SRC=$(dirname "$0")
BAD=0
FATAL=0   # непоправимое: система не того поколения, доставлять нечего

# Откуда дотянуть поставку, если рядом со скриптом её нет. Версия константой,
# а не «последняя»: установщик и файлы, которые он кладёт, обязаны быть одного
# тега, иначе панель окажется новее программы или наоборот.
REPO=tomon-one/byway
VER=0.2.1
# Версия движка, на которой byway проверялся целиком -- на живом роутере, с
# поднятым туннелем и реальным трафиком. Правится вместе с выпуском: протухшая
# «проверенная» хуже её отсутствия.
#
# ⚠️ Это ПРЕДВЫПУСК, и вариант «latest» его не даст. XTLS помечает
# предвыпуском ВСЁ, что новее 26.3.27 (проверено 2026-09-06: восемь выпусков
# подряд с pre=true), поэтому `releases/latest` отдаёт мартовский стабильный.
# Отсюда и два разных варианта в вопросе: «самый свежий» и «стабильный» у
# Xray -- это РАЗНЫЕ вещи, и человек должен выбирать зная это.
XRAY_TESTED=26.7.28

# Стояла ли программа ДО этого запуска. Спрашиваем сейчас, потому что после
# копирования различить установку и обновление уже нечем, а сказать человеку
# надо разное -- и службу при обновлении надо перезапустить, иначе движок
# продолжает работать по конфигу прежней версии.
WAS_INSTALLED=0
[ -f /usr/local/bin/byway ] && WAS_INSTALLED=1

# Свободное место на разделе, который переживает перезагрузку. Меряем
# /overlay, а не корень: корень на OpenWrt -- squashfs, свободного места там
# ноль по определению, и любой замер по нему бессмыслен.
# Скачивание. На роутере, где byway УЖЕ работает, github.com обычно лежит в
# его собственном списке -- и тогда сам роутер до него не достаёт: правила
# tproxy ловят трафик мостов, а не свой собственный, и curl возвращает 000.
# Поэтому сперва пробуем через локальный прокси-вход byway, потом напрямую.
# Порядок тот же, что у fetch_list внутри самой программы. На чистом роутере
# первая попытка стоит миллисекунд: никто не слушает, соединение отвергается
# сразу.
PXP=$(uci -q get byway.main.local_proxy_port 2>/dev/null || true)
PXP=${PXP:-1603}
# Зеркало -- ТРЕТЬЯ попытка, после прокси byway и прямого пути.
#
# Зачем оно вообще. README предлагает ставить через зеркало тому, у кого
# `raw.githubusercontent.com` недоступен. Но одной строкой на роутер попадает
# ТОЛЬКО install.sh, а поставку он тянул с `github.com` напрямую -- то есть
# человек, которому зеркало и понадобилось, получал скрипт и упирался на
# втором шаге. Способ из README работал наполовину. Поймано вопросом владельца
# «а на ссылке с прокси тестировал? вдруг вообще не работает».
#
# Зеркало ЧУЖОЕ: публичный gh-proxy, тот же, что у Zapret-Manager. Мы его не
# держим и не проверяем, что он отдаёт. Поэтому оно не подставляется молча --
# о переходе говорится вслух, и его можно запретить: NO_MIRROR=1 sh install.sh
MIRROR=https://v4.gh-proxy.org

dl() {   # аргументы curl как есть, --max-time задаёт вызывающий
    curl -fsSL --proxy "http://127.0.0.1:$PXP" "$@" 2>/dev/null && return 0
    # $GH_RES не в кавычках НАМЕРЕННО: это набор отдельных аргументов вида
    # `--resolve host:443:1.2.3.4`, и разбиение по пробелам здесь и нужно.
    # Опасности нет -- значения собираются нами из цифр, точек и имён, чужого
    # текста в них не бывает.
    # shellcheck disable=SC2086
    curl -fsSL $GH_RES "$@" 2>/dev/null
}

# Доступен ли GitHub напрямую -- решается ОДНОЙ пробой, в начале, и дальше все
# его адреса строятся уже с учётом ответа.
#
# Приём подсмотрен у Zapret-Manager и он лучше отката на каждой загрузке: на
# закрытой сети откат заставлял КАЖДОЕ скачивание сперва дважды упереться в
# таймаут, а их у установщика несколько. Здесь ожидание одно и короткое.
#
# Зачем вообще: README предлагает ставить через зеркало тому, у кого
# `raw.githubusercontent.com` недоступен. Но одной строкой на роутер попадает
# ТОЛЬКО install.sh, а поставку он тянул с `github.com` напрямую -- то есть
# человек, которому зеркало и понадобилось, упирался на втором шаге. Способ из
# README работал наполовину.
# Адрес имени через DoH. Спрашиваем у публичного резолвера по HTTPS: он
# отвечает на 443, а не на 53, и потому переживает подмену ответов у
# провайдера -- ту самую, ради обхода которой Zapret-Manager прибивает адреса
# в /etc/hosts гвоздями. Гвоздей не ставим: прибитый адрес однажды протухнет,
# а CDN их меняет.
doh_a() {   # 1 -- имя
    for _dq in "https://dns.google/resolve?name=$1&type=A" \
               "https://cloudflare-dns.com/dns-query?name=$1&type=A"; do
        _da=$(curl -fsSL --max-time 8 -H "accept: application/dns-json" "$_dq" 2>/dev/null |
              tr ',' '\n' | sed -n 's/.*"data":"\([0-9][0-9.]*\)".*/\1/p' | head -1)
        case "$_da" in
          [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf '%s' "$_da"; return 0 ;;
        esac
    done
    return 1
}


# ⚠️ Проба ЛЕНИВАЯ. Раньше она стояла здесь безусловно -- и роутер без
# интернета, у которого поставка уже лежит рядом, всё равно ждал таймаутов и
# читал предупреждение про чужое зеркало, хотя качать было нечего. Теперь
# зовётся из тех мест, где начинается настоящая загрузка. Найдено третьим
# аудитом 2026-09-07.
#
# Раньше первой загрузки её всё равно нельзя: сама ходит через curl, а его
# установщик доставляет чуть выше.
gh_ready() { [ "${GH_DONE:-0}" = 1 ] || { GH_DONE=1; gh_probe; }; }

gh_probe() {
    GH=""
    GH_RES=""
    # Через dl, а НЕ голым curl: dl ходит сперва через локальный прокси
    # byway, и на роутере, где byway уже работает, это ЕДИНСТВЕННЫЙ путь к
    # GitHub -- его домены лежат в списке, а собственный трафик роутера в
    # перехват не попадает. Голая проба на таком роутере объявляла GitHub
    # недоступным и уводила установку на чужое зеркало без всякой нужды.
    # Поймано прогоном на боевом роутере, а не разбором.
    dl --max-time 6 -o /dev/null \
        "https://raw.githubusercontent.com/$REPO/refs/heads/main/install.sh" && return 0

    # Вторая ступень: имя не разрешается или ответ подменён -- спрашиваем
    # адрес по HTTPS и подставляем его curl напрямую. Соединение при этом
    # идёт к НАСТОЯЩЕМУ узлу GitHub, сертификат проверяется как обычно, и
    # никакой посредник в середине не появляется.
    say "GitHub напрямую не отвечает — его адреса запрашиваются по DoH"
    _gr=""
    for _gh in raw.githubusercontent.com github.com api.github.com \
               codeload.github.com objects.githubusercontent.com; do
        _gi=$(doh_a "$_gh") || continue
        _gr="$_gr --resolve $_gh:443:$_gi"
    done
    if [ -n "$_gr" ]; then
        GH_RES=$_gr
        if dl --max-time 8 -o /dev/null \
              "https://raw.githubusercontent.com/$REPO/refs/heads/main/install.sh"; then
            say "адреса получены — соединение напрямую, минуя подменённый DNS"
            return 0
        fi
        GH_RES=""
    fi

    # Третья ступень -- чужое зеркало, и только если предыдущие не вышли.
    [ "${NO_MIRROR:-0}" = 1 ] && {
        warn "GitHub недоступен, а зеркало запрещено (NO_MIRROR=1) — установка не пойдёт"
        return 0
    }
    # Зеркало ЧУЖОЕ: публичный gh-proxy, тот же, что у Zapret-Manager. Мы его
    # не держим и не проверяем, что он отдаёт, -- поэтому говорим вслух.
    warn "ни напрямую, ни по адресам из DoH — через зеркало gh-proxy"
    warn "  это ЧУЖОЙ посредник: он видит, что вы качаете, и может отдать не то."
    warn "  запретить: NO_MIRROR=1 sh install.sh (тогда установка просто не пойдёт)"
    GH=$MIRROR/
}

# Адрес GitHub с учётом решения пробы. Зовётся ВМЕСТО прямого адреса везде,
# где установщик ходит на github.com, raw и api.
gh() { printf '%s%s' "$GH" "$1"; }

# Код ответа, а не «получилось или нет». Нужен там, где различие существенно:
# 404 на теге -- это «тега нет», а любой другой отказ -- «сеть подвела», и
# путать их нельзя.
http_code() {
    # Код забираем в переменную, а не печатаем на месте. Без -f curl
    # печатает 000 и при отказе соединения, но возвращает ненулевой код --
    # и обе попытки печатали подряд, склеиваясь в 000404. Поймано стендом,
    # а не разбором: на глаз функция выглядела правильной.
    _hc=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 25 \
          --proxy "http://127.0.0.1:$PXP" "$1" 2>/dev/null || true)
    case "$_hc" in ''|000) ;; *) printf '%s' "$_hc"; return 0 ;; esac
    # shellcheck disable=SC2086
    _hc=$(curl -sSL $GH_RES -o /dev/null -w '%{http_code}' --max-time 25 "$1" 2>/dev/null || true)
    printf '%s' "${_hc:-000}"
}

free_mb() {
    _m=/overlay; [ -d /overlay ] || _m=/
    _v=$(df -k "$_m" 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    [ -n "$_v" ] || _v=$(df -k / 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    printf '%s' "$_v"
}

# ── вопросы ────────────────────────────────────────────────────────────────
#
# Спрашиваем ТОЛЬКО про то, что можно не ставить: обязательное ставится молча.
# Человеку, который просто хочет туннель, лишний вопрос -- это ещё одно
# решение, которое он не готов принять и примет наугад.
#
# Читаем с /dev/tty, а не со стандартного входа. Разница видна на самом
# частом способе запуска: `wget -O - … | sh` отдаёт скрипту КАНАЛ вместо
# клавиатуры, и read вычитал бы из него остаток самого скрипта -- вопрос
# получил бы ответом строку кода. С /dev/tty вопросы работают и так, и через
# `sh -c "$(wget -O - …)"`. А когда терминала нет вовсе (установка из
# другого скрипта), берём умолчание и говорим об этом вслух.
ASK=0
if [ -c /dev/tty ] && (: >/dev/tty) 2>/dev/null; then ASK=1; fi
# Двуязычно и без словаря: эта строка печатается ДО того, как язык выбран.
[ "$ASK" = 1 ] ||
    _warn "терминала нет, ответы берутся по умолчанию / no terminal, defaults are used"

ask() {   # $1 вопрос, $2 умолчание y|n -- отвечает кодом возврата
    if [ "$ASK" = 0 ]; then
        printf '\033[1;36m[?]\033[0m %s %s\n' "$(t "$1")" "$(t "-- по умолчанию:") $2"
        [ "$2" = y ]
        return $?
    fi
    # Буквы подсказки тоже переводятся: английский читатель видел «[Д/н]» и
    # не знал, что нажимать -- хотя ответ на латинице принимается ниже.
    # Найдено третьим аудитом 2026-09-07.
    # Латиница в обоих языках: в терминале работают на английской раскладке,
    # и предложить кириллическую букву -- значит попросить переключиться ради
    # одного нажатия. Ответ принимается любой: y, n, д, н.
    if [ "$2" = y ]; then _d="[Y/n]"; else _d="[y/N]"; fi
    printf '\033[1;36m[?]\033[0m %s %s ' "$(t "$1")" "$_d" > /dev/tty
    read -r _a < /dev/tty || _a=""
    case "$_a" in
        [yYдД]*) return 0 ;;
        [nNнН]*) return 1 ;;
        *)       [ "$2" = y ] ;;
    esac
}

askv() {  # $1 вопрос, $2 умолчание -- печатает выбранное
    if [ "$ASK" = 0 ]; then printf '%s' "$2"; return 0; fi
    printf '\033[1;36m[?]\033[0m %s [%s] ' "$(t "$1")" "$2" > /dev/tty
    read -r _a < /dev/tty || _a=""
    printf '%s' "${_a:-$2}"
}

# Язык спрашивается ПЕРВЫМ, до единой проверки: всё, что установщик скажет
# дальше, человек должен прочитать. На повторном запуске умолчанием служит
# уже выбранный язык -- обновление не должно молча переключать интерфейс.
case "$(uci -q get byway.main.lang 2>/dev/null)" in en) LANG_EN=1 ;; esac
echo
echo "  Язык / Language:   1) Русский   2) English"
if [ "$LANG_EN" = 1 ]; then _dl=2; else _dl=1; fi
case "$(askv "Выбор / Choice" "$_dl")" in
  2|en|EN|e|E) LANG_EN=1 ;;
  *)           LANG_EN=0 ;;
esac
echo
say "── Проверка окружения ──"

# Проверяем ДО установки, а не после: человек должен узнать о нехватке
# модуля сразу, а не когда обвязка молча не поднимется.
[ -f /etc/openwrt_release ] || warn "не похоже на OpenWrt — byway рассчитан на него"

# Пакетный менеджер определяем сами: apk с OpenWrt 25.12, opkg на 24.10 и
# прежних. Просить человека набрать команду руками -- значит отправить его
# читать, чем его прошивка отличается от нашей, ради того, что скрипт узнаёт
# за одну проверку.
PKG=""
command -v apk  >/dev/null 2>&1 && PKG=apk
[ -z "$PKG" ] && command -v opkg >/dev/null 2>&1 && PKG=opkg
# Глагол у менеджеров РАЗНЫЙ: `apk add`, но `opkg install`. Печатаемое лечение
# подставляло имя и оставляло глагол apk -- выходило "opkg add", команды с
# таким именем нет, и совет не работал ни на одной системе до 25.12.
PKG_ADD=add
[ "$PKG" = opkg ] && PKG_ADD=install
PKG_UPDATED=0

# Список пакетов обновляем ОБОИМ менеджерам, а не одному opkg. На
# свежепрошитом роутере индексов apk нет вовсе: `apk add curl` отвечает
# «unable to select packages», и молча не ставится ничего -- ни curl, ни
# модули ядра, ни движок, а установщик доходит до конца и говорит «всё на
# месте». Печатаемое лечение поэтому тоже из двух команд: без update оно
# воспроизводило ровно тот отказ, от которого лечит.
# Куда пакетный менеджер говорит сам за себя. Его вывод мы прячем -- он
# длинный и шумный, -- а КОД ВОЗВРАТА у него врёт: apk честно напечатал
# "1 error", не поставил один пакет из четырёх и вышел с нулём (стенд,
# 2026-09-06: обрыв загрузки, "unexpected end of file"). Проверки по делу
# ниже это ловят и отказывают правильно. Но отказ без причины бесполезен:
# оборванная загрузка лечится повтором, отсутствие пакета -- нет, а выглядят
# они одинаково.
PKGLOG=/tmp/byway-pkg.log

add_pkg() {
    case "$PKG" in
      apk)  [ "$PKG_UPDATED" = 1 ] || { apk update >"$PKGLOG" 2>&1; PKG_UPDATED=1; }
            apk add "$@" >>"$PKGLOG" 2>&1 ;;
      opkg) [ "$PKG_UPDATED" = 1 ] || { opkg update >"$PKGLOG" 2>&1; PKG_UPDATED=1; }
            opkg install "$@" >>"$PKGLOG" 2>&1 ;;
      *)    return 1 ;;
    esac
}

# Показать, на что жаловался пакетный менеджер. Зовётся только с пути отказа,
# поэтому шумом не будет. Завершается `return 0` намеренно: без него grep без
# совпадений уронил бы весь установщик под `set -e`.
pkg_why() {
    [ -s "$PKGLOG" ] || return 0
    # Сначала строки, похожие на жалобу, и только если их нет -- хвост.
    # Ни того, ни другого по отдельности не хватает: apk кончает осмысленным
    # "1 error; ...", а у opkg ошибки идут в stderr без буферизации, тогда как
    # прогресс -- блоками, и в общем файле жалоба оказывается ПОСЕРЕДИНЕ, а
    # хвост показывает безобидное "Configuring ...". Обе редакции по
    # отдельности прятали причину, каждая на своём менеджере.
    _pw=$(grep -i -e error -e cannot -e failed -e unable -e "not found" -e "no such" "$PKGLOG" 2>/dev/null | tail -4)
    [ -n "$_pw" ] || _pw=$(grep -v "^[[:space:]]*$" "$PKGLOG" 2>/dev/null | tail -4)
    printf '%s\n' "$_pw" | while IFS= read -r _l; do
        [ -n "$_l" ] && _warn "  $_l"
    done
    warnf "  весь вывод пакетного менеджера: cat %s" "$PKGLOG"
    return 0
}

# Ставим недостающее сами, а не отказываемся. Отказ остаётся на случай, когда
# установка НЕ УДАЛАСЬ: тогда человеку и правда есть что чинить руками.
for c in curl; do
    command -v "$c" >/dev/null 2>&1 && continue
    sayf "нет %s -- установка" "$c"
    add_pkg "$c" && command -v "$c" >/dev/null 2>&1 ||
        { warnf "не поставился %s: доставить вручную" "$c"; pkg_why; BAD=$((BAD + 1)); }
done

# Поставка рядом со скриптом. Её может не быть вовсе: README предлагает
# запуск одной строкой, и тогда на роутер попадает ТОЛЬКО этот файл. Раньше
# такой запуск падал на первой же проверке -- то есть два из трёх описанных
# в README способов установки не работали ни разу. Проверка стоит ПОСЛЕ
# установки curl: без него дотянуть нечем.
have_src() {
    # Не только «да/нет»: имя недостающего файла нужно вызывающему. Прежняя
    # проверка его называла и останавливалась, и терять это при переходе на
    # загрузку было бы шагом назад -- половина поставки рядом это не «поставки
    # нет», а испорченная копия, и подменять её молча нельзя.
    _miss=""; _got=0
    for _f in byway etc-init.d-byway etc-config-byway; do
        if [ -f "$SRC/$_f" ]; then
            _got=$((_got + 1))
        else
            _miss="$_miss $_f"
        fi
    done
    [ -z "$_miss" ]
}

fetch_src() {
    gh_ready
    # Причины различаем: «нечем качать» лечится одной командой, «не скачалось»
    # -- совсем другим разговором. Сводить их к одному сообщению значит
    # отправить человека чинить не то.
    for _need in curl tar; do
        command -v "$_need" >/dev/null 2>&1 ||
            dief "нет утилиты %s -- это не похоже на рабочий OpenWrt" "$_need"
    done
    _sd=/tmp/byway-src.$$
    rm -rf "$_sd"
    mkdir -p "$_sd" || return 1
    # Убираем за собой НА ВЫХОДЕ, а не здесь: из этого каталога идёт
    # установка, он нужен до последнего шага. Без трапа каждый запуск
    # оставлял мегабайт в tmpfs навсегда -- это ОПЕРАТИВНАЯ ПАМЯТЬ роутера,
    # а не диск. На боевом 2026-09-07 набралось семь таких каталогов, 6.8 МБ.
    trap 'rm -rf "$_sd"' EXIT INT TERM
    # Тег -- то, что обещано и на что рассчитан этот файл. Ветка нужна, пока
    # тега ещё нет, но уходить на неё можно ТОЛЬКО когда тега действительно
    # нет: различаем по коду ответа, а не по любому отказу curl. Иначе
    # оборванная сеть на теге молча уводила бы установку на непомеченную
    # ветку -- ровно то, чего README обещает не делать («ссылка ведёт на тег,
    # а не на ветку»).
    _urls=$(gh "https://github.com/$REPO/archive/refs/tags/v$VER.tar.gz")
    if [ "$(http_code "$_urls")" = 404 ]; then
        warnf "тега v%s ещё нет — взята ветка main" "$VER"
        _urls=$(gh "https://github.com/$REPO/archive/refs/heads/main.tar.gz")
    fi
    for _u in $_urls; do
        dl --max-time 120 -o "$_sd/src.tgz" "$_u" || continue
        tar -xzf "$_sd/src.tgz" -C "$_sd" 2>/dev/null || continue
        rm -f "$_sd/src.tgz"
        # Ищем по файлу, который есть только у поставки, и берём его каталог:
        # архив GitHub кладёт всё внутрь папки с именем тега.
        _cf=$(find "$_sd" -maxdepth 3 -type f -name etc-config-byway 2>/dev/null | head -1)
        [ -n "$_cf" ] || continue
        SRC=$(dirname "$_cf")
        have_src || continue
        return 0
    done
    return 1
}

if ! have_src; then
    if [ "$_got" -gt 0 ]; then
        warnf "рядом лежит НЕПОЛНАЯ поставка, не хватает:%s" "$_miss"
        warn "  берётся целая с GitHub — то, что лежит рядом, использовано не будет"
    else
        say "поставки рядом нет — загрузка с GitHub"
    fi
    fetch_src ||
        dief "не удалось получить поставку — скачать архив с github.com/%s и запустить install.sh из него" "$REPO"
    sayf "поставка распакована: %s" "$SRC"
fi

for c in uci nft ip; do
    command -v "$c" >/dev/null 2>&1 ||
        { warnf "нет утилиты %s -- это не похоже на рабочий OpenWrt" "$c"; BAD=$((BAD + 1)); }
done

# Поколение файрвола. byway ставит СВОЮ таблицу nft, но правило для помеченного
# трафика добавляет в конфигурацию firewall4. На 21.02 и старше файрволом
# заведует firewall3, а он генерирует iptables: наша таблица, скорее всего,
# встанет, а правило по метке попадёт туда в другом виде -- и гостевые сети
# через туннель работать не будут. Наличие бинарника `nft` этого не ловит:
# на 21.02 его ставят пакетом, и проверка выше проходит.
#
# ОТКАЗЫВАЕМ, а не предупреждаем (решено 2026-09-06): BAD ниже разбирается
# в dief. Прежняя редакция этого комментария обещала предупреждение --
# устарела. Довод за отказ: человек получил бы туннель себе и не получил
# гостям, и пошёл бы искать поломку в своих настройках.
if ! command -v fw4 >/dev/null 2>&1; then
    warn "firewall4 не найден, а byway работает только на нём — это OpenWrt 22.03 и новее"
    warn "  на 21.02 и старше файрволом заведует firewall3 с iptables: другой механизм,"
    warn "  правило по метке туда не встанет, и туннель не получат ни гости, ни зоны"
    warn "  с политикой input REJECT. Половина работающего byway хуже честного отказа."
    warn "  своя версия: cat /etc/openwrt_release"
    BAD=$((BAD + 1))
    # Отдельная отметка, а не просто счётчик. Остальные недостачи установщик
    # берётся доставить сам, а эту -- нет: firewall4 не пакет, а поколение
    # системы. Значит дальше ставить нечего, и просить у человека ответы тоже
    # незачем. Прежде на 21.02 установщик доходил до вопроса про движок и
    # ТЯНУЛ xray-core из фида на роутер, где byway заведомо не заработает.
    # Поймано прогоном отказа в виртуалке, а не разбором.
    FATAL=1
fi

# ⚠️ Выходим ЗДЕСЬ, а не в конце. Прежде отметка ставилась, а установщик шёл
# дальше: доставлял пакеты, тянул модули ядра и раскладывал поставку по флешу
# -- и только потом объявлял отказ. На системе, где byway заведомо не
# заработает, оставался мусор. Найдено третьим аудитом 2026-09-07.
#
# Список недостач при этом полон: всё, что проверялось выше, уже сказано.
if [ "${FATAL:-0}" = 1 ]; then
    echo
    die "система не подходит -- ничего не установлено"
fi

# Модули для tproxy обязательны: без них выражение tproxy в nft не существует,
# и nft отвечает невнятным «No such file or directory» на имени таблицы.
# lsmod показывает только ЗАГРУЖАЕМЫЕ модули. Собранные в ядро он не
# показывает вовсе -- на таких прошивках установщик отказывался работать,
# хотя tproxy там как раз есть. /sys/module/<имя> существует в обоих случаях.
mod_ok() {
    lsmod 2>/dev/null | grep -q "^$1 " && return 0
    [ -d "/sys/module/$1" ] && return 0
    return 1
}

MISSING_MODS=""
for m in nft_tproxy nft_socket; do
    mod_ok "$m" || MISSING_MODS="$MISSING_MODS $m"
done
if [ -n "$MISSING_MODS" ]; then
    sayf "нет модулей ядра:%s -- установка" "$MISSING_MODS"
    # `|| true` обязателен: add_pkg отдаёт код пакетного менеджера, а голый
    # вызов под set -e завершает установщик прямо здесь -- ДО того, как
    # напечатается объяснение и текст лечения, написанные ровно на этот
    # случай. Результат всё равно проверяется следующей строкой, по делу, а
    # не по коду возврата.
    add_pkg kmod-nft-tproxy kmod-nft-socket || true
    # Пакет кладёт модуль, но в ядро он попадёт только при следующей загрузке.
    # Грузим сразу: иначе первая же попытка поднять обвязку упрётся в невнятное
    # «No such file or directory» на имени таблицы.
    for m in $MISSING_MODS; do modprobe "$m" >/dev/null 2>&1 || true; done
    MISSING_MODS=""
    for m in nft_tproxy nft_socket; do
        mod_ok "$m" || MISSING_MODS="$MISSING_MODS $m"
    done
    if [ -n "$MISSING_MODS" ]; then
        warnf "модули так и не встали:%s" "$MISSING_MODS"
        pkg_why
        warn "  без них перехват не работает; поставить вручную:"
        warn "  ${PKG:-apk} update && ${PKG:-apk} ${PKG_ADD:-add} kmod-nft-tproxy kmod-nft-socket"
        BAD=$((BAD + 1))
    fi
fi

# Имя файла в выпусках Xray под нашу архитектуру. Список из списка файлов
# самого выпуска, а не из головы: имена там свои, не как у uname.
# Плавающая точка на MIPS. Go собирает mips32le и mips64le с АППАРАТНОЙ
# плавающей точкой, и XTLS выкладывает только такую сборку -- softfloat в
# выпуске нет вовсе (сверено по списку файлов выпуска, а не по памяти).
# Между тем ходовые роутерные ядра -- 24Kc на ath79, 1004Kc на mt7621 --
# сопроцессора не имеют, и бинарник падает на первой же инструкции с
# «Illegal instruction». Из фида приезжает тот же Xray, собранный softfloat,
# и работает: проверено на стенде mipsel_24kc, где GitHub-сборка не пошла, а
# фидовая ответила `linux/mipsle` той же версии.
#
# Спрашиваем ДО скачивания. Проверка запуском после распаковки никуда не
# делась и остаётся вторым кольцом, но одна она заставляет роутер вытянуть
# 35 МБ по своему каналу и записать их на флеш, которого у MIPS-железок и
# так мало, -- чтобы тут же выбросить.
#
# Сомнение толкуем в пользу загрузки: нет /proc/cpuinfo или он пуст -- не
# отказываем, пусть решает проверка запуском.
mips_nofpu() {
    case "$(uname -m)" in mips*) ;; *) return 1 ;; esac
    # ⚠️ Содержимое, а не `[ -s ]`: файлы procfs отдают НУЛЕВОЙ размер, и
    # проверка на непустоту отключала саму себя -- на госте без сопроцессора
    # функция отвечала «качать можно». Поймано стендом, а не чтением.
    _ci=$(cat /proc/cpuinfo 2>/dev/null || true)
    [ -n "$_ci" ] || return 1
    # С сопроцессором ядро дописывает «FPU V…» в строку модели; без него
    # слова fpu в файле нет нигде.
    case "$_ci" in *[Ff][Pp][Uu]*) return 1 ;; esac
    return 0
}

xray_asset() {
    # Сначала DISTRIB_ARCH прошивки, и только потом uname. Причина: `uname -m`
    # на MIPS отдаёт одинаковое `mips` и для big-endian, и для little-endian,
    # то есть ветки mipsel и mips64el были недостижимы, а на самом ходовом
    # mt7621 (mipsel) качалась big-endian сборка. Она не запускалась, проверка
    # ниже это ловила -- и путь «взять с GitHub» на всём MIPS был мёртв.
    _da=""
    [ -f /etc/openwrt_release ] &&
        _da=$(sed -n "s/^DISTRIB_ARCH='\([^']*\)'.*/\1/p" /etc/openwrt_release | head -1)
    case "$_da" in
        aarch64*)          echo linux-arm64-v8a; return 0 ;;
        mipsel_*)          echo linux-mips32le;  return 0 ;;
        mips64el_*)        echo linux-mips64le;  return 0 ;;
        mips64_*)          echo linux-mips64;    return 0 ;;
        mips_*)            echo linux-mips32;    return 0 ;;
        x86_64*)           echo linux-64;        return 0 ;;
        i386*|i486*|i686*) echo linux-32;        return 0 ;;
        riscv64*)          echo linux-riscv64;   return 0 ;;
    esac
    # arm сюда доходит намеренно: в DISTRIB_ARCH он записан именем ядра
    # (arm_cortex-a7_neon-vfpv4), а v6 от v7 различает как раз uname.
    case "$(uname -m)" in
        aarch64)          echo linux-arm64-v8a ;;
        armv7l|armv7|arm) echo linux-arm32-v7a ;;
        armv6l)           echo linux-arm32-v6 ;;
        x86_64)           echo linux-64 ;;
        i386|i486|i686)   echo linux-32 ;;
        mips)             echo linux-mips32 ;;
        mipsel)           echo linux-mips32le ;;
        mips64)           echo linux-mips64 ;;
        mips64el)         echo linux-mips64le ;;
        riscv64)          echo linux-riscv64 ;;
        *) return 1 ;;
    esac
}

# Номер последнего выпуска у XTLS. Две ветки, и разница между ними -- та самая,
# на которой человек спотыкается:
#
#   stable -- `releases/latest` у GitHub, а он предвыпуски ПРОПУСКАЕТ. У XTLS
#             предвыпуском помечено всё, что новее 26.3.27, поэтому «latest»
#             отдаёт мартовский выпуск, хотя по-русски это слово значит
#             «самый свежий». Именно на этом слове владелец и споткнулся на
#             приёмке 2026-09-07: в меню оно означало ровно противоположное
#             тому, что читается. Слова latest в вопросах больше нет.
#   any    -- первый в списке всех выпусков, то есть действительно самый
#             свежий, включая предвыпуски.
xray_ver_top() {   # 1 -- stable | any
    if [ "$1" = stable ]; then
        _vu=https://api.github.com/repos/XTLS/Xray-core/releases/latest
    else
        _vu="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1"
    fi
    dl --max-time 25 "$(gh "$_vu")" |
        sed -n 's/.*"tag_name"[^"]*"v\([^"]*\)".*/\1/p' | head -1
}

# Движок с GitHub. Отдельно от фида, потому что в фиде версия та, что собрали
# вместе с прошивкой, а Xray меняется быстро: транспорты чинят и добавляют.
xray_from_github() {
    gh_ready
    if mips_nofpu; then
        warn "на этом процессоре сборка с GitHub не запустится: MIPS там только с аппаратной плавающей точкой, а сопроцессора здесь нет"
        warn "  из прошивки приезжает та же версия, собранная softfloat"
        return 1
    fi
    _as=$(xray_asset) || { warnf "не знаю, какой файл выпуска брать для %s" "$(uname -m)"; return 1; }

    # Место проверяем ДО скачивания. Бинарник около 35 МБ несжатого, и на
    # роутере с 43-мегабайтным флешем он либо влезает, либо нет -- узнать об
    # этом на середине распаковки значит получить переполненный раздел.
    # Каталог создаём ДО замера: df по несуществующему пути молчит и отдаёт
    # пустую строку, а пустая строка трактовалась как ноль -- и ветка «взять
    # с GitHub» не срабатывала НИ РАЗУ, всегда откатываясь в фид. Меряем
    # /overlay: /usr/local лежит именно там.
    mkdir -p /usr/local/bin
    _free=$(free_mb)
    # 25, а не 45: 35 МБ несжатого бинарника ubifs дожимает примерно вдвое.
    # Пустой ответ df -- это «не знаю», а не «ноль»: тогда качаем и проверяем
    # делом, а не отказываем заранее.
    if [ -n "$_free" ] && [ "$_free" -lt 25 ]; then
        warnf "на флеше %s МБ, движку нужно около 25 -- берётся из прошивки" "$_free"
        return 1
    fi

    command -v unzip >/dev/null 2>&1 || add_pkg unzip
    command -v unzip >/dev/null 2>&1 || { warn "нет unzip, распаковать нечем"; return 1; }

    # Номер версии к этому месту уже разрешён: слова сюда не доходят.
    case "$_ver" in
      ''|*[!0-9.]*) warnf "непонятный номер версии «%s»" "$_ver"; return 1 ;;
    esac

    # Архив -- в память, распаковка -- на флеш. Наоборот нельзя: сложенные
    # рядом архив и бинарник занимают весь раздел.
    # Имя с номером процесса, а не постоянное. /tmp общий: постоянное
    # `/tmp/xray.zip` мог заранее создать кто угодно с правами на запись, а
    # `unzip -o` от root распаковал бы ЕГО содержимое в /usr/local/bin. Проверки
    # суммы у нас нет и взяться ей неоткуда (GitHub её не публикует), поэтому
    # защита одна: непредсказуемое имя и удаление чужого файла перед записью.
    _z=/tmp/xray.$$.zip
    rm -f "$_z" 2>/dev/null || true
    sayf "установка Xray-core %s (%s)" "$_ver" "$_as"
    dl --max-time 300 -o "$_z" \
       "$(gh "https://github.com/XTLS/Xray-core/releases/download/v$_ver/Xray-$_as.zip")" ||
        { warn "не скачался"; rm -f "$_z"; return 1; }

    mkdir -p /usr/local/bin
    # Убираем и обломок: unzip мог успеть записать часть файла, а это
    # мегабайты на разделе в 43.7 МБ. Путь стал достижим именно теперь, когда
    # порог места опущен и ветка «взять с GitHub» наконец работает.
    unzip -o -j "$_z" xray -d /usr/local/bin >/dev/null 2>&1 ||
        { warn "не распаковался"; rm -f "$_z" /usr/local/bin/xray; return 1; }
    rm -f "$_z"
    mv /usr/local/bin/xray "/usr/local/bin/xray-$_ver" && chmod 755 "/usr/local/bin/xray-$_ver"

    # Проверяем, что оно вообще запускается на этом железе: неверно угаданная
    # архитектура даёт не ошибку скачивания, а «Exec format error» потом.
    if ! "/usr/local/bin/xray-$_ver" version >/dev/null 2>&1; then
        warn "скачанный движок не запускается на этом железе -- берётся из прошивки"
        rm -f "/usr/local/bin/xray-$_ver"
        return 1
    fi
    XRAY_PATH="/usr/local/bin/xray-$_ver"
    sayf "движок готов: %s" "$XRAY_PATH"
}

# ⚠️ Место проверяем ЗДЕСЬ, до движка, а не после него. Прежде проверка стояла
# в конце -- и мерила флеш сразу после записи тридцати пяти мегабайт, когда
# ubifs ещё не успел их дожать. На приёмке 2026-09-07 это дало отказ «меньше
# 2 МБ свободно» на разделе, где через минуту было свободно 21 МБ: byway не
# установился вовсе, а движок остался лежать. Худший исход -- отказ, оставивший
# мусор.
#
# Ещё и потому здесь, что сразу после записи число ВРЁТ: сжатие идёт лениво, и
# судить по нему нельзя в принципе.
FREE=$(free_mb)
[ "${FREE:-99}" -ge 2 ] || { warn "на флеше меньше 2 МБ свободно"; BAD=$((BAD + 1)); }

XRAY_PATH=""
if [ "${FATAL:-0}" = 1 ]; then
    # Движок не трогаем вовсе: система не годится, и ставить на неё
    # тридцатипятимегабайтный бинарник -- это мусор на чужом флеше.
    say "движок не ставится: система не подходит, см. выше"
# ⚠️ Настройку СПРАШИВАЕМ, а не угадываем. Прежде «движка нет» решалось тремя
# способами, и ни один не смотрел в byway.main.xray_bin -- хотя ниже путь
# записывается именно туда. `command -v` для самого частого случая бесполезен:
# /usr/local/bin не входит в PATH OpenWrt; шаблон xray-* не ловит файл с именем
# просто `xray`. Человек, указавший свой движок, получал предложение поставить
# ещё один. Найдено третьим аудитом 2026-09-07.
elif _xb=$(uci -q get byway.main.xray_bin 2>/dev/null); [ -n "$_xb" ] && [ -x "$_xb" ]; then
    sayf "движок уже указан в настройках: %s" "$_xb"
elif ! command -v xray >/dev/null 2>&1 && [ ! -x /usr/bin/xray ] &&
   ! ls /usr/local/bin/xray-* >/dev/null 2>&1; then
    echo
    # ⚠️ Спрашиваем про ВЕРСИЮ, а не про источник. Откуда её брать -- наша
    # забота: сперва GitHub, не вышло -- прошивка. Прежнее меню предлагало
    # выбрать «из фида или с GitHub», то есть требовало от человека знать
    # нашу кухню, а потом ещё и вписать номер версии руками словом. Владелец
    # на приёмке 2026-09-07: «будь я человеком, впервые читающий это, нихуя
    # бы не понял».
    if mips_nofpu; then
        # На этом процессоре варианты с GitHub невозможны в принципе -- не
        # предлагаем их вовсе, вместо того чтобы отказывать после выбора.
        say "Движок Xray-core. На этом процессоре сборки с GitHub не запускаются,"
        say "поэтому он берётся из прошивки:"
        line "     1) поставить из прошивки  -- по умолчанию"
        line "     2) никакой -- путь укажу сам потом"
        _c=$(askv "Выбор" 1)
        case "$_c" in
          2) warn "движок не ставится: указать путь после установки"
             warn "  uci set byway.main.xray_bin=/путь/к/xray && uci commit byway"
             _c=9 ;;
          *) _c=1 ;;
        esac
    else
        say "Движок Xray-core. Какую версию поставить:"
        linef "     1) проверенную с byway -- %s  (по умолчанию)" "$XRAY_TESTED"
        line "     2) самую свежую, включая предвыпуски"
        line "     3) самую свежую стабильную"
        line "     4) никакую -- путь укажу сам потом"
        line "     либо впишите номер версии, например 26.3.27"
        _c=$(askv "Выбор" 1)
        _ver=""
        case "$_c" in
          ''|1)  _ver=$XRAY_TESTED ;;
          2)     _ver=$(xray_ver_top any) ;;
          3)     _ver=$(xray_ver_top stable) ;;
          4)     warn "движок не ставится: указать путь после установки"
                 warn "  uci set byway.main.xray_bin=/путь/к/xray && uci commit byway"
                 _c=9 ;;
          # Номером -- чтобы не заставлять выбирать из списка того, кто уже
          # знает, что ему нужно.
          [0-9]*.[0-9]*) _ver=$_c ;;
          *)     warnf "ответ «%s» непонятен -- взята проверенная версия" "$_c"
                 _ver=$XRAY_TESTED ;;
        esac
        # Итог складываем в _c ЯВНО: 0 -- движок уже стоит, 1 -- ставить из
        # прошивки, 9 -- не ставить вовсе. Прежде здесь стоял разбор «всё, что
        # не 3, считаем единицей» -- и после удачной загрузки с GitHub он
        # ставил движок ВТОРОЙ раз, из фида. Найдено при этой же правке.
        #
        # ⚠️ Служебный код -- 9, и это не вкусовщина. Он был 3, то есть
        # СОВПАДАЛ с номером пункта меню «самую свежую стабильную»: ответ «3»
        # проходил в case, честно спрашивал у GitHub номер выпуска, а потом
        # оба блока установки пропускались этим самым условием. Роутер
        # оставался с полностью установленным byway БЕЗ движка, служба не
        # стартовала, а установщик отчитывался успехом -- предупреждение
        # печатал только пункт 4. Хуже отказа: отказ виден. Найдено четвёртым
        # аудитом, заход 3.
        if [ "$_c" != 9 ]; then
            if [ -z "$_ver" ]; then
                warn "не удалось спросить у GitHub номер версии -- берётся из прошивки"
                _c=1
            elif sayf "версия: %s" "$_ver"; xray_from_github; then
                _c=0
            else
                _c=1
            fi
        fi
    fi
    if [ "$_c" = 1 ]; then
        say "установка xray-core из прошивки"
        add_pkg xray-core || true   # см. про set -e у вызова для модулей
        command -v xray >/dev/null 2>&1 || [ -x /usr/bin/xray ] || {
            warn "Xray-core не поставился из прошивки"
            # Сперва самая частая причина, и она не в сети. Движок -- это
            # около тридцати мегабайт распакованными, а на дешёвых роутерах
            # раздел под изменения бывает и меньше четырёх: у 8 МБ флеша
            # overlay доходит до 768 КБ, у 16 МБ -- 3,5-8 МБ. Тогда не
            # поставится НИ ОДИН движок, и советовать «повторите команду
            # руками» -- значит отправить человека по кругу.
            #
            # Проверяем ПОСЛЕ неудачи, а не до: файловые системы роутеров
            # жмут, и предсказать занятое место по размеру пакета нельзя.
            # Судим по факту отказа плюс по остатку.
            _fe=$(free_mb)
            if [ -n "$_fe" ] && [ "$_fe" -lt 15 ]; then
                warnf "на разделе изменений %s МБ, а движку нужно около 30 -- сюда он не встанет" "$_fe"
                warn "  это не поправить настройкой: нужен роутер с большим флешем либо extroot на USB"
            else
                pkg_why
                warn "  ${PKG:-apk} update && ${PKG:-apk} ${PKG_ADD:-add} xray-core -- либо положить бинарник вручную"
                warn "  и указать путь: uci set byway.main.xray_bin=/путь/к/xray"
            fi
            BAD=$((BAD + 1))
        }
    fi
fi

# base64 нужен ТОЛЬКО для ключей vmess и ss: у vless, trojan и socks всё
# лежит в ссылке открытым текстом. Поэтому спрашиваем, а не ставим молча --
# на роутере с сорока мегабайтами флеша лишний пакет это не мелочь.
# ⚠️ Судим ЗАПУСКОМ, а не наличием. `command -v base64` на этом роутере
# отвечает `/bin/base64` -- но это ссылка на busybox, у которого апплета
# base64 нет вовсе: `echo -n x | base64` даёт «applet not found». Проверка по
# наличию файла молча пропускала вопрос про coreutils-base64, и человек с
# ключом vmess:// или ss:// упирался в отказ уже в работе, без единой
# подсказки при установке. Поймано приёмкой владельца 2026-09-07.
have_base64() { printf x | base64 >/dev/null 2>&1; }

if ! have_base64; then
    # Умолчание -- НЕТ: base64 нужен только ключам vmess:// и ss://, а
    # подавляющее большинство ключей сегодня vless://. Ставить пакет на флеш
    # «на всякий случай» -- не то, что делают по умолчанию на роутере с
    # сорока мегабайтами. Просьба владельца на приёмке 2026-09-07.
    if ask "Поставить base64? Нужен только для ключей vmess:// и ss://" n; then
        add_pkg coreutils-base64 || true   # см. про set -e у вызова для модулей
        have_base64 ||
            { warn "не поставился: ключи vmess и ss разобрать не выйдет"; pkg_why; }
    else
        say "base64 не ставится -- ключи vless, trojan и socks работают без него"
    fi
fi

if [ "$BAD" -gt 0 ]; then
    echo
    # Почти всё выше не ставится по одной причине -- нет интернета. Отдельными
    # строками про curl, модули и base64 это выглядит как три беды, и человек
    # чинит их поочерёдно. Проверено на стенде: гость с опущенным wan получал
    # ровно такой отказ. Диагноз ставится ТОЛЬКО на пути отказа, лишней
    # задержки в обычной установке от него нет.
    #
    # Порядок проверок -- от ближнего к дальнему, и он важен: без маршрута DNS
    # тоже не отвечает, и первая же редакция этого блока послала человека
    # чинить dnsmasq, когда лежал wan. Маршрут вдобавок виден локально, без
    # единого пакета и без ожидания.
    if [ "$PKG_UPDATED" = 1 ]; then
        if ! ip route 2>/dev/null | grep -q "^default"; then
            warn "и главное: у роутера нет маршрута наружу — почти всё выше поэтому"
            warn "  проверить: ifstatus wan, ip route, ip link"
        elif ! nslookup downloads.openwrt.org >/dev/null 2>&1; then
            warn "и главное: DNS не отвечает — почти всё выше поэтому"
            warn "  проверить: cat /etc/resolv.conf, /etc/init.d/dnsmasq restart"
        elif ! wget -q -T5 -O /dev/null http://downloads.openwrt.org/ 2>/dev/null; then
            warn "и главное: наружу не пускает — почти всё выше поэтому"
            warn "  проверить: firewall, ping 1.1.1.1, traceroute"
        fi
    fi
    dief "не хватает %s условий — доставить перечисленное и запустить снова" "$BAD"
fi
say "всё на месте"

echo
say "── Установка ──"

mkdir -p /usr/local/bin /etc/byway /etc/byway/presets /etc/byway/lang /etc/byway/routes
# Кладём через временное имя и mv, а не cp поверх. Разница видна при
# обновлении: `byway update` запускает этот установщик из САМОГО себя, cp
# пишет в тот же inode, который читает работающая оболочка, и она дочитывает
# хвост уже новой версии со старого смещения. Проверено стендом на sh, dash и
# bash -- все три исполнили обрывок чужого файла. mv даёт новый inode, старый
# живёт до конца процесса.
put() {  # $1 откуда, $2 куда, $3 права
    cp "$1" "$2.new" && chmod "$3" "$2.new" && mv "$2.new" "$2" && return 0
    # Отказ должен быть громким. Прежняя форма (cp && chmod прямо в теле
    # скрипта) под set -e прощалась и установка ехала дальше, спотыкаясь
    # позже о «byway: not found»; новая уронила бы скрипт молча, без единого
    # слова. Ни то ни другое не годится: говорим, что не легло и почему
    # смотреть.
    rm -f "$2.new" 2>/dev/null || true
    dief "не удалось положить %s — проверить место на флеше и права" "$2"
}
put "$SRC/byway" /usr/local/bin/byway 755
put "$SRC/etc-init.d-byway" /etc/init.d/byway 755
# ⚠️ Удаление кладём РЯДОМ. Прежде оно не попадало на роутер вовсе: README
# давал три команды `sh uninstall.sh`, а файла с таким именем после установки
# одной строкой не существовало -- поставка живёт во временном каталоге и
# исчезает при первой перезагрузке. Найдено третьим аудитом 2026-09-07.
[ -f "$SRC/uninstall.sh" ] && put "$SRC/uninstall.sh" /usr/local/bin/byway-uninstall 755
# Сумма выложенного файла. По ней автообновление отличает свою версию от
# правленой руками и во второй случай не лезет: перетереть чужую правку
# молча -- худшее, что может сделать программа, обновляющаяся сама.
mkdir -p /etc/byway
md5sum /usr/local/bin/byway 2>/dev/null | cut -d' ' -f1 > /etc/byway/.binmd5 || true

# ⚠️ Регистрация в АВТОЗАПУСКЕ. Прежде её не делал никто: install.sh только
# клал файл службы, панель поднимала службу «сейчас» и rc.d-ссылку не
# создавала, а `/etc/init.d/byway enable` жил ТОЛЬКО в тексте памятки
# «Дальше» -- то есть числился шагом человека. README при этом обещал, что в
# консоль лезть не обязательно ни разу. После первой же перезагрузки роутер
# оставался без туннеля, и doctor об этом молчал. Найдено третьим аудитом
# 2026-09-07; в keep-списке прошивки ссылка S90byway значилась всё это время,
# то есть автозапуск был задуман и просто не включался.
#
# Безопасно делать до настройки: при `enabled=0` служба ничего не поднимает.
/etc/init.d/byway enable >/dev/null 2>&1 || true
if /etc/init.d/byway enabled 2>/dev/null; then
    say "программа и служба, автозапуск включён"
else
    say "программа и служба"
    warn "служба не встала в автозапуск -- после перезагрузки туннеля не будет; поправить: /etc/init.d/byway enable"
fi

# Конфигурацию не перетираем: в ней ключ и настройки человека.
if [ -f /etc/config/byway ]; then
    say "конфигурация уже есть, остаётся без изменений"
else
    cp "$SRC/etc-config-byway" /etc/config/byway && chmod 600 /etc/config/byway
    # 600, а не 644: сюда попадёт ключ от VPN. uci и панель работают от
    # root, так что доступ не теряется ни у кого, кому он нужен.
    say "конфигурация создана из шаблона"
fi

# Выбранный язык -- в конфигурацию: иначе установщик говорил бы по-английски,
# а всё, что человек откроет следом, -- по-русски.
if [ "$LANG_EN" = 1 ]; then _wl=en; else _wl=ru; fi
if [ "$(uci -q get byway.main.lang)" != "$_wl" ]; then
    uci set byway.main.lang="$_wl" && uci commit byway
fi

# Путь к движку -- в настройки. Раньше XRAY_PATH присваивался и не читался
# никем: скачанный с GitHub бинарник лежит под своей версией
# (/usr/local/bin/xray-26.7.28), а служба искала /usr/bin/xray и не
# стартовала -- то есть весь путь «взять движок с GitHub» кончался
# неработающим byway. Ищем и уже стоявший движок: при установке поверх
# скачивания не будет, а путь всё равно нужен.
if [ -z "$(uci -q get byway.main.xray_bin)" ]; then
    if [ -z "$XRAY_PATH" ]; then
        if command -v xray >/dev/null 2>&1; then
            XRAY_PATH=$(command -v xray)
        elif [ -x /usr/bin/xray ]; then
            XRAY_PATH=/usr/bin/xray
        else
            # По времени, а не по алфавиту: лексически xray-26.7.9 старше
            # xray-26.7.11, и выбралась бы прошлая версия.
            XRAY_PATH=$(ls -1t /usr/local/bin/xray-* 2>/dev/null | head -1)
        fi
    fi
    if [ -n "$XRAY_PATH" ] && [ -x "$XRAY_PATH" ]; then
        uci set byway.main.xray_bin="$XRAY_PATH" && uci commit byway
        sayf "движок записан в настройки: %s" "$XRAY_PATH"
    else
        # Движка нет НИ ОДНОГО, и молчать об этом нельзя: byway при этом
        # установлен целиком, а служба не стартует. Без этой ветки установка
        # объявлялась удавшейся -- и человек шёл искать поломку в панели.
        warn "движок не найден: byway установлен, но служба не поднимется"
        warn "  указать путь: uci set byway.main.xray_bin=/путь/к/xray && uci commit byway"
        BAD=$((BAD + 1))
    fi
fi

# Списки тоже: пустые создаём, существующие не трогаем.
for l in domains subnets; do
    [ -f "/etc/byway/$l.lst" ] || : > "/etc/byway/$l.lst"
done
say "списки на месте"

# Словари перевода кладём всегда: они маленькие, а без них переключение
# языка молча не сработает -- byway просто продолжит говорить по-русски.
if [ -d "$SRC/lang" ]; then
    for l in "$SRC"/lang/*.tsv; do
        [ -f "$l" ] && cp "$l" /etc/byway/lang/ && chmod 644 "/etc/byway/lang/$(basename "$l")"
    done
    # xargs, а не tr: перевод строки в конце вывода ls превращался в пробел,
    # и строка печаталась как «словари перевода: en.tsv » -- с висящим
    # пробелом перед концом. Мелочь, но её видит каждый, кто ставит.
    _dl2=$(ls /etc/byway/lang/ 2>/dev/null | xargs echo)
    sayf "словари перевода: %s" "$_dl2"
fi

if [ -d "$SRC/luci" ]; then
    mkdir -p /www/luci-static/resources/view/byway /www/luci-static/resources/byway
    # Общие модули панели: словарь и внешний вид. Их подключают все вкладки
    # через 'require byway.<имя>', и путь тут не про вкус, а про то, где LuCI
    # ищет модули.
    for _m in lang ui; do
        [ -f "$SRC/luci/$_m.js" ] &&
            cp "$SRC/luci/$_m.js" "/www/luci-static/resources/byway/$_m.js" &&
            chmod 644 "/www/luci-static/resources/byway/$_m.js"
    done
    for v in overview settings lists maint advanced; do
        [ -f "$SRC/luci/$v.js" ] &&
            cp "$SRC/luci/$v.js" "/www/luci-static/resources/view/byway/$v.js" && chmod 644 "/www/luci-static/resources/view/byway/$v.js"
    done
    # Знак: плоское начертание идёт значком вкладки (шестнадцать пикселей --
    # грани там превращаются в грязь), обычное лежит рядом на будущее.
    for _g in logo-flat.svg logo.svg; do
        [ -f "$SRC/$_g" ] &&
            cp "$SRC/$_g" "/www/luci-static/resources/byway/$_g" &&
            chmod 644 "/www/luci-static/resources/byway/$_g"
    done
    [ -f "$SRC/luci/menu.json" ] &&
        cp "$SRC/luci/menu.json" /usr/share/luci/menu.d/luci-app-byway.json && chmod 644 /usr/share/luci/menu.d/luci-app-byway.json
    [ -f "$SRC/luci/acl.json" ] &&
        cp "$SRC/luci/acl.json" /usr/share/rpcd/acl.d/luci-app-byway.json && chmod 644 /usr/share/rpcd/acl.d/luci-app-byway.json
    # Кэш меню LuCI надо сбросить, иначе раздел не появится до перезагрузки.
    for c in /tmp/luci-indexcache*; do [ -e "$c" ] && : > "$c"; done
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
    say "панель LuCI: Сервисы → Byway"
else
    warn "каталога luci рядом нет — панель не установлена"
fi

# Пути в keep-список прошивки: без этого sysupgrade снесёт byway, а правку
# dnsmasq в /etc/config оставит. Дом остался бы без DNS.
# Перечислены ФАЙЛЫ, а не каталог /usr/local/bin целиком: там же обычно лежит
# бинарник Xray на 34 МБ, а sysupgrade пакует сохраняемое в память -- каталогом
# целиком мы бы клали роутер на ровном месте.
for P in /etc/byway/ /etc/init.d/byway /etc/rc.d/S90byway /etc/rc.d/K10byway \
         /usr/local/bin/byway /usr/local/bin/byway-uninstall          /usr/bin/byway /usr/bin/byway-uninstall; do
    grep -qxF "$P" /etc/sysupgrade.conf 2>/dev/null || echo "$P" >> /etc/sysupgrade.conf
done
say "пути внесены в keep-список прошивки"

# /usr/local/bin в PATH OpenWrt НЕ входит: /etc/profile задаёт его жёстко
# строкой /usr/sbin:/usr/bin:/sbin:/bin. Без этого последнее, что видит
# человек после установки, -- три команды, ни одна из которых не запустится.
# Симлинк надёжнее правки профиля: он работает и в `ssh router 'byway ...'`,
# где профиль не читается вовсе.
# Ссылка и для удаления: /usr/local/bin в PATH у OpenWrt НЕ входит, и файл,
# положенный туда, по имени не зовётся -- ровно это и вышло на первом же
# прогоне после того, как удаление стали класть на роутер.
[ -e /usr/bin/byway-uninstall ] || [ ! -x /usr/local/bin/byway-uninstall ] ||
    ln -s /usr/local/bin/byway-uninstall /usr/bin/byway-uninstall 2>/dev/null || true
if [ ! -e /usr/bin/byway ]; then
    ln -s /usr/local/bin/byway /usr/bin/byway 2>/dev/null &&
        say "byway доступен по имени из любой оболочки"
fi

# Сбор состояния: пишет только при изменении, поэтому во флеш почти ничего
# не уходит, а перезапуск службы остаётся записанным.
if ! crontab -l 2>/dev/null | grep -q "byway watch"; then
# `|| true` здесь ОБЯЗАТЕЛЕН, и вот почему: под set -e подоболочка
# умирает на первой же неудачной команде, а `crontab -l` на роутере без
# crontab возвращает единицу. Без него echo не выполнялся вовсе, в
# `crontab -` уходила пустота -- и задача не заводилась НИКОГДА, при том
# что установщик докладывал об успехе. Поймано стендом на чистой машине.
    (crontab -l 2>/dev/null || true; echo "*/5 * * * * /usr/local/bin/byway watch >/dev/null 2>&1") | crontab -
    NEED_CRON=1
fi
# Учёт использования собирался НИКЕМ: задачи для stat не было ни здесь, ни в
# службе, при том что панель показывает экран «чем пользуются» и галочку для
# него. Возможность была мертва целиком.
#
# Раз в час, а не раз в двадцать минут: каждый прогон с новыми соединениями
# переписывает итог во флеше, а флеша здесь 43.7 МБ ubi. Минута смещена от
# нуля, чтобы не сойтись с чужими часовыми задачами.
if ! crontab -l 2>/dev/null | grep -q "byway stat"; then
    (crontab -l 2>/dev/null || true; echo "7 * * * * /usr/local/bin/byway stat >/dev/null 2>&1") | crontab -
    NEED_CRON=1
fi
if [ "${NEED_CRON:-0}" = "1" ]; then
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    # Отчитываемся по ФАКТУ, а не по намерению. Прежняя строка сообщала об
    # обеих задачах безусловно -- и сообщала бы даже тогда, когда в crontab
    # не легло ничего. Ровно так пропажа `byway watch` и пряталась.
    _cw=0; _cs=0
    crontab -l 2>/dev/null | grep -q "byway watch" && _cw=1
    crontab -l 2>/dev/null | grep -q "byway stat"  && _cs=1
    if [ "$_cw$_cs" = "11" ]; then
        say "задачи в cron: журнал состояния и учёт использования"
    else
        warn "в cron легло НЕ ВСЁ — проверить: crontab -l"
        [ "$_cw" = 1 ] || warn "  нет задачи byway watch: не будет ни проверки версии, ни обновления списков"
        [ "$_cs" = 1 ] || warn "  нет задачи byway stat: учёт использования собираться не будет"
    fi
fi

# Правило для зон с политикой input REJECT -- гостевой и подобных. tproxy не
# переписывает адрес назначения, пакет приходит в input с исходным 198.18.x.x
# и упирается в политику зоны. Без этого правила выбор гостевой сети в
# настройках просто не работает, а uninstall его при этом удаляет как своё.
if [ -z "$(uci -q get firewall.bywaytproxy 2>/dev/null)" ]; then
    uci -q set firewall.bywaytproxy=rule
    uci -q set firewall.bywaytproxy.name='byway-tproxy'
    uci -q set firewall.bywaytproxy.src='*'
    uci -q set firewall.bywaytproxy.proto='all'
    # И значение, и маска -- из настройки. Прежде маска стояла литералом,
    # и при своей метке правило выходило вида 0x200000/0x100000: маска не от
    # той метки, совпадение случайное.
    _fwm=$(uci -q get byway.main.mark || echo 0x100000)
    uci -q set firewall.bywaytproxy.mark="$_fwm/$_fwm"
    uci -q set firewall.bywaytproxy.target='ACCEPT'
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    say "правило firewall для помеченного трафика создано"
fi

echo
say "── Готово ──"
/usr/local/bin/byway version
echo

# Обновление и первая установка кончаются по-разному. При обновлении на диске
# уже новая программа, а движок работает по конфигу, собранному прежней:
# перезапуск обязателен, иначе правки не действуют до следующей перезагрузки,
# и человек считает, что обновление ничего не изменило.
# Обновлением считаем только тот случай, когда byway стоял И настроен. Иначе
# памятку «Дальше» получал бы и человек, у которого повторный запуск -- это
# первая удачная установка после неудачной: программа лежала, ключа не было,
# и три шага ему нужнее всего.
if [ "$WAS_INSTALLED" = 1 ] && [ -n "$(uci -q get byway.main.node_url 2>/dev/null)" ]; then
    # Конфиг движка собран ПРЕЖНЕЙ версией программы. Один перезапуск поднял
    # бы движок на нём же: новая программа на диске, работает старая сборка,
    # и человек считает, что обновление ничего не изменило.
    /usr/local/bin/byway gen || warn "конфиг не пересобрался — движок остаётся на прежнем"
    if [ "$(uci -q get byway.main.enabled)" = "1" ]; then
        # Предупреждаем ДО, а не отчитываемся после: на единственном шлюзе
        # дома перезапуск -- это несколько секунд без туннеля у всех.
        warn "перезапуск службы — туннель прервётся на несколько секунд"
        # Вывод НЕ в /dev/null: если служба не встала, единственное объяснение
        # почему -- как раз в нём.
        # Судим ДЕЛОМ. Код возврата у restart ненулевым быть не может:
        # rc.common при USE_PROCD=1 берёт его у service_started, а та
        # возвращает 0 на всех ветках. Ветка else не выполнялась никогда.
        /etc/init.d/byway restart || true
        _rok=0
        for _rw in 1 2 3 4 5 6 7 8 9 10 11 12; do
            if pgrep -f '/etc/byway/config.json' >/dev/null 2>&1; then _rok=1; break; fi
            sleep 1
        done
        if [ "$_rok" = 1 ]; then
            say "служба перезапущена на новой версии"
        else
            warn "движок не поднялся — смотреть: logread -e byway"
        fi
    fi
    say "Обновлено. Если открыта панель — обновить страницу с очисткой кэша (Ctrl+F5)."
elif [ "$LANG_EN" = 1 ]; then
# Метка в кавычках -- ОБЯЗАТЕЛЬНО. Без них оболочка разбирает тело как
# обычную строку: обратные кавычки внутри становятся подстановкой команды,
# и `byway presets` в тексте памятки не показывался, а ВЫПОЛНЯЛСЯ -- вывод
# вклинивался в середину фразы, а установщик лез в сеть за списками, хотя
# сам же тремя строками выше объясняет, что качать их можно только после
# поднятого туннеля. Поймано на стенде, воспроизводилось каждый раз.
# Переменных внутри нет, так что кавычки ничего не ломают.
_H() { printf '\033[1;36m%s\033[0m\n' "$1"; }
_C() { printf '       \033[0;33m%s\033[0m\n' "$1"; }

printf '\n\033[1;32m%s\033[0m\n' "Next:"
_H "  1  The VPN key — web UI, Services → Byway → Overview, or by command:"
_C "uci set byway.main.node_url='vless://…'"
_C "uci set byway.main.enabled=1"
_C "uci commit byway"
_H "  2  Start it now — at every later boot it starts on its own:"
_C "/etc/init.d/byway start"
_H "  3  Lists — AFTER the tunnel is up:"
_C "uci add_list byway.main.preset=byway"
_C "uci commit byway && byway presets"
_C "/etc/init.d/byway reload"
printf '     %s\n' "ready-made lists are fetched THROUGH the tunnel, and reload moves them into the config"
printf '\n  %s   %s\n' "Check the environment: byway doctor" "State: byway"
else
# Метка в кавычках -- ОБЯЗАТЕЛЬНО. Без них оболочка разбирает тело как
# обычную строку: обратные кавычки внутри становятся подстановкой команды,
# и `byway presets` в тексте памятки не показывался, а ВЫПОЛНЯЛСЯ -- вывод
# вклинивался в середину фразы, а установщик лез в сеть за списками, хотя
# сам же тремя строками выше объясняет, что качать их можно только после
# поднятого туннеля. Поймано на стенде, воспроизводилось каждый раз.
# Переменных внутри нет, так что кавычки ничего не ломают.
# Печатаем printf-строками, а НЕ heredoc. Метка без кавычек разбирала бы тело
# как обычную строку -- обратные кавычки внутри стали бы подстановкой команды,
# и `byway presets` в тексте не показывался, а ВЫПОЛНЯЛСЯ. С кавычками тело
# не подставляет ничего, но тогда в него не вписать и цвет. printf снимает
# обе беды разом: подстановки нет, а escape-последовательности он понимает.
#
# Пустых строк между шагами нет намеренно: с ними памятка расплывалась на
# полтора экрана и читалась как текст, а не как список действий.
_H() { printf '\033[1;36m%s\033[0m\n' "$1"; }        # заголовок шага
_C() { printf '       \033[0;33m%s\033[0m\n' "$1"; } # команда

printf '\n\033[1;32m%s\033[0m\n' "Дальше:"
_H "  1  Ключ VPN — в панели «Сервисы → Byway → Основное», либо командой:"
_C "uci set byway.main.node_url='vless://…'"
_C "uci set byway.main.enabled=1"
_C "uci commit byway"
_H "  2  Запустить сейчас — при загрузке роутера дальше сам:"
_C "/etc/init.d/byway start"
_H "  3  Списки — ПОСЛЕ того, как туннель поднялся:"
_C "uci add_list byway.main.preset=byway"
_C "uci commit byway && byway presets"
_C "/etc/init.d/byway reload"
printf '     %s\n' "готовые списки качаются через туннель, а reload переносит их в конфиг"
printf '\n  %s   %s\n' "Проверить окружение: byway doctor" "Состояние: byway"
fi
