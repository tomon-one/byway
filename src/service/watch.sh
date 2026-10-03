# Сторож из cron (cmd_watch): возврат ядра, починка перехвата, обновление
# списков и byway по расписанию, журнал состояния.

# ── журнал состояния ───────────────────────────────────────────────────────
#
# Журнал Xray (кольцевой буфер 256 КБ) проворачивается за часы, поэтому
# отвалы и перезапуски пишем в свой файл. Только при изменении: при исправной
# работе во флеш (43.7 МБ) не уходит ни байта. Смена PID -- это перезапуск,
# пишется отдельно.
WATCH_LOG=$LISTS/health.log

WATCH_LAST=/tmp/byway-watch.last

# Метка «обвязку сняли намеренно», сторож её не трогает. В tmpfs: после
# перезагрузки снимается, обвязку поднимает запуск службы.
PLUMB_DOWN=/tmp/byway-plumb-down
# Метка держит сторожа и pulse. Пустая -- сняли руками (`byway plumb off`),
# держит до plumb on. С номером -- службу остановила замена ядра: умер её
# процесс (обрыв ssh посреди замены) -- до своего запуска службы она не
# дошла. Метка снимается, служба запускается: иначе её не поднял бы никто --
# сторож при лежащем движке только закрывает доступ.
plumb_down_held() {
    [ -f "$PLUMB_DOWN" ] || return 1
    _pdo=$(cat "$PLUMB_DOWN" 2>/dev/null || true)
    [ -n "$_pdo" ] || return 0
    if tr '\0' ' ' < "/proc/$_pdo/cmdline" 2>/dev/null | grep -q byway; then
        return 0
    fi
    rm -f "$PLUMB_DOWN" 2>/dev/null || true
    if [ "$(u enabled)" = "1" ] && [ -z "$(xray_pid)" ]; then
        logf 'метка остановки от умершего процесса %s снята -- служба запускается' "$_pdo"
        /etc/init.d/byway start >/dev/null 2>&1 || true
    fi
    return 1
}

# Сколько проверок подряд не нашлось движка; в tmpfs, после перезагрузки с 0.
NOPID=/tmp/byway-nopid

# Промежуток словами: 90m, 3h, 2h37m, 1d, 1d6h. Отдаёт минуты, при мусоре -1.
mins_of() {
    _s=$(printf '%s' "$1" | tr 'DHM' 'dhm' | tr -d ' ')
    case "$_s" in ''|0) echo 0; return 0 ;; esac
    case "$_s" in *[!0-9]*) ;; *) echo "$_s"; return 0 ;; esac   # голое число -- минуты
    echo "$_s" | awk '{
        n = 0; v = 0; ok = 1
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c >= "0" && c <= "9") { v = v * 10 + (c + 0); continue }
            if      (c == "d") n += v * 1440
            else if (c == "h") n += v * 60
            else if (c == "m") n += v
            else { ok = 0; break }
            v = 0
        }
        if (!ok) { print -1 } else { print n + v }
    }'
}

cmd_watch() {
    watch_restore
    watch_snapshot
    watch_heal
    watch_lists
    watch_upcheck
    watch_autoupdate
    watch_access
    watch_hosts

    _now="nft=${_tab:-0} rule=${_rul:-0} route=${_rt:-0} dns=$_dm fakeip=$_fk"
    _cur="pid=${_pid:-none} $_now"
    _prev=$(cat "$WATCH_LAST" 2>/dev/null || true)

    [ "$_cur" = "$_prev" ] && [ -z "$_healed" ] && return 0

    _stamp=$(date '+%Y-%m-%d %H:%M')
    # Пометки и значения полей (yes/no/none) одинаковы на всех языках: строку
    # читают глазами, grep-ом и в отчёте человеку, который русского не знает.
    _why=""
    case "$_prev" in
      "") _why="(start)" ;;
      *)  _oldpid=${_prev#pid=}; _oldpid=${_oldpid%% *}
          if [ "$_oldpid" != "${_pid:-none}" ]; then
              _why="(restart)"
              # Респавн procd не зовёт plumb on, кэш dnsmasq не сбрасывает
              # никто, а таблица fakedns живёт в памяти Xray: старый адрес из
              # пула новый процесс не знает или уже отдал другому домену.
              # HUP, а не рестарт: не рвёт резолв дому.
              if [ -n "$_pid" ] && [ "$_fk" = yes ]; then
                  killall -HUP dnsmasq 2>/dev/null || true
                  logt "движок перезапустился — кэш dnsmasq сброшен: прежние подставные адреса недействительны"
              fi
          fi
          ;;
    esac

    [ -n "$_healed" ] && _why="$_healed"
    printf '%s  %s%s\n' "$_stamp" "$_cur" "${_why:+  $_why}" >> "$WATCH_LOG"
    printf '%s' "$_cur" > "$WATCH_LAST"

    if [ "$(grep -c . "$WATCH_LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
        tail -200 "$WATCH_LOG" > "$WATCH_LOG.n" && mv "$WATCH_LOG.n" "$WATCH_LOG"
    fi
}

# Возврат ядра, если файла движка нет.
watch_restore() {
    # Повтор раз в 15 мин, в фоне: загрузка идёт минуты, сторож ходит раз в
    # пять. Запускаемое xray-* рядом -- не повод: его указывают руками.
    _xalt=""
    for _x in /usr/local/bin/xray-*; do [ -x "$_x" ] && _xalt=$_x; done
    if [ "$(u enabled)" = "1" ] && [ -z "$_xalt" ] && ! xray_ok "${XRAY:-/nonexistent}" &&
       [ -z "$(find /tmp/byway-engine-restore -mmin -15 2>/dev/null)" ]; then
        : > /tmp/byway-engine-restore
        logt "byway watch: ядра нет -- byway engine restore в фоне"
        ( "$0" engine restore 2>&1 | sed "s/$(printf '\033')\[[0-9;]*m//g" | logger -t byway ) </dev/null >/dev/null 2>&1 &
    fi
    return 0
}

# Дешёвый снимок состояния: pid, обвязка, резолвер.
watch_snapshot() {
    _pid=$(xray_pid)
    # Не полный health (curl через туннель каждые пять минут -- нагрузка на
    # TLS роутера и ноду). Таблицу ищем по ТОЧНОМУ имени: подстрока `inet
    # byway` совпала бы и с `inet byway_block`, снесённая обвязка при kill
    # switch выглядела бы целой.
    _tab=$(nft list tables 2>/dev/null | grep -cE "^table inet $TABLE\$" || true)
    _rul=$(ip rule show 2>/dev/null | grep -cE "$(rule_re)" || true)
    # Маршрут -- третья опора обвязки: без него помеченный пакет молча
    # гибнет, снаружи «туннель есть, а сайты не открываются».
    _rt=$(ip route show table "$RT_TABLE" 2>/dev/null | grep -c "^local default" || true)
    _dm=$(uci -q get "$DNSSEC.server" 2>/dev/null || echo none)
    _d=$(plain_domains "$(merged_domains)" | head -1)
    _fk=no
    if [ -n "$_d" ]; then
        # Ответ из пула не доказывает, что жив наш движок: поставочные
        # dns_listen и fakeip_pool совпадают с podkop'овскими. Спрашиваем и
        # свою таблицу nft -- её ставит и снимает только byway.
        if nft list table inet "$TABLE" >/dev/null 2>&1 &&
           nslookup "$_d" 127.0.0.1 2>/dev/null | awk '/^Address/{print $NF}' |
               grep -qE "^$(fakeip_re)"; then
            _fk=yes
        fi
    fi
    return 0
}

# Починка обвязки: снятие при мёртвом движке, возврат из запрета, подъём.
watch_heal() {
    # Обвязку сносят и чужие скрипты (`nft flush ruleset`, firewall4, сосед по
    # таблице маршрутизации). Чиним только при живом движке и включённой
    # службе и не после `plumb off` (метка в tmpfs): иначе сторож дрался бы
    # с человеком, снявшим туннель.
    _healed=""
    # Движка нет при включённой службе -- упал, а не выключен; при закрытой
    # модели отказа ради этого случая она и заведена.
    if [ -z "$_pid" ] && [ "$(u enabled)" = "1" ] && ! plumb_down_held; then
        engine_gone
        if [ "$_healed" = "(nodns)" ]; then
            # Пересобираем состояние: в журнал -- то, что стало.
            _tab=$(nft list tables 2>/dev/null | grep -cE "^table inet $TABLE\$" || true)
            _rul=$(ip rule show 2>/dev/null | grep -cE "$(rule_re)" || true)
            _rt=$(ip route show table "$RT_TABLE" 2>/dev/null | grep -c "^local default" || true)
            _dm=$(uci -q get "$DNSSEC.server" 2>/dev/null || echo none)
        fi
    else
        rm -f "$NOPID" 2>/dev/null || true
    fi
    # Движок вернулся при стоящем запрете: respawn procd не зовёт хук
    # service_started, а ветка починки ниже не заходит (обвязка цела) -- без
    # этого список вечно отвечал бы 0.0.0.0. Удачный plumb on сам снимает
    # запрет. `u guard` не спрашиваем (как у block_on): это возврат из
    # запрета, не починка, и выключенный сторож не должен оставлять запрет.
    if [ -n "$_pid" ] && [ -f "$BLOCK_MARK" ]; then
        engine_back
    fi
    if [ -n "$_pid" ] && [ "$(u enabled)" = "1" ] &&
       [ "$(u guard)" != "0" ] && ! plumb_down_held; then
        # Вхождением, а не равенством: в списке резолверов бывают доменные
        # записи пользователя, при равенстве сторож чинил бы исправное
        # каждые пять минут.
        case " $_dm " in *" $(dns_addr) "*) _dmok=1 ;; *) _dmok=0 ;; esac
        # Пропавший маршрут чинится тем же plumb on (`_rt` в условии
        # обязателен): иначе помеченный пакет проваливается в main и уходит
        # в WAN с настоящим адресом, а status, health и doctor зелёные.
        if [ "${_tab:-0}" = "0" ] || [ "${_rul:-0}" = "0" ] ||
           [ "${_rt:-0}" = "0" ] || [ "$_dmok" = "0" ]; then
            logt "byway watch: правил перехвата нет при работающем движке -- восстановление"
            if cmd_plumb on >/dev/null 2>&1; then
                _healed="(healed)"
            else
                _healed="(failed)"
            fi
            # Пересобираем состояние: в журнал -- то, что стало.
            _tab=$(nft list tables 2>/dev/null | grep -cE "^table inet $TABLE\$" || true)
            _rul=$(ip rule show 2>/dev/null | grep -cE "$(rule_re)" || true)
            _rt=$(ip route show table "$RT_TABLE" 2>/dev/null | grep -c "^local default" || true)
            _dm=$(uci -q get "$DNSSEC.server" 2>/dev/null || echo none)
        fi
    fi
    return 0
}

# Обновление готовых списков по промежутку из настройки.
watch_lists() {
    # Промежуток словами (12h, 2h37m): cron «каждые N» умеет, только когда N
    # делит час, поэтому проверка едет на пятиминутном пробуждении. Прошлая
    # загрузка -- mtime каталога списков; touch ДО загрузки, чтобы неудачная
    # попытка не повторялась каждые пять минут.
    _iv=$(mins_of "$(u lists_update)")
    if [ "${_iv:-0}" -gt 0 ] && [ -n "$(u preset)" ]; then
        [ "$_iv" -lt 30 ] && _iv=30          # ниже -- долбёж чужого сервера
        mkdir -p "$PRESETS_DIR"
        if [ -z "$(find "$PRESETS_DIR" -maxdepth 0 -mmin "-$_iv" 2>/dev/null)" ]; then
            touch "$PRESETS_DIR"
            logf 'обновление готовых списков (промежуток %s мин)' "$_iv"
            # Не в /dev/null: предупреждения проверки (пересечение с хостлистом
            # zapret, ширина набора, отказ, срез) из cron никто не видит --
            # кладём в системный журнал.
            _esc=$(printf '\033')
            cmd_presets 2>&1 | sed "s/${_esc}\[[0-9;]*m//g" |
                grep '^\[[!x]\]' | while IFS= read -r _pl; do
                    logger -t byway "$_pl"
                done
            /etc/init.d/byway reload >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# Проверка новой версии byway, без установки.
watch_upcheck() {
    # Проверяем, но не ставим: установка перезапускает службу и отнимает
    # туннель у дома в невыбранный момент, а битый выпуск, поставившийся сам,
    # сломал бы всех разом. Промежуток случайный, 12-36 ч: запрос к GitHub
    # в одно время каждые сутки выделялся бы в трафике. В UPMARK -- минуты
    # до следующей проверки, mtime -- время прошлой.
    if [ "$(u update_check)" != "0" ]; then
        _upm=$(cat "$UPMARK" 2>/dev/null || true)
        case "$_upm" in ''|*[!0-9]*) _upm=1440 ;; esac
        if [ -z "$(find "$UPMARK" -mmin -"$_upm" 2>/dev/null)" ]; then
            # Случайность из uuid ядра: od и hexdump есть не в каждом busybox.
            _ur=$(cut -c1-4 /proc/sys/kernel/random/uuid 2>/dev/null || echo 0)
            case "$_ur" in ''|*[!0-9a-f]*) _ur=0 ;; esac
            printf '%s\n' "$(( 720 + 0x$_ur % 1441 ))" > "$UPMARK"
            _uv=$(latest_version)
            _uc=${_uv%% *}; _un=${_uv#* }
            if [ -n "$_un" ] && [ "$_un" != "$_uc" ] && ver_gt "$_un" "$BYWAY_NUM"; then
                # Пишем только при изменении, иначе строка каждые сутки.
                if [ "$(cat "$NEWVER" 2>/dev/null)" != "$_un" ]; then
                    printf '%s\n' "$_un" > "$NEWVER"
                    # Дата первого обнаружения -- во ФЛЕШ, не по mtime в tmpfs,
                    # и только если этого номера там ещё нет: NEWVER после
                    # перезагрузки стёрт, номер снова «новый», дата сдвигалась
                    # бы на «сейчас», и выдержка (3 суток) не копилась бы у
                    # роутера, который перезагружают чаще. Только при разумных
                    # часах: без батарейки он до синхронизации в 1970-м.
                    _sy=$(date +%Y 2>/dev/null)
                    case "$(cat "$SEENF" 2>/dev/null || true)" in
                      "$_un "*) ;;
                      *) if [ "${_sy:-1970}" -ge 2020 ]; then
                             printf '%s %s\n' "$_un" "$(date +%s)" > "$SEENF" 2>/dev/null || true
                         fi ;;
                    esac
                    logf 'новая версия byway %s (у вас %s): %s' "$_un" "$BYWAY_NUM" "$(cat "$RELNOTE" 2>/dev/null || true)"
                fi
            elif [ -n "$_un" ]; then
                # Стираем только когда ответ получен и новой версии в нём нет:
                # отказ связи (000, 403, обрыв) не доказывает, что выпуска нет,
                # а стёртый NEWVER сбросил бы дату обнаружения и выдержку.
                rm -f "$NEWVER" 2>/dev/null || true
            fi
        fi
    fi
    return 0
}

# Ночная установка новой версии по настройке auto_update.
watch_autoupdate() {
    # Выключено по умолчанию: включивший соглашается на ночной рестарт службы.
    # Ограничения ниже -- плата за отсутствие человека в цепочке.
    if [ "$(u auto_update)" = "1" ] && [ -s "$NEWVER" ] &&
       ver_gt "$(cat "$NEWVER")" "$BYWAY_NUM"; then
        _au=$(cat "$NEWVER")
        # `|| true`: RELNOTE может не быть, под set -e cmd_watch оборвался бы
        # здесь, не дойдя до списков и подрезки журналов.
        _aunote=$(cat "$RELNOTE" 2>/dev/null || true)
        # Часы: без батарейки роутер до синхронизации в 1970-м.
        _auy=$(date +%Y 2>/dev/null); _auh=$(date +%H 2>/dev/null)
        # Выдержка: не раньше трёх суток после первого обнаружения, пусть на
        # грабли наступят те, кто обновляется руками. Метка важности снимает.
        case "$_aunote" in
          ВАЖНО*|CRITICAL*|!*) _aubake=0 ;;
          *)                   _aubake=1 ;;
        esac
        # Возраст -- по записанной дате, не по mtime: ntpd переводит часы
        # скачком после старта, и файл, записанный до скачка, «старел» на него.
        _auage=0
        _ausv=$(cat "$SEENF" 2>/dev/null || true)
        case "$_ausv" in
          "$_au "*)
            _aust=${_ausv#* }
            case "$_aust" in ''|*[!0-9]*) _aust=0 ;; esac
            _aunow=$(date +%s 2>/dev/null || echo 0)
            case "$_aunow" in ''|*[!0-9]*) _aunow=0 ;; esac
            [ "$_aust" -gt 0 ] && [ "$_aunow" -gt "$_aust" ] && _auage=$((_aunow - _aust))
            ;;
        esac
        [ "$_aubake" = 0 ] || [ "$_auage" -ge 259200 ] || _au=""
        # Только внутри минорной версии: 0.1.x -> 0.1.y само, 0.1 -> 0.2 нет.
        [ "${_au%.*}" = "${BYWAY_NUM%.*}" ] || _au=""
        # Правленое руками не трогаем; суммы нет -- версия неизвестна.
        if [ -n "$_au" ]; then
            if [ -f "$BINSUM" ]; then
                [ "$(md5sum /usr/local/bin/byway 2>/dev/null | cut -d" " -f1)" = "$(cat "$BINSUM")" ] || {
                    logt "автообновление: byway правлен руками -- не трогается"
                    _au=""
                }
            else
                # Суммы нет -- версия неизвестного происхождения, не трогаем.
                logt "автообновление: сумма выложенной версии неизвестна -- не трогается"
                _au=""
            fi
        fi
        watch_au_install
    fi
    return 0
}

# Установка выпуска с проверкой туннеля и откатом на копию.
watch_au_install() {
        # Час -- не отметка «пробовали сегодня»: сторож ходит раз в пять минут,
        # внутри часа условие истинно 12 раз. Повторы гасят AUTRY (раз в
        # сутки) и AUFAIL (проваливавшийся номер второй раз не ставим: иначе
        # установка и откат каждую ночь, запись во флеш и два обрыва туннеля).
        if [ -n "$_au" ] && [ "${_auy:-1970}" -ge 2020 ] && [ "$_auh" = "$(au_hour)" ] &&
           [ "$(cat "$AUFAIL" 2>/dev/null || true)" != "$_au" ] &&
           [ -z "$(find "$AUTRY" -mmin -1440 2>/dev/null)" ]; then
            : > "$AUTRY" 2>/dev/null || true
            logf 'автообновление: установка %s (было %s)' "$_au" "$BYWAY_NUM"
            # Копию всей версии, проверку туннеля и откат делает cmd_update
            # сам; здесь -- итог по коду. В подоболочке: die (exit) не должен
            # унести весь прогон сторожа.
            _aurc=0
            ( cmd_update --to "$_au" ) >/dev/null 2>&1 || _aurc=$?
            case "$_aurc" in
              0)
                _f 'обновлено до %s, %s\n' "$_au" "$(date '+%Y-%m-%d %H:%M')" > "$AULOG"
                logf 'автообновление: %s поднялось' "$_au"
                rm -f "$NEWVER" 2>/dev/null || true ;;
              3)
                # AUFAIL -- чтобы следующая ночь не ставила тот же номер.
                printf '%s\n' "$_au" > "$AUFAIL" 2>/dev/null || true
                _f 'ОТКАТ с %s на %s, %s\n' "$_au" "$BYWAY_NUM" "$(date '+%Y-%m-%d %H:%M')" > "$AULOG"
                logf 'автообновление: %s не поднялось -- откат на %s' "$_au" "$BYWAY_NUM" ;;
              4)
                printf '%s\n' "$_au" > "$AUFAIL" 2>/dev/null || true
                _f 'ОТКАТ НЕ УДАЛСЯ: на диске %s, копия в %s\n' "$_au" "$PREVSET" > "$AULOG"
                logf 'автообновление: ОТКАТ НЕ УДАЛСЯ -- копия в %s, вернуть: byway update --rollback' "$PREVSET" ;;
              5)
                logf 'автообновление: копия для отката не сделалась -- установка ОТМЕНЕНА (место на /overlay?)' ;;
              6)
                logf 'автообновление: подпись выпуска %s не сошлась -- не ставится' "$_au" ;;
              *)
                logf 'автообновление: %s не скачалось, работает прежняя' "$_au" ;;
            esac
        fi
    return 0
}

# Потолок журнала обращений 4 МБ.
watch_access() {
    # Обычно обрезает cmd_stat, но учёт можно выключить, а cron потерять;
    # ~90 строк в минуту -- 18 МБ в сутки при 240 МБ памяти. Этот обход
    # ходит независимо от учёта.
    if [ -s "$ACCESS" ] &&
       [ "$(wc -c < "$ACCESS" 2>/dev/null || echo 0)" -gt 4194304 ]; then
        : > "$ACCESS"
        logt "журнал обращений превысил 4 МБ и обрезан -- похоже, не запускается учёт трафика (byway stat в cron)"
    fi
    return 0
}

# DNS через туннель: адрес сервера вписан в конфиг при сборке. Раз в час
# сверяем с внешним резолвером; сменился -- пересборка и reload (иначе туннель
# стучится в старый адрес до ручного byway gen).
watch_hosts() {
    [ "$(u dns_route)" = "tunnel" ] || return 0
    [ -n "$(find /tmp/byway-hostcheck -mmin -60 2>/dev/null)" ] && return 0
    : > /tmp/byway-hostcheck
    _wch=""
    for _wp in $(grep -o '"hosts": {[^}]*}' "$OUT" 2>/dev/null | grep -o '"[^"]*": "[0-9.]*"' | tr -d '" ' ); do
        _wn=${_wp%%:*}; _wo=${_wp#*:}
        _wa=$(server_addr "$_wn")
        [ -n "$_wa" ] && [ "$_wa" != "$_wo" ] && _wch="$_wch $_wn:$_wo->$_wa"
    done
    [ -n "$_wch" ] || return 0
    logf 'адрес сервера сменился (%s) -- пересборка конфига' "${_wch# }"
    "$0" gen >/dev/null 2>&1 && /etc/init.d/byway reload >/dev/null 2>&1 || true
    return 0
}

# Движка нет при включённой службе -- упал, а не выключен. Запрет -- сразу;
# перехват DNS снимается на втором промахе подряд (иначе dnsmasq шлёт весь
# резолв дома в мёртвый вход, единственный апстрим, noresolv=1). procd
# поднимает упавший движок за секунды -- на каждый перезапуск не снимаем.
# Зовут сторож и pulse; _dm -- текущие резолверы dnsmasq.
engine_gone() {
    block_on
    _miss=$(cat "$NOPID" 2>/dev/null || echo 0)
    _miss=$((_miss + 1))
    printf '%s' "$_miss" > "$NOPID" 2>/dev/null || true
    case " $_dm " in
      *" $(dns_addr) "*)
        if [ "${_miss:-0}" -ge 2 ]; then
            # Текст зависит от модели: при закрытой обвязку снимаем, а
            # запрет оставляем -- интернета нет.
            if [ "$(u on_failure)" != "open" ]; then
                logt "движок не поднимается -- перехват снят, запрет «не пускать мимо VPN» ОСТАЁТСЯ: доступа наружу нет"
            else
                logt "движок не поднимается -- перехват снят, дом остаётся с интернетом и без туннеля"
            fi
            # --service: метку «сняли руками» не ставим, иначе сторож не
            # поднял бы обвязку, когда движок вернётся. --keep-block:
            # снимает сторож, не человек; безусловное снятие запрета
            # открывало при закрытой модели окно прямого трафика.
            cmd_plumb off --service --keep-block >/dev/null 2>&1 || true
            _healed="(nodns)"
        fi ;;
    esac
    return 0
}

# Движок вернулся при стоящем запрете: respawn procd не зовёт service_started,
# обвязка цела -- без этого список вечно отвечал бы 0.0.0.0. Удачный plumb on
# снимает запрет. `u guard` не спрашиваем: это возврат, не починка.
engine_back() {
    if [ "$(u enabled)" != "1" ]; then
        block_off
    elif cmd_plumb on >/dev/null 2>&1; then
        logt "движок вернулся -- перехват поднят, запрет «не пускать мимо VPN» снят"
        _healed="(healed)"
    else
        logt "движок вернулся, но перехват не поднялся -- запрет «не пускать мимо VPN» остаётся"
        _healed="(failed)"
    fi
    return 0
}

# Раз в минуту из cron: только «движок упал» и «движок вернулся». Окно без DNS
# при неподнимающемся движке -- 1–2 минуты вместо 5–10 у сторожа. В минуты,
# кратные пяти, ходит сторож: двойной счёт промахов снял бы DNS за полминуты.
cmd_pulse() {
    _pm=$(date +%M); _pm=${_pm#0}
    [ $(( ${_pm:-0} % 5 )) = 0 ] && return 0
    [ "$(u enabled)" = "1" ] || return 0
    plumb_down_held && return 0
    _pid=$(xray_pid)
    _healed=""
    if [ -z "$_pid" ]; then
        _dm=$(uci -q get "$DNSSEC.server" 2>/dev/null || echo none)
        engine_gone
    else
        rm -f "$NOPID" 2>/dev/null || true
        [ -f "$BLOCK_MARK" ] && engine_back
    fi
    return 0
}
