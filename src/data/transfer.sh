# Перенос настроек: export, import, clear. Ключ в выгрузке -- только с
# --with-key; import кладёт прежнее в before-import.

# ── перенос настроек ───────────────────────────────────────────────────────
# Формат -- один текстовый файл, читаемый глазами и вставляемый в переписку:
# архив в сообщение не вставишь, base64 в busybox нет. Ключ в выгрузку не
# должен попадать сам: --no-key -- export его не пишет, import не трогает
# нынешний.

# Список явный, а не «всё из секции»: чужой файл не должен задавать роутеру
# произвольную опцию; незнакомое имя -- описка или настройка версии новее.
EXPORT_KEYS="enabled conn_mode node_url sub_url outbound_json conn_label
             list_mode ru_direct preset interface fakeip_pool dns_upstream
             dns_upstream2 dns_bootstrap dns_listen tproxy_port local_proxy_port redirect_port
             router_via_vpn mark self_mark log_level ipv6 fakeip6_pool
             show_usage mux_concurrency probe_interval guard block_quic allow_insecure
             lists_update dns_route on_failure node_urls lang update_check
             auto_update auto_update_hour"

# xray_bin не переносится: это путь к программе, которую byway запускает от
# root, из чужого файла его брать не надо (xray_ok удержит, но незачем), и
# он машинный -- на другом роутере пути обычно нет.

# Опции с ключом: ими различаются «поделиться настройкой» и «отдать доступ».
SECRET_KEYS="node_url node_urls sub_url outbound_json"

# Списочные опции UCI: вводятся через add_list, иначе одна строка с пробелами.
LIST_KEYS="preset interface node_urls"

# Тело отдельно от cmd_export: /dev/stdout есть не в каждой сборке busybox, и
# «в файл или на экран» одной строкой иначе не записать.
export_body() {
    {
        echo "# byway export 1"
        _f '# программа: byway %s\n' "$BYWAY_VERSION"
        _f '# снято: %s с %s\n' "$(date '+%Y-%m-%d %H:%M')" "$(uci -q get system.@system[0].hostname || _t роутера)"
        [ "$_nokey" = 1 ] &&
            echo "$(_t '# БЕЗ КЛЮЧА: подключение к VPN придётся вписать заново')"
        echo
        echo "[settings]"
        for _k in $EXPORT_KEYS; do
            [ "$_nokey" = 1 ] && in_set "$_k" "$SECRET_KEYS" && continue
            _v=$(uci -q get "byway.main.$_k" || true)
            [ -n "$_v" ] || continue
            # Перевод строки в значении рвёт формат (свой конфиг аутбаунда
            # вставляют многострочным): сворачиваем в одну строку, JSON цел.
            printf '%s=%s\n' "$_k" "$(printf '%s' "$_v" | tr '\n\r' '  ')"
        done
        # Пустой строки перед заголовком нет намеренно: она попала бы в конец
        # предыдущего списка, и import тихо менял бы разбивку файла на секции.
        # Строки со скобки из списков выкидываем: не отличить от заголовка.
        echo "[domains]"
        grep -v '^\[' "$LISTS/domains.lst" 2>/dev/null || true
        echo "[subnets]"
        grep -v '^\[' "$LISTS/subnets.lst" 2>/dev/null || true
        # Направления -- своими разделами, у каждого свой список. Без них на
        # новом роутере трафик, разложенный по нодам, шёл бы весь в основную.
        for _rn in $(route_names); do
            printf '[route:%s]\n' "$_rn"
            printf 'label=%s\n' "$(uci -q get "byway.$_rn.label" || true)"
            printf 'enabled=%s\n' "$(uci -q get "byway.$_rn.enabled" || echo 1)"
            printf '[routelist:%s]\n' "$_rn"
            grep -v '^\[' "$ROUTES_DIR/$_rn.lst" 2>/dev/null || true
        done
    }
}

# ── очистка накопленного ────────────────────────────────────────────────────
# Файлы обнуляются, а не удаляются: byway дописывает в них на ходу, и
# исчезнувший файл пришлось бы создавать заново каждому, кто пишет.
cmd_clear() {
    case "${1:-}" in
      log)
        : > "$LISTS/health.log"; : > /tmp/byway-watch.last
        say "журнал состояния очищен" ;;
      stat)
        # Стираем и сырьё (хвост журнала обращений с адресами), и карту с
        # позицией обхода и отсечкой времени: иначе карта считается уже
        # построенной, новая не строится и всё идёт в строку «(по IP)».
        : > "$LISTS/usage.tsv"; : > "$MAP"; : > "$ACCESS"
        rm -f "$MAPPOS" "$MARK" 2>/dev/null || true
        say "статистика использования очищена" ;;
      all)
        : > "$LISTS/health.log"; : > /tmp/byway-watch.last
        : > "$LISTS/usage.tsv"; : > "$MAP"; : > "$ACCESS"
        rm -f "$MAPPOS" "$MARK" 2>/dev/null || true
        say "журнал и статистика очищены" ;;
      *) die "byway clear log | stat | all" ;;
    esac
}

# Куда можно писать выгрузку и откуда читать. Панель запускает byway с ЛЮБЫМИ
# аргументами (rpcd проверяет только путь программы): без проверки `byway
# export /etc/passwd` перезапишет системный файл от root. Системные каталоги
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
        export_body
        return 0
    fi
    path_ok "$_dest" || die "сюда писать нельзя: системные каталоги закрыты"
    # Под umask 077 во временный файл и mv -- как в cmd_report.
    ( umask 077; export_body > "$_dest.new.$$" )
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
    head -1 "$_src" | grep -q '^# byway export' ||
        die "это не выгрузка byway: в первой строке нет заголовка"
    import_backup

    _tmp=/tmp/byway-import.$$
    # Ловушка обязательна: в разобранной выгрузке лежит ключ, а выйти можно и
    # по die, и по Ctrl+C. $_bak ловушка НЕ трогает: копию конфига (с ключом,
    # во флеше, права 700) заводят ради отката ПОСЛЕ удачного приёма, меню и
    # панель на неё ссылаются. Каталог один, следующий приём перезапишет.
    trap 'rm -rf "$_tmp" 2>/dev/null' EXIT INT TERM
    mkdir -p "$_tmp"
    chmod 700 "$_tmp" 2>/dev/null || true
    awk -v d="$_tmp" '
        function nm(str,   n) { n = substr(str, index(str, ":") + 1)
            sub(/\]$/, "", n)
            return (n ~ /^[A-Za-z0-9_-]+$/) ? n : "" }
        /^\[settings\]$/ { s = d "/settings"; next }
        /^\[domains\]$/  { s = d "/domains";  next }
        /^\[subnets\]$/  { s = d "/subnets";  next }
        /^\[route:.*\]$/ { n = nm($0)
            if (n == "") { s = ""; next }
            print n >> (d "/routes"); s = d "/route." n; next }
        /^\[routelist:.*\]$/ { n = nm($0)
            s = (n == "") ? "" : d "/routelist." n; next }
        # Неизвестный раздел -- НЕ дописывать в предыдущий. Выгрузка
        # от будущей версии иначе уронила бы свои строки в чужой
        # список, и заметить это было бы неоткуда.
        /^\[.*\]$/ { s = ""; next }
        /^#/ { next }
        s { print > s }
    ' "$_src"
    import_settings
    import_lists
    import_routes
    rm -rf "$_tmp"

    sayf "принято настроек: %s" "$_n"
    if [ "$_nokey" = 1 ]; then
        say "ключ оставлен прежний"
        # Ключ в файле есть, но не взят -- сказать прямо: иначе отказ вылезет
        # позже строкой «конфиг не собрался», без указания причины.
        grep -q '^node_url=..' "$_src" 2>/dev/null &&
            warn "в выгрузке ключ ЕСТЬ, но принят не был -- так велит --no-key (в панели это галочка «Оставить нынешний ключ»)"
    fi

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
            say "применено. byway выключен настройкой -- включить: uci set byway.main.enabled=1 && uci commit byway"
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

# Шаг import: копия конфига и списков в before-import ДО правки.
import_backup() {
    _bak=$LISTS/before-import
    mkdir -p "$_bak"
    chmod 700 "$_bak" 2>/dev/null || true
    ( umask 077; rm -f "$_bak/config"; cp "$CONF" "$_bak/config" ) 2>/dev/null || true
    cp "$LISTS/domains.lst" "$_bak/domains.lst" 2>/dev/null || true
    cp "$LISTS/subnets.lst" "$_bak/subnets.lst" 2>/dev/null || true
    return 0
}

# Шаг import: опции из [settings] в UCI, только из EXPORT_KEYS.
import_settings() {
    _n=0; _skip=""
    if [ -s "$_tmp/settings" ]; then
        while IFS= read -r _line; do
            case "$_line" in ''|'#'*) continue ;; esac
            _k=${_line%%=*}; _v=${_line#*=}
            [ "$_k" = "$_line" ] && continue
            if ! in_set "$_k" "$EXPORT_KEYS"; then
                _skip="$_skip $_k"; continue
            fi
            [ "$_nokey" = 1 ] && in_set "$_k" "$SECRET_KEYS" && continue
            if in_set "$_k" "$LIST_KEYS"; then
                uci -q delete "byway.main.$_k" || true
                # set -f: значение из ЧУЖОГО файла, без него «*» раскрылся бы
                # в список файлов каталога и попал в настройки.
                set -f
                for _w in $_v; do uci add_list "byway.main.$_k=$_w"; done
                set +f
            else
                uci set "byway.main.$_k=$_v"
            fi
            _n=$((_n + 1))
        done < "$_tmp/settings"
    fi
    [ -n "$_skip" ] && warnf "настройки неизвестны и пропущены:%s" "$_skip"
    return 0
}

# Шаг import: списки доменов и подсетей; пустой раздел -- «список был пуст»,
# отсутствующий -- «про списки речи не было».
import_lists() {
    for _l in domains subnets; do
        [ -f "$_tmp/$_l" ] || continue
        # Убираем только последнюю пустую строку: пустые внутри -- ручная
        # разбивка на секции, стирать её нельзя.
        sed '${/^[[:space:]]*$/d;}' "$_tmp/$_l" > "$LISTS/$_l.lst"
    done
    return 0
}

# Шаг import: направления заменяются целиком (как списки), нет раздела --
# прежние остаются на месте.
import_routes() {
    if [ -f "$_tmp/routes" ]; then
        mkdir -p "$_bak/routes"
        chmod 700 "$_bak/routes" 2>/dev/null || true
        for _old in $(route_names); do
            cp "$ROUTES_DIR/$_old.lst" "$_bak/routes/$_old.lst" 2>/dev/null || true
            uci -q delete "byway.$_old" || true
        done
        mkdir -p "$ROUTES_DIR"
        while IFS= read -r _rn; do
            [ -n "$_rn" ] || continue
            # Имя из чужого файла станет именем секции UCI и файла: проверка
            # дублирует awk, цена ошибки -- запись мимо каталога.
            case "$_rn" in
              *[!A-Za-z0-9_-]*|'') warnf "направление «%s» пропущено: имя не годится" "$_rn"; continue ;;
            esac
            uci -q set "byway.$_rn=route"
            while IFS= read -r _rl; do
                case "$_rl" in
                  label=*)   uci -q set "byway.$_rn.label=${_rl#label=}" ;;
                  enabled=*) uci -q set "byway.$_rn.enabled=${_rl#enabled=}" ;;
                esac
            done < "$_tmp/route.$_rn"
            if [ -f "$_tmp/routelist.$_rn" ]; then
                sed '${/^[[:space:]]*$/d;}' "$_tmp/routelist.$_rn" > "$ROUTES_DIR/$_rn.lst"
            else
                : > "$ROUTES_DIR/$_rn.lst"
            fi
            _n=$((_n + 1))
        done < "$_tmp/routes"
    fi
    return 0
}
