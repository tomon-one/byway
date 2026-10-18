# Перенос настроек: export, import, clear. Тело выгрузки, разбор и приём
# выгрузки, очистка -- в ucode (uc/transfer.uc). Здесь проверка пути, запись
# файла, сборка конфига, перезапуск и откат. Ключ в выгрузке -- только с
# --with-key; import кладёт прежнее в before-import.

tf_uc() {
    BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_CONF=$CONF BW_ACCESS=$ACCESS bw_uc "$@"
}

cmd_clear() {
    tf_uc clear "${1:-}"
}

# Куда можно писать выгрузку и откуда читать. Панель вправе запускать только
# команды, перечисленные в acl.json (точные строки, без `export *`); эта
# проверка -- для консоли: без неё `byway export /etc/passwd` перезапишет
# системный файл от root. Системные каталоги
# закрыты, кроме своего /etc/byway; остальное открыто -- консоли не мешаем.
path_ok() {
    case "$1" in *..*) return 1 ;; esac
    # Судим по РАЗРЕШЁННОМУ пути, не по написанному: корень -- overlayfs,
    # /overlay/upper/etc/... -- тот же файл, что /etc/..., а симлинк из
    # разрешённого каталога (/tmp/x -> /etc) уводит туда же. readlink -f
    # разбирает и новый файл при существующем каталоге; не разобрал -- по
    # написанному.
    _pp=$(readlink -f "$1" 2>/dev/null) || _pp=""
    [ -n "$_pp" ] || _pp=$1
    case "$_pp" in
        # Свой каталог открыт для выгрузок, но не для СВОИХ рабочих файлов:
        # запись поверх config.json, byway.prev (откат автообновления) или
        # списков читается потом как своё и выглядит как порча данных.
        /etc/byway/config.json|/etc/byway/byway.prev|/etc/byway/prev.tgz|/etc/byway/.binmd5|\
        /etc/byway/dns-saved|/etc/byway/domains.lst|/etc/byway/subnets.lst|\
        /etc/byway/usage.tsv|/etc/byway/health.log|/etc/byway/presets/*|\
        /etc/byway/routes/*|/etc/byway/lang/*) return 1 ;;
        /etc/byway/*) return 0 ;;
        # Исключение: панель кладёт принимаемую выгрузку сюда (maint.js,
        # IMPORT_TMP), запрет ниже отверг бы её и приём из панели не
        # работал бы. Файл черновой, данных byway в нём нет.
        /tmp/byway-import.txt) return 0 ;;
        # Рабочие файлы в памяти -- тоже свои: выгрузка поверх черновика
        # конфига или журнала обращений ломает byway.
        /tmp/byway-*) return 1 ;;
        # /www -- корень uhttpd: файл отдаётся по http без авторизации, chmod
        # 600 не спасает (читает тот же root). /overlay и /rom -- системные
        # файлы под другими именами.
        /etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/proc/*|/sys/*|/dev/*|\
        /www/*|/overlay/*|/rom/*) return 1 ;;
        *) return 0 ;;
    esac
}

cmd_export() {
    # Без ключа ПО УМОЛЧАНИЮ (с 0.3.0): выгрузку чаще пересылают, чем
    # восстанавливают, а ключ в ней -- доступ к VPN. --no-key принят для
    # старых команд.
    _nokey=1; _dest=""
    for _a in "$@"; do
        case "$_a" in
            --no-key)   _nokey=1 ;;
            --with-key) _nokey=0 ;;
            -*)       die "byway export [файл] [--with-key]" ;;
            *)        _dest="$_a" ;;
        esac
    done

    if [ -z "$_dest" ]; then
        tf_uc export "$_nokey"
        return 0
    fi
    path_ok "$_dest" || die "сюда писать нельзя: системные каталоги закрыты"
    # Под umask 077 во временный файл и mv -- как в cmd_report.
    ( umask 077; tf_uc export "$_nokey" > "$_dest.new.$$" )
    mv "$_dest.new.$$" "$_dest"
    sayf "выгружено: %s (%s байт)" "$_dest" "$(wc -c < "$_dest")"
    if [ "$_nokey" = 1 ]; then
        say "ключ не записан — файл можно показывать кому угодно"
    else
        warn "в файле лежит ключ от VPN — никуда не выкладывать"
    fi
}

cmd_import() {
    _nokey=0; _src=""
    for _a in "$@"; do
        case "$_a" in
            --no-key) _nokey=1 ;;
            -*)       die "byway import ФАЙЛ [--no-key]" ;;
            *)        _src="$_a" ;;
        esac
    done
    [ -n "$_src" ] || die "byway import ФАЙЛ [--no-key] — файл от byway export"
    path_ok "$_src" || die "отсюда читать нельзя: системные каталоги закрыты"
    [ -r "$_src" ] || dief "не читается: %s" "$_src"
    # Файл панели (/tmp/byway-import.txt) после приёма не нужен: в нём ключ.
    # Копию конфига в before-import ловушка НЕ трогает: она -- ради отката
    # после удачного приёма, меню и панель на неё ссылаются.
    trap 'case "$_src" in /tmp/byway-import.txt) rm -f "$_src" ;; esac' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Разбор и приём: правки UCI -- без commit, списки -- на место.
    tf_uc import "$_src" "$_nokey" || exit $?
    _bak=$LISTS/before-import

    # Проверка сборкой: cmd_gen пишет во временный файл и переносит его после
    # проверки движком, боевой конфиг не портится. Подоболочка нужна: cmd_gen
    # на неудаче делает exit, без неё откат ниже не выполнился бы.
    if (cmd_gen); then
        uci commit byway
        # Перезапуск -- сами: reload по `uci commit byway` сравнивает собранный
        # конфиг с прежним, а он уже собран нами и совпадает -- движок остался
        # бы на старых настройках.
        if [ "$(u enabled)" = "1" ]; then
            warn "перезапуск службы — туннель прервётся на несколько секунд"
            # Судим ДЕЛОМ, не кодом возврата: rc.common при USE_PROCD=1 берёт
            # код у service_started, а он 0 на всех ветках, включая «движок
            # не поднялся».
            /etc/init.d/byway restart >/dev/null 2>&1 || true
            _iw=0
            while [ "$_iw" -lt 12 ] && [ -z "$(xray_pid)" ]; do
                _iw=$((_iw + 1)); sleep 1
            done
            if [ -n "$(xray_pid)" ]; then
                say "применено, служба перезапущена"
            else
                warn "применено, но движок не поднялся — смотреть: logread -e byway"
            fi
        else
            say "применено. byway выключен настройкой -- включить: uci set byway.main.enabled=1 && uci commit byway && /etc/init.d/byway restart"
        fi
    else
        warn "конфиг не собрался — прежние настройки возвращаются на место"
        uci -q revert byway || true
        cp "$_bak/domains.lst" "$LISTS/domains.lst" 2>/dev/null || true
        cp "$_bak/subnets.lst" "$LISTS/subnets.lst" 2>/dev/null || true
        # Секции направлений вернёт uci revert, списки -- копии рядом: файлы
        # revert не знает.
        if [ -d "$_bak/routes" ]; then
            for _rb in "$_bak/routes"/*.lst; do
                [ -f "$_rb" ] || continue
                cp "$_rb" "$ROUTES_DIR/$(basename "$_rb")" 2>/dev/null || true
            done
        fi
        die "настройки из файла не приняты, прежние на месте"
    fi
}
