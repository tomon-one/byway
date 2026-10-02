# Ядро Xray: byway engine ВЕРСИЯ|tested|newest|stable|restore|ФАЙЛ --
# загрузка со сверкой sha256, замена рядом или через память, откат.

# ── замена движка ──────────────────────────────────────────────────────────
# Два ядра по ~35 МБ на 43 МБ раздела не встают: при месте новое кладётся
# рядом (eng_side), иначе служба стоит, а ядро проверяется в /tmp (eng_ram).
# Архив прежней версии берётся ДО остановки -- после неё GitHub может быть
# недоступен. SHA2-256 из .dgst -- от битой загрузки, не подпись. Туннель
# при замене падает, поэтому команда только ручная: сторож её не зовёт.

# Сборки XTLS на MIPS без сопроцессора не запускаются (только hardfloat) --
# та же функция в install.sh, править парой.
eng_mips_nofpu() {
    case "$(uname -m)" in mips*) ;; *) return 1 ;; esac
    # Содержимое, а не [ -s ]: procfs отдаёт нулевой размер.
    _ci=$(cat /proc/cpuinfo 2>/dev/null || true)
    [ -n "$_ci" ] || return 1
    case "$_ci" in *[Ff][Pp][Uu]*) return 1 ;; esac
    return 0
}

# Имя файла выпуска под эту машину -- та же функция в install.sh, править
# парой. DISTRIB_ARCH первым: uname -m на MIPS не различает порядок байтов.
eng_asset() {
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

# net_get: сперва через прокси-вход byway (GitHub в списке), потом напрямую.
eng_dl() { net_get "$@"; }

# Номер выпуска XTLS: stable -- releases/latest, any -- самый свежий. У XTLS
# предвыпуском помечено всё новее 26.3.27, и «latest» отдаёт мартовский.
eng_top() {   # 1 -- stable | any
    if [ "$1" = stable ]; then
        _evu=https://api.github.com/repos/XTLS/Xray-core/releases/latest
    else
        _evu="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1"
    fi
    eng_dl --max-time 25 "$_evu" |
        sed -n 's/.*"tag_name"[^"]*"v\([^"]*\)".*/\1/p' | head -1
}

# Архив версии $1 в файл $2, со сверкой суммы. 0 -- лежит и сверен, 1 -- не
# скачался, 2 -- сумма не сошлась или её нет. Файла при отказе не остаётся.
eng_fetch() {   # 1 версия, 2 файл
    _efu="https://github.com/XTLS/Xray-core/releases/download/v$1/Xray-$ENG_ASSET.zip"
    rm -f "$2" "$2.dgst" 2>/dev/null || true
    eng_dl --max-time 300 -o "$2" "$_efu" || { rm -f "$2" 2>/dev/null; return 1; }
    eng_dl --max-time 30 -o "$2.dgst" "$_efu.dgst" || { rm -f "$2" "$2.dgst" 2>/dev/null; return 2; }
    _efw=$(sed -n 's/^SHA2-256= *\([0-9a-f]\{64\}\).*/\1/p' "$2.dgst" | head -1)
    _efg=$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)
    rm -f "$2.dgst" 2>/dev/null || true
    if [ -z "$_efw" ] || [ "$_efw" != "$_efg" ]; then
        rm -f "$2" 2>/dev/null || true
        return 2
    fi
    return 0
}

# Размер ядра внутри архива, байты. Пусто -- в архиве нет файла xray.
eng_size() {
    case "$1" in
      *.gz) eng_cat "$1" | wc -c ;;
      *)    unzip -l "$1" xray 2>/dev/null | awk '$NF=="xray"{print $1; exit}' ;;
    esac
}

# Бинарник xray из пакета на stdout: .gz -- своя сборка (byway engine ФАЙЛ),
# иначе архив выпуска XTLS.
eng_cat() {
    case "$1" in
      *.gz) gunzip -c "$1" 2>/dev/null ;;
      *)    unzip -p "$1" xray 2>/dev/null ;;
    esac
}

# Ядро из архива $1 в путь $2: через временное имя, чтобы оборванная
# распаковка не оставила под рабочим именем половину файла.
eng_put() {   # 1 архив, 2 путь
    rm -f "$2.new" 2>/dev/null || true
    if eng_cat "$1" > "$2.new" && [ -s "$2.new" ] &&
       chmod 755 "$2.new" && mv "$2.new" "$2"; then
        return 0
    fi
    rm -f "$2.new" 2>/dev/null || true
    return 1
}

# «Не скачалось» чаще из-за туннеля, а не сети: GitHub в списке byway, и при
# мёртвом туннеле резолвер отдаёт подставной адрес. Снятая обвязка возвращает
# настоящий DNS; рестарт службы в ходе замены поднимет её обратно.
eng_nonet() {
    warn "  GitHub не ответил ни через туннель, ни напрямую, ни по адресам из DoH — проверить связь роутера и повторить"
}

eng_free_kb() {   # свободно на разделе, где лежит /usr/local/bin, КБ
    df -k /usr/local/bin 2>/dev/null | awk 'NR==2{print $4}'
}

eng_mem_kb() { awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null; }

# Конфиг под движок $1 тем же cmd_gen: развилки по версии (xray_ver_num)
# берутся от НОВОГО движка, он же проверяет итог.
eng_gen() {   # 1 путь к движку
    ( XRAY=$1; XRAYVER=""; cmd_gen ) > "$_ed/gen.log" 2>&1
}

# Без выхода по set -e: на пути «через память» отказ здесь случается при
# остановленной службе, и выход оставил бы дом без туннеля.
eng_bin_set() {   # 1 путь
    if ! { uci set byway.main.xray_bin="$1" && uci commit byway; } 2>/dev/null; then
        warnf "путь к движку не записался в настройки: uci set byway.main.xray_bin=%s && uci commit byway" "$1"
    fi
    return 0
}

# Дождаться туннеля. 150 с -- бюджет автоотката обновления: обвязку после
# старта поднимает фоновый цикл службы, ему нужно до ~65 с сверх запуска.
eng_wait() {
    eng_idle && return 0
    # Сервер проверяем, только если он отвечал ДО замены (_etun0): мёртвый
    # сервер -- не вина нового ядра, откатывать за это нельзя.
    for _ew in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        sleep 10
        alive_ok && { [ "${_etun0:-0}" = 0 ] || tunnel_ok; } && return 0
    done
    return 1
}

cmd_engine() {
    case "${1:-}" in /*) eng_local "$1"; return 0 ;; esac
    command -v unzip >/dev/null 2>&1 ||
        dief "нет unzip — поставить: %s unzip" "$PKG_FIX"
    command -v sha256sum >/dev/null 2>&1 ||
        die "нет sha256sum — сверить архив нечем, замена не начата"
    if eng_mips_nofpu; then
        die "на этом процессоре сборки Xray-core с GitHub не запускаются — движок обновляется пакетом OpenWrt: apk upgrade xray-core либо opkg upgrade xray-core"
    fi
    ENG_ASSET=$(eng_asset) ||
        dief "неизвестно, какой файл выпуска брать для %s" "$(uname -m)"
    _eold=$XRAY
    _eov=""
    [ -n "$_eold" ] && [ -x "$_eold" ] &&
        _eov=$("$_eold" version 2>/dev/null | head -1 | awk '{print $2}' | tr -cd '0-9.')

    _earg=${1:-}
    case "$_earg" in
      ''|--check)
        # Первым -- ответ «есть ли новее». Путь, место и память -- в
        # подробностях; в --check (его зовёт панель) их нет.
        _env=$(eng_top any || true)
        _esv=$(eng_top stable || true)
        if [ -z "$_eov" ]; then
            warn "ядро Xray не указано или не запускается (byway.main.xray_bin)"
            say "  поставить: byway engine restore"
        elif [ -z "$_env" ]; then
            sayf "стоит Xray %s; есть ли новее — неизвестно: GitHub не ответил" "$_eov"
            eng_nonet
        elif ver_gt "$_env" "$_eov"; then
            sayf "есть обновление ядра: Xray %s (стоит %s)" "$_env" "$_eov"
        else
            sayf "обновлений ядра нет: стоит Xray %s" "$_eov"
        fi
        if [ -n "$_eov" ] && [ "$XRAY_TESTED" != "$_eov" ]; then
            if ver_gt "$_eov" "$XRAY_TESTED"; then
                sayf "  стоит новее проверенной с byway (%s)" "$XRAY_TESTED"
            else
                sayf "  проверенная с byway: %s" "$XRAY_TESTED"
            fi
        fi
        if [ -n "$_env" ] && [ -n "$_eov" ] && ver_gt "$_env" "$_eov"; then
            sayf "  поставить: byway engine %s" "$_env"
            [ "$XRAY_TESTED" != "$_env" ] && ver_gt "$XRAY_TESTED" "$_eov" &&
                say "  или проверенную: byway engine tested"
        fi
        [ "$_earg" = "--check" ] && return 0
        say "подробно:"
        [ -n "$_eov" ] && sayf "  файл: %s" "$_eold"
        [ -n "$_env" ] && sayf "  самая свежая у XTLS: %s, стабильная: %s" "$_env" "${_esv:-?}"
        _efk=$(eng_free_kb || echo 0); _emk=$(eng_mem_kb || echo 0)
        sayf "  на флеше свободно %s МБ, памяти доступно %s МБ" \
            "$(( ${_efk:-0} / 1024 ))" "$(( ${_emk:-0} / 1024 ))"
        say "  варианты: byway engine ВЕРСИЯ | tested | newest | stable | restore | /tmp/ФАЙЛ.gz"
        return 0 ;;
      tested) _env=$XRAY_TESTED ;;
      # Ядра нет (sysupgrade его не сохраняет): версия из имени файла в
      # xray_bin (настройки sysupgrade переживают), иначе проверенная. Зовут
      # служба при старте и сторож.
      restore)
        [ -z "$_eov" ] || { sayf "ядро на месте: Xray %s" "$_eov"; return 0; }
        _erb=$(uci -q get byway.main.xray_bin 2>/dev/null || true)
        _env=${_erb##*/xray-}
        _env=${_env%%-*}
        case "$_erb" in /usr/local/bin/xray-*) ;; *) _env="" ;; esac
        case "$_env" in ''|*[!0-9.]*) _env=$XRAY_TESTED ;; esac ;;
      newest) _env=$(eng_top any || true)
              [ -n "$_env" ] || die "GitHub не ответил — номер свежей версии неизвестен, ничего не тронуто" ;;
      stable) _env=$(eng_top stable || true)
              [ -n "$_env" ] || die "GitHub не ответил — номер свежей версии неизвестен, ничего не тронуто" ;;
      *)      _env=$_earg ;;
    esac
    case "$_env" in
      *[!0-9.]*|.*|*.) dief "непонятная версия «%s» — нужен номер вида 26.9.9 либо tested, newest, stable, restore" "$_earg" ;;
    esac
    # Своя сборка той же версии (xray-local-*, xray-26.9.30-h2l) -- не «стоит
    # уже»: официальная возвращается той же командой.
    case "$_eold" in
      /usr/local/bin/xray-*-*) ;;
      *) [ "$_env" != "$_eov" ] || { sayf "стоит уже %s — менять нечего" "$_env"; return 0; } ;;
    esac

    _enew=/usr/local/bin/xray-$_env
    _elk=/var/run/byway-engine.lock
    take_lock "$_elk" "$(_t 'замена движка')" || die "замена движка уже идёт"
    _ed=/tmp/byway-engine.$$
    rm -rf "$_ed" 2>/dev/null || true
    mkdir -p "$_ed"
    trap 'rm -rf "$_ed" "$_elk" 2>/dev/null' EXIT INT TERM

    # Архив в память: ~14 МБ. Меньше 40 МБ доступно -- живой движок рядом с
    # ним рискует OOM, а он и есть туннель.
    _emk=$(eng_mem_kb || echo 0)
    [ "${_emk:-0}" -ge 40960 ] ||
        dief "памяти доступно %s МБ, для замены нужно не меньше 40 — ничего не тронуто" "$(( ${_emk:-0} / 1024 ))"

    # Ядра нет -- место проверяем ДО загрузки: сторож повторяет раз в 15 мин,
    # качать 14 МБ ради отказа каждый раз незачем.
    if [ -z "$_eov" ]; then
        _efree=$(eng_free_kb || echo 0)
        [ "${_efree:-0}" -ge 25600 ] ||
            dief "на флеше свободно %s МБ, ядру нужно %s — ничего не тронуто" \
                 "$(( ${_efree:-0} / 1024 ))" 25
    fi
    sayf "загрузка Xray-core %s (%s)" "$_env" "$ENG_ASSET"
    _erc=0; eng_fetch "$_env" "$_ed/new.zip" || _erc=$?
    case "$_erc" in
      0) ;;
      1) eng_nonet
         dief "архив %s не скачался — ничего не тронуто" "$_env" ;;
      *) dief "архив %s не сошёлся с суммой SHA2-256 из .dgst выпуска — отброшен, ничего не тронуто" "$_env" ;;
    esac
    _epkg=$_ed/new.zip
    _esz=$(eng_size "$_epkg")
    [ -n "$_esz" ] || die "в архиве нет файла xray — ничего не тронуто"
    say "архив сверен с суммой из выпуска"

    # Рядом -- если на флеше есть весь размер ядра и 5 МБ сверху. Сжатие
    # ubifs не угадать, поэтому меряется по несжатому.
    _efree=$(eng_free_kb || echo 0)
    # Ядра нет вовсе: откатываться не на что, откат не нужен -- просто ставим.
    if [ -z "$_eov" ]; then
        eng_fresh
        return 0
    fi
    _etun0=0
    eng_idle || { tunnel_ok && _etun0=1; } || true
    if [ "$(( ${_efree:-0} * 1024 ))" -ge "$(( _esz + 5242880 ))" ]; then
        eng_side
    else
        eng_ram
    fi
}

# Путь «ядра нет» (после sysupgrade или снятого пакета): ставится без отката.
eng_fresh() {
    # 25 МБ, как у установщика: ubifs дожимает ядро примерно вдвое, порог
    # «несжатый размер + 5» отказывал роутеру с /overlay 43.7 МБ после
    # sysupgrade -- тому, ради кого восстановление и заведено.
    [ "${_efree:-0}" -ge 25600 ] ||
        dief "на флеше свободно %s МБ, ядру нужно %s — ничего не тронуто" \
             "$(( ${_efree:-0} / 1024 ))" 25
    sayf "ядра нет — ставится Xray %s" "$_env"
    eng_put "$_epkg" "$_enew" || die "ядро не распаковалось на флеш — ничего не тронуто"
    if ! "$_enew" version >/dev/null 2>&1; then
        rm -f "$_enew" 2>/dev/null || true
        die "ядро не запускается на этом железе — удалено"
    fi
    eng_bin_set "$_enew"
    logf 'движок поставлен: %s (прежнего не было)' "$_env"
    if [ "$(u enabled)" = "1" ]; then
        say "запуск службы"
        /etc/init.d/byway restart >/dev/null 2>&1 || true
    fi
    sayf "готово: Xray %s, на флеше свободно %s МБ" "$_env" "$(( $(eng_free_kb || echo 0) / 1024 ))"
}

# Путь «рядом». Прежнее ядро не трогается до успеха: откат -- вернуть путь.
eng_side() {
    say "места хватает — новое ядро кладётся рядом с прежним"
    eng_put "$_epkg" "$_enew" || die "ядро не распаковалось на флеш — ничего не тронуто"
    rm -f "$_epkg" 2>/dev/null || true
    if ! "$_enew" version >/dev/null 2>&1; then
        rm -f "$_enew" 2>/dev/null || true
        die "новое ядро не запускается на этом железе — удалено, работает прежнее"
    fi
    if eng_idle; then
        eng_bin_set "$_enew"
        case "$_eold" in /usr/local/bin/xray-*) rm -f "$_eold" 2>/dev/null || true ;; esac
        sayf "служба не работает (выключена или нет ключа) — ядро заменено без проверки туннеля: Xray %s" "$_env"
        return 0
    fi
    if ! eng_gen "$_enew"; then
        tail -6 "$_ed/gen.log" | sed 's/^/    /'
        rm -f "$_enew" 2>/dev/null || true
        eng_gen "$_eold" || true
        die "новый движок не принял конфиг — удалён, работает прежний"
    fi
    eng_bin_set "$_enew"
    warn "перезапуск службы: туннель пропадёт на несколько секунд"
    /etc/init.d/byway restart >/dev/null 2>&1 || true
    say "проверка туннеля на новом движке (до 2,5 минуты)"
    if eng_wait; then
        # Удаляется, только если ядро наше: /usr/bin/xray -- файл пакета, снос
        # в обход менеджера оставил бы пакет с дырой.
        case "$_eold" in
          /usr/local/bin/xray-*) rm -f "$_eold" 2>/dev/null || true
                                 sayf "прежний движок удалён: %s" "$_eold" ;;
          *) sayf "прежний движок %s — из пакета, оставлен; снять можно пакетным менеджером" "$_eold" ;;
        esac
        logf 'движок заменён: %s -> %s' "$_eov" "$_env"
        sayf "готово: Xray %s, на флеше свободно %s МБ" "$_env" "$(( $(eng_free_kb || echo 0) / 1024 ))"
        return 0
    fi
    warn "туннель на новом движке не поднялся — возврат прежнего"
    eng_bin_set "$_eold"
    eng_gen "$_eold" || true
    /etc/init.d/byway restart >/dev/null 2>&1 || true
    rm -f "$_enew" 2>/dev/null || true
    logf 'движок: %s не поднялся, возвращён %s' "$_env" "$_eov"
    dief "возвращён %s; новое ядро удалено" "$_eov"
}

# Путь «через память». После остановки службы -- никаких die: любой отказ
# кончается запуском службы, иначе дом без туннеля.
eng_ram() {
    case "$_eold" in
      /usr/local/bin/xray-*) ;;
      *) dief "места на второе ядро нет, а прежнее (%s) — из пакета; снять пакет вручную и поставить заново: byway engine %s" "$_eold" "$_env" ;;
    esac
    sayf "места на второе ядро нет (свободно %s МБ) — замена через память" "$(( ${_efree:-0} / 1024 ))"
    # Откат -- из архива прежней версии, он берётся СЕЙЧАС, пока туннель жив.
    # Нет архива -- замена не начинается.
    sayf "загрузка прежней версии %s — для отката" "$_eov"
    _erc=0; eng_fetch "$_eov" "$_ed/old.zip" || _erc=$?
    [ "$_erc" = 0 ] ||
        dief "архив прежней версии %s не получен — без копии для отката замена не начата" "$_eov"

    warn "остановка службы: туннель пропадёт примерно на минуту"
    # При «не пускать мимо VPN» запрет держится всю минуту (stop_service).
    BYWAY_KEEP_BLOCK=1 /etc/init.d/byway stop >/dev/null 2>&1 || true
    # Сторож не должен «чинить» остановленную службу посреди замены; метку
    # снимает plumb on при запуске.
    : > "$PLUMB_DOWN" 2>/dev/null || true
    sleep 2
    _emk=$(eng_mem_kb || echo 0)
    if [ "$(( ${_emk:-0} * 1024 ))" -lt "$(( _esz + 20971520 ))" ]; then
        warnf "памяти после остановки мало: %s МБ" "$(( ${_emk:-0} / 1024 ))"
        eng_ram_back
    fi
    _etmp=$_ed/xray
    if ! eng_cat "$_epkg" > "$_etmp" || ! chmod 755 "$_etmp" ||
       ! "$_etmp" version >/dev/null 2>&1; then
        warn "новое ядро не распаковалось или не запускается"
        eng_ram_back
    fi
    rm -f "$_epkg" 2>/dev/null || true
    # Без ключа конфига нет, сверять нечего (eng_idle, как в eng_side).
    if ! eng_idle && ! eng_gen "$_etmp"; then
        tail -6 "$_ed/gen.log" | sed 's/^/    /'
        eng_gen "$_eold" || true
        warn "новый движок не принял конфиг"
        eng_ram_back
    fi
    # Точка невозврата: прежнее ядро уступает место.
    rm -f "$_eold" 2>/dev/null || true
    if ! cp "$_etmp" "$_enew.new" 2>/dev/null || ! chmod 755 "$_enew.new" ||
       ! mv "$_enew.new" "$_enew"; then
        rm -f "$_enew.new" "$_enew" 2>/dev/null || true
        warn "новое ядро не легло на флеш"
        eng_ram_restore
    fi
    rm -f "$_etmp" 2>/dev/null || true
    eng_bin_set "$_enew"
    /etc/init.d/byway start >/dev/null 2>&1 || true
    say "проверка туннеля на новом движке (до 2,5 минуты)"
    if eng_wait; then
        rm -f "$_ed/old.zip" 2>/dev/null || true
        logf 'движок заменён: %s -> %s' "$_eov" "$_env"
        sayf "готово: Xray %s, на флеше свободно %s МБ" "$_env" "$(( $(eng_free_kb || echo 0) / 1024 ))"
        return 0
    fi
    BYWAY_KEEP_BLOCK=1 /etc/init.d/byway stop >/dev/null 2>&1 || true
    rm -f "$_enew" 2>/dev/null || true
    warn "туннель на новом движке не поднялся"
    eng_ram_restore
}

# Отказ ДО удаления прежнего ядра: оно на месте, достаточно запустить.
eng_ram_back() {
    /etc/init.d/byway start >/dev/null 2>&1 || true
    die "служба запущена с прежним движком — ничего не заменено"
}

# Отказ ПОСЛЕ удаления: прежнее ядро -- из архива, скачанного до остановки.
eng_ram_restore() {
    sayf "возврат %s из архива" "$_eov"
    if eng_put "$_ed/old.zip" "$_eold"; then
        eng_bin_set "$_eold"
        eng_gen "$_eold" || true
        /etc/init.d/byway start >/dev/null 2>&1 || true
        logf 'движок: %s не встал, возвращён %s' "$_env" "$_eov"
        dief "возвращён %s" "$_eov"
    fi
    # Флеш не принял и прежнее ядро. Службу всё равно запускаем: без движка
    # она не встанет, но и dnsmasq не останется смотреть в мёртвый порт --
    # обвязку без движка plumb не ставит.
    /etc/init.d/byway start >/dev/null 2>&1 || true
    # Архив прежнего -- единственное, что осталось: ловушка его не трогает.
    trap - EXIT INT TERM
    rm -rf "$_elk" 2>/dev/null || true
    logf 'движок: НИ НОВОЕ, НИ ПРЕЖНЕЕ ядро не легло на флеш -- туннеля нет'
    dief "ни новое, ни прежнее ядро не легло на флеш — туннеля нет. Архив прежнего: %s (в памяти, до перезагрузки); поставить: unzip -p %s xray > %s && chmod 755 %s && /etc/init.d/byway start" \
        "$_ed/old.zip" "$_ed/old.zip" "$_eold" "$_eold"
}

# Служба не работает (выключена или нет ключа): туннеля для проверки нет,
# ядро меняется без неё. Иначе на ненастроенном роутере замена откатывалась
# бы «туннель не поднялся».
eng_idle() {
    [ "$(u enabled)" != "1" ] && return 0
    case "$(u conn_mode)" in
      urltest|selector) [ -z "$(u node_urls)" ] ;;
      outbound)         [ -z "$(u outbound_json)" ] ;;
      *)                [ -z "$(u node_url)" ] ;;
    esac
}

# Своя сборка ядра из /tmp (.gz с бинарником xray или .zip выпуска): та же
# замена с откатом, но без сверки с .dgst -- sha256 печатается, сверяет
# человек со своей сборкой. Файл после установки удаляется (память).
eng_local() {
    case "$1" in
      /tmp/*) ;;
      *) die "своя сборка ядра — только из /tmp: на флеше рядом с ядром ей нет места" ;;
    esac
    [ -f "$1" ] || dief "нет файла %s" "$1"
    # unzip и имя сборки -- для отката через память: прежнее ядро берётся
    # архивом выпуска с GitHub.
    command -v unzip >/dev/null 2>&1 ||
        dief "нет unzip — поставить: %s unzip" "$PKG_FIX"
    ENG_ASSET=$(eng_asset 2>/dev/null) || ENG_ASSET=""
    _eold=$XRAY
    _eov=""
    [ -n "$_eold" ] && [ -x "$_eold" ] &&
        _eov=$("$_eold" version 2>/dev/null | head -1 | awk '{print $2}' | tr -cd '0-9.')
    _epkg=$1
    _esz=$(eng_size "$_epkg")
    [ "${_esz:-0}" -gt 1048576 ] ||
        dief "в %s нет ядра xray — нужен .gz с бинарником или .zip выпуска" "$1"
    sayf "своя сборка: %s, sha256 ядра %s" "$1" "$(eng_cat "$_epkg" | sha256sum | cut -d' ' -f1)"
    _env=$(_t 'своя сборка')
    _enew=/usr/local/bin/xray-local-$(date +%Y%m%d%H%M)
    _elk=/var/run/byway-engine.lock
    take_lock "$_elk" "$(_t 'замена движка')" || die "замена движка уже идёт"
    _ed=/tmp/byway-engine.$$
    rm -rf "$_ed" 2>/dev/null || true
    mkdir -p "$_ed"
    trap 'rm -rf "$_ed" "$_elk" 2>/dev/null' EXIT INT TERM
    _emk=$(eng_mem_kb || echo 0)
    [ "${_emk:-0}" -ge 40960 ] ||
        dief "памяти доступно %s МБ, для замены нужно не меньше 40 — ничего не тронуто" "$(( ${_emk:-0} / 1024 ))"
    _efree=$(eng_free_kb || echo 0)
    if [ -z "$_eov" ]; then
        eng_fresh
        return 0
    fi
    _etun0=0
    eng_idle || { tunnel_ok && _etun0=1; } || true
    if [ "$(( ${_efree:-0} * 1024 ))" -ge "$(( _esz + 5242880 ))" ]; then
        eng_side
    else
        eng_ram
    fi
}

# Ядро на Go 1.27 без -tags http2legacy: XHTTP открывает соединение на каждый
# ждущий запрос, xmux.maxConnections их не держит; при висящем рукопожатии --
# сотни соединений и OOM (Xray#6797, сборки XTLS с 26.9.8). Тег сборки виден
# в buildinfo бинарника. $1 -- путь к ядру.
eng_dial_bug() {
    "$1" version 2>/dev/null | head -1 | grep -q '(go1\.27[.) ]' || return 1
    ! grep -q 'http2legacy' "$1" 2>/dev/null
}
