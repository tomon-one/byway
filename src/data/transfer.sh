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
        /etc/byway/routes/*|/etc/byway/lang/*|\
        /etc/byway/before-import|/etc/byway/before-import/*|/etc/byway/.*) return 1 ;;
        # before-import -- копия для отката приёма, .* -- служебные метки
        # обновления: запись поверх них ломала откат (Ф9, п4-7, прогон 5).
        /etc/byway/*) return 0 ;;
        # Исключение: панель кладёт принимаемую выгрузку сюда (maint.js,
        # IMPORT_TMP), запрет ниже отверг бы её и приём из панели не
        # работал бы. Файл черновой, данных byway в нём нет.
        # /var/run -- ссылка на /tmp/run: readlink -f даёт второй путь.
        /var/run/byway-import.txt|/tmp/run/byway-import.txt) return 0 ;;
        # Рабочие файлы в памяти -- тоже свои: выгрузка поверх черновика
        # конфига или журнала обращений ломает byway. Они живут в /var/run
        # (/tmp/run): прежде закрыт был только /tmp/byway-* (Ф9, п4-7).
        /tmp/byway-*|/tmp/run/byway*|/var/run/byway*) return 1 ;;
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
    # Каталог файлом не считается: `export /tmp` отвечал «выгружено: /tmp
    # (0 байт)», а файл ложился в /tmp/tmp.new.PID (Ф9, п3-20).
    [ -d "$_dest" ] && dief "это каталог, нужен файл: %s" "$_dest"
    path_ok "$_dest" || die "сюда писать нельзя: системные каталоги закрыты"
    # Под umask 077 во временный файл и mv -- как в cmd_report.
    ( umask 077; tf_uc export "$_nokey" > "$_dest.new.$$" )
    mv "$_dest.new.$$" "$_dest" || { rm -f "$_dest.new.$$"; dief "не записан: %s" "$_dest"; }
    sayf "выгружено: %s (%s байт)" "$_dest" "$(wc -c < "$_dest")"
    if [ "$_nokey" = 1 ]; then
        say "ключ не записан — файл можно показывать кому угодно"
    else
        warn "в файле лежит ключ от VPN — никуда не выкладывать"
    fi
}

tf_back() {
    [ -f "$1" ] || return 0
    if cp "$1" "$2.new" 2>/dev/null; then mv -f "$2.new" "$2"
    else rm -f "$2.new"; warnf "не вернулся на место: %s" "$2"; fi
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
    # Файл панели (/var/run/byway-import.txt) после приёма не нужен: в нём ключ.
    # Копию конфига в before-import ловушка НЕ трогает: она -- ради отката
    # после удачного приёма, меню и панель на неё ссылаются.
    # Прерванный приём (Ctrl+C, TERM) откатывается: непроверенные правки
    # лежали бы дельтой UCI, и их унёс бы следующий commit (Ф9, п2-36).
    _bak=$LISTS/before-import
    _idone=""
    trap '[ "$_idone" = 0 ] && tf_undo; case "$_src" in /var/run/byway-import.txt) rm -f "$_src" ;; esac' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Разбор и приём: правки UCI -- без commit, списки -- на место.
    _idone=0
    tf_uc import "$_src" "$_nokey" || { _rc=$?; _idone=1; exit "$_rc"; }

    # Проверка сборкой: cmd_gen пишет во временный файл и переносит его после
    # проверки движком, боевой конфиг не портится. Подоболочка нужна: cmd_gen
    # на неудаче делает exit, без неё откат ниже не выполнился бы.
    # Голый `uci commit` при полном флеше обнулил бы файл с ключом (Ф9, п2-35).
    # Ключи -- своим пакетом byway_key, первыми (Ф9, п1-12): без места на
    # них прежний способ подключения не меняется.
    if (cmd_gen) && { [ ! -f /etc/config/byway_key ] || bw_uc ucommit byway_key; } && bw_uc ucommit byway; then
        # Записано: дальше откатывать нечего.
        _idone=1
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
            say "применено. byway выключен настройкой -- включить: byway on"
        fi
    else
        warn "конфиг не собрался — прежние настройки возвращаются на место"
        _idone=1
        tf_undo
        die "настройки из файла не приняты, прежние на месте"
    fi
}

# Откат приёма: дельта UCI и списки -- из копии before-import.
tf_undo() {
    uci -q revert byway || true
    uci -q revert byway_key || true
    # Ключи записались, а остальное -- нет (место кончилось между двумя
    # commit): прежние ключи -- из копии (права 600 cp сохраняет).
    tf_back "$_bak/config_key" /etc/config/byway_key
    # Через временный рядом: cp, оборванный нехваткой места, не встаёт
    # на место рабочего (Ф9, п2-4).
    tf_back "$_bak/domains.lst" "$LISTS/domains.lst"
    tf_back "$_bak/subnets.lst" "$LISTS/subnets.lst"
    # Секции направлений вернёт uci revert, списки -- копии рядом: файлы
    # revert не знает.
    if [ -d "$_bak/routes" ]; then
        for _rb in "$_bak/routes"/*.lst; do
            [ -f "$_rb" ] || continue
            tf_back "$_rb" "$ROUTES_DIR/$(basename "$_rb")"
        done
    fi
    # Сборка могла пройти, а запись -- нет: конфиг движка -- по прежним.
    (cmd_gen) >/dev/null 2>&1 || true
}
