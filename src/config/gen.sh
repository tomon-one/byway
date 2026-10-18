# Сборка конфига Xray: cmd_gen готовит окружение, конфиг собирает ucode
# (uc/gen.uc). $OUT меняется, только если ядро приняло конфиг (run -test).

cmd_gen() {
    # Замок: панель и cron могут позвать gen одновременно, а черновик один.
    _lock=/var/run/byway-gen.lock
    take_lock "$_lock" "$(_t 'сборка конфига')" || die "другая сборка конфига не закончилась за 30 секунд"
    # Ловушка снимает замок на любом выходе, в том числе на отказе ucode.
    # INT/TERM -- выйти (EXIT снимет).
    trap 'rm -rf "$_lock" 2>/dev/null; true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [ -f "$CONF" ] || dief "нет %s" "$CONF"
    [ -x "$XRAY" ] || die "xray не найден"
    mkdir -p "$LISTS"
    # Каталог root для журнала обращений и рабочих файлов stat: в общем /tmp
    # движок не от root (ujail) мог бы занять имя заранее (Д-7).
    [ -d /var/run/byway ] || { mkdir -p /var/run/byway && chmod 755 /var/run/byway; } 2>/dev/null || true
    # Список негодных строк -- до сборки списков и направлений.
    : > "$BADLIST" 2>/dev/null || true

    # Слияние списков с пресетами и метка сокетов -- пока на shell (списки,
    # перехват): ucode получает готовое.
    D=$LISTS/domains.lst
    S=$(merged_subnets)
    MERGED=$(merged_domains)
    xray_ver_num >/dev/null
    _gm=$(ob_env_mark)
    _grc=0
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_MERGED=$MERGED BW_SUBNETS=$S \
    BW_BADLIST=$BADLIST BW_ACCESS=$ACCESS BW_PROBE=$PROBE_DOMAIN BW_POOL6_DEF=$POOL6_DEF \
    BW_XRAY=$XRAY BW_XRAYVER=$XRAYVER BW_SELFMARK=$_gm \
        bw_uc gen || _grc=$?
    rm -rf "$_lock" 2>/dev/null || true
    [ "$_grc" = 0 ] || exit "$_grc"
}

# Настоящий адрес сервера для DNS через туннель. Местный резолвер в этом
# режиме отдаёт адрес из прежнего конфига (hosts), смена адреса не увиделась
# бы: сперва пин /etc/hosts, потом внешние резолверы, потом местный.
server_addr() {   # $1 -- имя
    _sa=$(awk -v n="$1" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == n) { print $1; exit } }' \
          /etc/hosts 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)
    [ -n "$_sa" ] || _sa=$(a_of "$1" 8.8.8.8)
    [ -n "$_sa" ] || _sa=$(a_of "$1" 1.1.1.1)
    [ -n "$_sa" ] || _sa=$(a_of "$1")
    printf '%s' "$_sa"
}
