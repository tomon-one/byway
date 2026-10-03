# Обновление самого byway: номер свежей версии, загрузка, откат; метки
# проверки обновлений и ночного автообновления.

# Автопроверка новой версии. Метки в /tmp: ежедневная запись во флеш не
# нужна, а после перезагрузки проверка лишний раз безвредна.
UPMARK=/tmp/byway-upcheck     # когда спрашивали в прошлый раз

UPOK=/tmp/byway-upcheck-ok     # время последней проверки, дошедшей до GitHub
UPFAIL=/tmp/byway-upcheck-fail # код ответа последней неудачной проверки
NEWVER=/tmp/byway-newver      # номер найденной версии, если она новее

RELNOTE=/tmp/byway-relnote    # первая строка описания выпуска

AULOG=/tmp/byway-autoupdate   # чем кончилось ночное обновление

PREVBIN=/etc/byway/byway.prev # прежняя копия одного скрипта (до 0.3.0), удаляется
PREVSET=/etc/byway/prev.tgz   # прежняя версия целиком (скрипт, init, панель) для отката

AUTRY=/etc/byway/.au-try      # когда пробовали обновиться; флеш

SEENF=/etc/byway/.newver-seen # версия и когда увидели впервые; флеш

BINSUM=/etc/byway/.binmd5     # сумма выложенной версии (правку руками не трогаем)

AUFAIL=/etc/byway/.au-failed  # выпуск, который уже не поднялся: второй раз не ставим

# Час автообновления по местному времени роутера, сверяется с `date +%H`.
# Одна функция и для сторожа, и для doctor: иначе doctor назовёт один час,
# а сработает другой. Форма двузначная (04): `date +%H` даёт 04, и сравнение
# строк с «4» не совпало бы никогда.
au_hour() {
    _auhv=$(u auto_update_hour)
    [ -n "$_auhv" ] || _auhv=04
    case "$_auhv" in
      [0-9]|[01][0-9]|2[0-3]) ;;
      *) warnf "час автообновления «%s» не годится, взято 04" "$_auhv" >&2
         _auhv=04 ;;
    esac
    [ "${#_auhv}" = 2 ] || _auhv="0$_auhv"
    printf '%s' "$_auhv"
}

# Спрашивает у GitHub про последний выпуск, печатает «код версия». Код
# отдаётся строкой: из подстановки $( ) переменная не выйдет.
latest_version() {
    _px=$(u local_proxy_port); _px=${_px:-1603}
    _api="https://api.github.com/repos/$BYWAY_REPO/releases/latest"
    _code=000; _body=""
    for _via in "--proxy http://127.0.0.1:$_px" "" doh; do
        if [ "$_via" = doh ]; then gh_resolve; [ -n "$GH_RES" ] || break; _via=$GH_RES; fi
        # shellcheck disable=SC2086
        _r=$(curl -sSL --max-time 25 -A "Mozilla/5.0" $_via -w '
%{http_code}' "$_api" 2>/dev/null || true)
        _code=$(printf '%s' "$_r" | tail -1)
        _body=$(printf '%s' "$_r" | sed '$d')
        # Любой ответ, кроме «не дозвонились», окончателен (404 -- нет
        # репозитория): повтор другим путём затёр бы код нулями.
        case "$_code" in 000) ;; *) break ;; esac
    done
    # Первая строка описания -- в файл, не в вывод: в ней пробелы, они
    # сломали бы разбор поля у вызывающего. В JSON перевод строки -- «\n»
    # из двух знаков, обратная косая и есть граница первой строки.
    printf '%s' "$_body" |
        sed -n 's/.*"body"[^"]*"\([^"\\]*\).*/\1/p' | head -1 > "$RELNOTE" 2>/dev/null || true
    printf '%s %s' "$_code" \
        "$(printf '%s' "$_body" | sed -n 's/.*"tag_name"[^"]*"v*\([0-9][^"]*\)".*/\1/p' | head -1)"
}

# Код выхода для ночного обновления: 0 -- поставлено и туннель работает,
# 3 -- не поднялось и откачено, 4 -- откат не удался, 5 -- копия для отката
# не сделалась, 6 -- подпись не сошлась (оба -- ничего не тронуто), прочее --
# не скачалось.
cmd_update() {
    _uf=""; _nov=0; _uto=""
    while [ $# -gt 0 ]; do
        case "$1" in
          --rollback)
            [ -s "$PREVSET" ] || die "откатывать не на что: копия делается при byway update"
            upd_restore || die "откат не завершён — освободить место на флеше и повторить: byway update --rollback"
            # Снятый вручную выпуск автообновление не вернёт: иначе первая же
            # ночь ставила бы его заново, и откат отменялся без слова.
            printf '%s\n' "$BYWAY_NUM" > "$AUFAIL" 2>/dev/null || true
            sayf "автообновление выпуск %s больше не поставит" "$BYWAY_NUM"
            return 0 ;;
          --check|--force) _uf=$1 ;;
          --no-verify) _nov=1 ;;
          # Ночное: ставится выдержавший три дня номер, а не свежий на 04:00.
          --to) shift; _uto=${1:-}
                case "$_uto" in ''|*[!0-9.]*) dief "непонятная версия «%s»" "$_uto" ;; esac ;;
          *) dief "непонятный ключ: %s — byway update [--check|--force|--rollback|--no-verify]" "$1" ;;
        esac
        shift
    done
    if [ -n "$_uto" ]; then _lv="200 $_uto"; else _lv=$(latest_version); fi
    _code=${_lv%% *}; _new=${_lv#* }
    if [ -z "$_new" ] || [ "$_new" = "$_code" ]; then
        case "$_code" in
          000) die "GitHub не ответил -- похоже, нет связи" ;;
          404) dief "на GitHub нет ни репозитория %s, ни его выпусков" "$BYWAY_REPO" ;;
          403) die "GitHub ответил «слишком часто спрашиваете» -- подождать час" ;;
          *)   dief "GitHub ответил %s, но версии в ответе нет" "$_code" ;;
        esac
    fi

    # Метка «найдена новая» устаревает с самим обновлением: после ручной
    # установки статус и панель до суток писали «доступно X (у вас X)».
    ver_gt "$_new" "$BYWAY_NUM" || rm -f "$NEWVER" 2>/dev/null || true
    if ! ver_gt "$_new" "$BYWAY_NUM"; then
        # Тег могут пересобрать на новом коммите под тем же номером:
        # «новее нет» верно про номер, но не про файлы. Отсюда --force.
        case "$_uf" in
          --force)
            sayf "версия та же (%s), но ставится заново -- так велит --force" "$BYWAY_NUM" ;;
          *)
            sayf "версия %s -- новее нет" "$BYWAY_NUM"
            say "  переставить ту же: byway update --force"
            return 0 ;;
        esac
    else
        sayf "есть новая версия: %s (у вас %s)" "$_new" "$BYWAY_NUM"
    fi
    [ "$_uf" = --check ] && return 0

    # Распаковка в память. Каталог свой у каждого запуска и создаётся
    # атомарно (mktemp, права 700): на имени с $$ каталог, заведённый заранее
    # другим пользователем, mkdir -p принимал как свой, и в него подкладывали
    # исходник, который установщик от root разложит в /usr/local/bin.
    _d=$(mktemp -d /tmp/byway-update.XXXXXX) || die "не создать рабочий каталог в /tmp"
    # INT/TERM -- выйти (EXIT снимет): ловушка без exit оставляла процесс
    # идти дальше после Ctrl+C уже без рабочего каталога.
    trap 'rm -rf "$_d" 2>/dev/null' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _px=$(u local_proxy_port); _px=${_px:-1603}
    _url="https://github.com/$BYWAY_REPO/archive/refs/tags/v$_new.tar.gz"
    say "загрузка"
    net_get --max-time 120 -o "$_d/p.tar.gz" "$_url" ||
        die "не скачалось -- ничего не тронуто"
    tar xzf "$_d/p.tar.gz" -C "$_d" 2>/dev/null || die "не распаковалось -- ничего не тронуто"
    _src=$(find "$_d" -maxdepth 2 -name install.sh 2>/dev/null | head -1)
    [ -n "$_src" ] || die "в пакете нет install.sh -- ничего не тронуто"
    if [ "$_nov" = 1 ]; then
        warn "--no-verify: подпись выпуска не проверяется"
    else
        # 1 -- проверить нечем (нет usign, нет подписи): обход назвать можно.
        # 2 -- подлинность опровергнута: обход не советовать.
        _uvr=0; upd_verify "$_new" "$(dirname "$_src")" "$_d" || _uvr=$?
        case "$_uvr" in
          0) say "подпись выпуска сошлась с ключом byway" ;;
          1) warn "выпуск не поставлен -- ничего не тронуто; поставить без проверки подписи: byway update --no-verify"
             exit 6 ;;
          *) warn "архив не совпал с подписанным выпуском -- подменён или повреждён; ничего не тронуто, повторить позже"
             exit 6 ;;
        esac
    fi

    # Связь до установки: откатывать за мёртвый сервер нельзя (eng_wait).
    _etun0=0
    eng_idle || { tunnel_ok && _etun0=1; } || true
    if ! upd_snapshot; then
        warn "копия прежней версии для отката не сделалась (место на флеше?) -- ничего не тронуто"
        exit 5
    fi

    # Ставит install.sh: он один знает, что куда класть и что оставить
    # (конфигурация, списки); копия этой логики здесь разошлась бы с ним.
    say "установка"
    if ! ( cd "$(dirname "$_src")" && sh install.sh ); then
        # Под set -e установщик мог успеть разложить часть файлов.
        warn "установка оборвалась -- возврат прежней версии"
        upd_restore || exit 4
        exit 3
    fi
    rm -f "$NEWVER" "$RELNOTE" 2>/dev/null || true
    # Поставленный вручную выпуск, который раньше не поднимался, больше не
    # «отвергнут»: doctor писал бы об этом вечно.
    [ "$(cat "$AUFAIL" 2>/dev/null || true)" != "$_new" ] || rm -f "$AUFAIL" 2>/dev/null || true
    eng_idle && return 0
    say "проверка туннеля на новой версии (до 2,5 минуты)"
    if eng_wait; then
        say "готово: туннель на новой версии работает"
        return 0
    fi
    warn "на новой версии туннель не поднялся -- возврат прежней"
    upd_restore || exit 4
    exit 3
}

# Прежняя версия целиком -- в архив на флеш: откат одного скрипта оставлял
# новые init, панель и словарь при старом byway. Только существующие пути.
upd_snapshot() {
    _us=""
    for _uf in /usr/local/bin/byway /etc/init.d/byway /usr/local/bin/byway-uninstall \
               /www/luci-static/resources/view/byway /www/luci-static/resources/byway \
               /usr/share/luci/menu.d/luci-app-byway.json \
               /usr/share/rpcd/acl.d/luci-app-byway.json /etc/byway/lang; do
        [ -e "$_uf" ] && _us="$_us ${_uf#/}"
    done
    rm -f "$PREVBIN" 2>/dev/null || true
    # shellcheck disable=SC2086
    tar czf "$PREVSET.new" -C / $_us 2>/dev/null && [ -s "$PREVSET.new" ] &&
        mv "$PREVSET.new" "$PREVSET" && chmod 600 "$PREVSET" && return 0
    rm -f "$PREVSET.new" 2>/dev/null || true
    return 1
}

# Вернуть архив прежней версии и перезапустить службу. Автозапуск -- заново
# по init прежней версии (номер START у версий разный).
upd_restore() {
    [ -s "$PREVSET" ] || { warn "копии прежней версии нет"; return 1; }
    # Через каталог в памяти и mv на место: запись поверх файла, который
    # сейчас исполняется (byway update --rollback), портила бы его чтение.
    _ur=$(mktemp -d /tmp/byway-rollback.XXXXXX) ||
        { warnf "откат не удался -- копия в %s" "$PREVSET"; return 1; }
    tar xzf "$PREVSET" -C "$_ur" 2>/dev/null || { rm -rf "$_ur"; warnf "откат не удался -- копия в %s" "$PREVSET"; return 1; }
    _urf=0
    for _uf in $(cd "$_ur" && find . -type f); do
        _ud=${_uf#.}
        mkdir -p "$(dirname "$_ud")" 2>/dev/null || true
        cp -p "$_ur$_ud" "$_ud.new" 2>/dev/null && mv "$_ud.new" "$_ud" 2>/dev/null || _urf=1
    done
    rm -rf "$_ur" 2>/dev/null || true
    [ "$_urf" = 0 ] || { warnf "откат лёг не целиком -- копия в %s" "$PREVSET"; return 1; }
    md5sum /usr/local/bin/byway 2>/dev/null | cut -d' ' -f1 > "$BINSUM" 2>/dev/null || true
    /etc/init.d/byway disable >/dev/null 2>&1 || true
    /etc/init.d/byway enable >/dev/null 2>&1 || true
    /etc/init.d/rpcd reload >/dev/null 2>&1 || true
    /etc/init.d/byway restart >/dev/null 2>&1 || true
    say "прежняя версия возвращена"
    return 0
}

# Подпись выпуска (с 0.3.0): SHA256SUMS -- суммы всех файлов архива тега --
# и его подпись лежат вложениями выпуска на GitHub, ключ -- BYWAY_PUBKEY.
# Архив с чужого зеркала или подменённый по дороге не пройдёт: каждый файл
# обязан быть в списке и с той суммой, лишних нет.
# Подписанный список сумм выпуска -- в каталог $2/SHA256SUMS. 0 -- подпись
# сошлась; 1 -- проверить нечем (нет usign, подпись не скачалась); 2 -- не
# сошлась. Общая для byway update и byway lang.
rel_sums() {   # 1 -- номер, 2 -- рабочий каталог
    command -v usign >/dev/null 2>&1 || { warn "нет usign — подпись выпуска проверить нечем"; return 1; }
    _rel="https://github.com/$BYWAY_REPO/releases/download/v$1"
    if ! net_get --max-time 30 -o "$2/SHA256SUMS" "$_rel/SHA256SUMS" ||
       ! net_get --max-time 30 -o "$2/SHA256SUMS.sig" "$_rel/SHA256SUMS.sig"; then
        warnf "у выпуска %s нет подписи (SHA256SUMS.sig) либо она не скачалась" "$1"
        return 1
    fi
    printf 'untrusted comment: byway release key public key\n%s\n' "$BYWAY_PUBKEY" > "$2/key.pub"
    usign -V -q -m "$2/SHA256SUMS" -x "$2/SHA256SUMS.sig" -p "$2/key.pub" ||
        { warn "подпись выпуска не сошлась с ключом byway"; return 2; }
    return 0
}

# Файл совпал со своей строкой подписанного списка.
rel_sum_ok() {   # 1 -- файл, 2 -- путь в выпуске (lang/en.tsv), 3 -- SHA256SUMS
    _rw=$(awk -v f="$2" '{ p = $2; sub(/^\*/, "", p) } p == f { print $1; exit }' "$3")
    [ -n "$_rw" ] && [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$_rw" ]
}

upd_verify() {   # 1 -- номер, 2 -- корень распакованного архива, 3 -- рабочий каталог
    _rsr=0; rel_sums "$1" "$3" || _rsr=$?
    [ "$_rsr" = 0 ] || return "$_rsr"
    ( cd "$2" && sha256sum -c "$3/SHA256SUMS" >/dev/null 2>&1 ) ||
        { warn "файлы архива не совпали с подписанным списком"; return 2; }
    _ul=$(cd "$2" && find . -type f | sed 's|^\./||' | sort)
    _us=$(awk '{ sub(/^\*/, "", $2); print $2 }' "$3/SHA256SUMS" | sort)
    [ "$_ul" = "$_us" ] || { warn "в архиве есть файлы вне подписанного списка"; return 2; }
    # Подпись не несёт номера выпуска: подписанный список старого выпуска
    # сошёлся бы и под новым тегом. Номер -- из подписанных файлов.
    grep -qx "VER=$1" "$2/install.sh" 2>/dev/null &&
        grep -qx "BYWAY_NUM=\"$1\"" "$2/byway" 2>/dev/null ||
        { warnf "архив не того выпуска: внутри не v%s" "$1"; return 2; }
    return 0
}
