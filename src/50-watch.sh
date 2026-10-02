# Сторож из cron (cmd_watch): возврат ядра, починка перехвата, обновление
# списков и byway по расписанию, журнал состояния. cmd_job -- фоновые задачи
# панели.

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
# Сколько проверок подряд не нашлось движка; в tmpfs, после перезагрузки с 0.
NOPID=/tmp/byway-nopid
# Фоновая задача панели: обновление и замена ядра идут минуты, запрос панели
# живёт секунды. `job update|engine [ВЕРСИЯ]` запускает и сразу отвечает,
# `job log` отдаёт ход (конец -- строка «== конец»). Одна задача за раз.
JOBLOG=/tmp/byway-job.log
JOBPID=/var/run/byway-job.pid

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

cmd_job() {
    case "${1:-}" in
      update|engine)
        if [ -f "$JOBPID" ] && kill -0 "$(cat "$JOBPID" 2>/dev/null)" 2>/dev/null; then
            die "уже идёт другая задача — дождаться её конца"
        fi
        if [ "$1" = update ]; then set -- update
        else set -- engine "${2:-tested}"; fi
        : > "$JOBLOG"
        _js=""; command -v setsid >/dev/null 2>&1 && _js=setsid
        $_js "$0" job run "$@" </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$JOBPID"
        sayf "задача запущена: byway %s" "$*"
        ;;
      run)
        # Прямо в файл, без конвейера: sed в конвейере пишет блоками, ход был
        # бы виден только в конце. Цвета снимает `job log`.
        shift
        { "$0" "$@" 2>&1; printf '\n== %s\n' "$(_t конец)"; } > "$JOBLOG"
        rm -f "$JOBPID" 2>/dev/null || true
        ;;
      log)
        sed "s/$(printf '\033')\[[0-9;]*m//g" "$JOBLOG" 2>/dev/null || true
        # Код 3 -- «ещё идёт»: панель судит по коду, а не по тексту.
        if [ -f "$JOBPID" ] && kill -0 "$(cat "$JOBPID" 2>/dev/null)" 2>/dev/null; then
            printf '%s\n' "$(_t '… идёт')"
            return 3
        fi
        ;;
      *) die "byway job update|engine [ВЕРСИЯ]|log" ;;
    esac
}

cmd_watch() {
    watch_restore
    watch_snapshot
    watch_heal
    watch_lists
    watch_upcheck
    watch_autoupdate
    watch_access

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
           nslookup "$_d" 127.0.0.1 2>/dev/null | grep -qE "$(fakeip_re)"; then
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
    if [ -z "$_pid" ] && [ "$(u enabled)" = "1" ] && [ ! -f "$PLUMB_DOWN" ]; then
        block_on
        # Обвязка стоит, а движка нет: dnsmasq шлёт весь резолв дома на мёртвый
        # вход (единственный апстрим, noresolv=1). Ветка починки ниже требует
        # живого процесса, block_on при open выходит сразу. Действуем на
        # ВТОРОМ подряд наблюдении (5 мин): procd поднимает движок сам за
        # секунды, на каждый рестарт обвязку не снимаем.
        _miss=$(cat "$NOPID" 2>/dev/null || echo 0)
        _miss=$((_miss + 1))
        printf '%s' "$_miss" > "$NOPID" 2>/dev/null || true
        case " $_dm " in
          *" $(dns_addr) "*)
            if [ "${_miss:-0}" -ge 2 ]; then
                # Текст зависит от модели: при закрытой обвязку снимаем, а
                # запрет оставляем -- интернета нет.
                if [ "$(u on_failure)" != "open" ]; then
                    logt "движок не поднимается пять минут -- перехват снят, запрет «не пускать мимо VPN» ОСТАЁТСЯ: доступа наружу нет"
                else
                    logt "движок не поднимается пять минут -- перехват снят, дом остаётся с интернетом и без туннеля"
                fi
                # --service: метку «сняли руками» не ставим, иначе сторож не
                # поднял бы обвязку, когда движок вернётся. --keep-block:
                # снимает сторож, не человек; безусловное снятие запрета
                # открывало при закрытой модели окно прямого трафика.
                cmd_plumb off --service --keep-block >/dev/null 2>&1 || true
                _healed="(nodns)"
                # Пересобираем состояние: в журнал -- то, что стало.
                _tab=$(nft list tables 2>/dev/null | grep -cE "^table inet $TABLE\$" || true)
                _rul=$(ip rule show 2>/dev/null | grep -cE "$(rule_re)" || true)
                _rt=$(ip route show table "$RT_TABLE" 2>/dev/null | grep -c "^local default" || true)
                _dm=$(uci -q get "$DNSSEC.server" 2>/dev/null || echo none)
            fi ;;
        esac
    else
        rm -f "$NOPID" 2>/dev/null || true
    fi
    # Движок вернулся при стоящем запрете: respawn procd не зовёт хук
    # service_started, а ветка починки ниже не заходит (обвязка цела) -- без
    # этого список вечно отвечал бы 0.0.0.0. Удачный plumb on сам снимает
    # запрет. `u guard` не спрашиваем (как у block_on): это возврат из
    # запрета, не починка, и выключенный сторож не должен оставлять запрет.
    if [ -n "$_pid" ] && [ -f "$BLOCK_MARK" ]; then
        if [ "$(u enabled)" != "1" ]; then
            block_off
        elif cmd_plumb on >/dev/null 2>&1; then
            logt "движок вернулся -- перехват поднят, запрет «не пускать мимо VPN» снят"
            _healed="(healed)"
        else
            logt "движок вернулся, но перехват не поднялся -- запрет «не пускать мимо VPN» остаётся"
            _healed="(failed)"
        fi
    fi
    if [ -n "$_pid" ] && [ "$(u enabled)" = "1" ] &&
       [ "$(u guard)" != "0" ] && [ ! -f "$PLUMB_DOWN" ]; then
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
    if [ "$(u auto_update)" = "1" ] && [ -s "$NEWVER" ]; then
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
            # Копия для отката проверяется, без неё не ставим: /overlay 43.7 МБ
            # уже доходил до нуля свободных байт.
            _aubk=1
            cp /usr/local/bin/byway "$PREVBIN" 2>/dev/null && [ -s "$PREVBIN" ] || _aubk=0
            chmod 755 "$PREVBIN" 2>/dev/null || true
            _auprev=$(md5sum "$PREVBIN" 2>/dev/null | cut -d' ' -f1)
            if [ "$_aubk" = 0 ]; then
                logf 'автообновление: копия для отката не сделалась -- установка ОТМЕНЕНА (место на /overlay?)'
            else
            # В подоболочке: cmd_update при отказе зовёт die (exit), без скобок
            # он унёс бы весь прогон сторожа.
            _aurc=0
            _autun0=0; tunnel_ok && _autun0=1
            ( cmd_update ) >/dev/null 2>&1 || _aurc=1
            # Судим делом и на ветке отказа: установщик под set -e успевает
            # подложить новый бинарник до падения на следующем шаге. «Не
            # скачалось» -- только если сумма файла не тронута.
            if [ "$_aurc" = 1 ] &&
               [ "$(md5sum /usr/local/bin/byway 2>/dev/null | cut -d' ' -f1)" = "$_auprev" ]; then
                logf 'автообновление: %s не скачалось, работает прежняя' "$_au"
            else
                # Судим делом, не кодом установщика: нужно «туннель поднялся».
                # 15 оборотов по 10 с, не 6: обвязку после рестарта поднимает
                # фоновый цикл службы (бюджет «до 65 секунд» -- пол, в обороте
                # есть блокирующий nslookup); на 60-й секунде исправную версию
                # откатывали.
                _auok=0
                for _aut in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                    sleep 10
                    if alive_ok && { [ "$_autun0" = 0 ] || tunnel_ok; }; then _auok=1; break; fi
                done
                if [ "$_auok" = 1 ]; then
                    _f 'обновлено до %s, %s\n' "$_au" "$(date '+%Y-%m-%d %H:%M')" > "$AULOG"
                    logf 'автообновление: %s поднялось' "$_au"
                    rm -f "$NEWVER" 2>/dev/null || true
                else
                    # Ради этого копия: чинить некому, чинит роутер сам.
                    # AUFAIL -- чтобы следующая ночь не ставила тот же номер.
                    printf '%s\n' "$_au" > "$AUFAIL" 2>/dev/null || true
                    # Итог восстановления читается: проглоченный отказ cp
                    # объявил бы откат состоявшимся и переписал сумму под
                    # непрошедшую версию, стерев признак поломки.
                    _aurb=1
                    cp "$PREVBIN" /usr/local/bin/byway 2>/dev/null || _aurb=0
                    chmod 755 /usr/local/bin/byway 2>/dev/null || true
                    if [ "$_aurb" = 0 ]; then
                        logf 'автообновление: ОТКАТ НЕ УДАЛСЯ -- на диске %s, копия в %s. Восстановить руками: cp %s /usr/local/bin/byway' "$_au" "$PREVBIN" "$PREVBIN"
                        _f 'ОТКАТ НЕ УДАЛСЯ: на диске %s, копия в %s\n' "$_au" "$PREVBIN" > "$AULOG"
                    else
                    # Сумма -- по восстановленному файлу: установщик уже
                    # переписал .binmd5 суммой новой версии, без этого проверка
                    # видела бы «правлен руками» каждую ночь.
                    md5sum /usr/local/bin/byway 2>/dev/null | cut -d' ' -f1 > "$BINSUM" 2>/dev/null || true
                    /etc/init.d/byway restart >/dev/null 2>&1 || true
                    _f 'ОТКАТ с %s на %s, %s\n' "$_au" "$BYWAY_NUM" "$(date '+%Y-%m-%d %H:%M')" > "$AULOG"
                    logf 'автообновление: %s не поднялось -- откат на %s' "$_au" "$BYWAY_NUM"
                    fi
                fi
            fi
            fi
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
