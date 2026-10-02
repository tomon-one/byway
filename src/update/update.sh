# Обновление самого byway: номер свежей версии, загрузка, откат; метки
# проверки обновлений и ночного автообновления.

# Автопроверка новой версии. Метки в /tmp: ежедневная запись во флеш не
# нужна, а после перезагрузки проверка лишний раз безвредна.
UPMARK=/tmp/byway-upcheck     # когда спрашивали в прошлый раз

NEWVER=/tmp/byway-newver      # номер найденной версии, если она новее

RELNOTE=/tmp/byway-relnote    # первая строка описания выпуска

AULOG=/tmp/byway-autoupdate   # чем кончилось ночное обновление

PREVBIN=/etc/byway/byway.prev # копия прежней версии, для отката

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

cmd_update() {
    _lv=$(latest_version)
    _code=${_lv%% *}; _new=${_lv#* }
    if [ -z "$_new" ] || [ "$_new" = "$_code" ]; then
        case "$_code" in
          000) die "GitHub не ответил -- похоже, нет связи" ;;
          404) dief "на GitHub нет ни репозитория %s, ни его выпусков" "$BYWAY_REPO" ;;
          403) die "GitHub ответил «слишком часто спрашиваете» -- подождать час" ;;
          *)   dief "GitHub ответил %s, но версии в ответе нет" "$_code" ;;
        esac
    fi

    if ! ver_gt "$_new" "$BYWAY_NUM"; then
        # Тег могут пересобрать на новом коммите под тем же номером:
        # «новее нет» верно про номер, но не про файлы. Отсюда --force.
        case "${1:-}" in
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
    case "${1:-}" in --check) return 0 ;; esac

    # Распаковка в память. Каталог свой у каждого запуска ($$): на общем
    # имени в /tmp кто угодно подложил бы исходник, который установщик от
    # root разложит в /usr/local/bin.
    _d=/tmp/byway-update.$$
    rm -rf "$_d" 2>/dev/null || true
    mkdir -p "$_d"
    trap 'rm -rf "$_d" 2>/dev/null' EXIT INT TERM
    _px=$(u local_proxy_port); _px=${_px:-1603}
    _url="https://github.com/$BYWAY_REPO/archive/refs/tags/v$_new.tar.gz"
    say "загрузка"
    net_get --max-time 120 -o "$_d/p.tar.gz" "$_url" ||
        die "не скачалось -- ничего не тронуто"
    tar xzf "$_d/p.tar.gz" -C "$_d" 2>/dev/null || die "не распаковалось -- ничего не тронуто"
    _src=$(find "$_d" -maxdepth 2 -name install.sh 2>/dev/null | head -1)
    [ -n "$_src" ] || die "в пакете нет install.sh -- ничего не тронуто"

    # Ставит install.sh: он один знает, что куда класть и что оставить
    # (конфигурация, списки); копия этой логики здесь разошлась бы с ним.
    say "установка"
    ( cd "$(dirname "$_src")" && sh install.sh )
}
