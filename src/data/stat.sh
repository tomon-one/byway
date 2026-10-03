# Учёт обращений по журналу Xray (stat из cron) и top -- чем пользуются.

# ── учёт использования ─────────────────────────────────────────────────────
#
# Xray пишет строку в момент приёма, до сниффинга: в ней адрес из пула, не
# имя (`accepted tcp:198.19.14.63:443 [tproxy-in -> proxy]`). FakeDNS отдаёт
# домену один адрес до рестарта Xray -- раз за PID строим таблицу адрес ->
# имя. logqueries у dnsmasq отвергнут: раздувает буфер журнала (256 КБ) и
# чаще пишет во флеш. Подсети идут по настоящим адресам -- строка «(по IP)».

# Рабочие файлы учёта -- в каталоге root (/var/run/byway, 755), а не в общем
# /tmp: движок от пользователя byway мог подложить туда карту «адрес -> домен»
# или метку, и root записал бы её в usage.tsv.
STATDIR=/var/run/byway
STAT=$LISTS/usage.tsv        # домен, обращений, последний раз

MAP=$STATDIR/fakemap       # адрес -> домен, живёт в памяти как и сам Xray

MARK=$STATDIR/statmark     # PID и метка времени последней обработанной строки

MAPPOS=$STATDIR/fakemap.pos # докуда дошли, строя карту порциями

# Журнал обращений, из которого считается учёт, движок пишет только при
# show_usage=1 (или уровне info/debug).
stat_off() {
    [ "$(u show_usage)" = "1" ] && return 1
    case "$(u log_level)" in info|debug) return 1 ;; esac
    return 0
}

cmd_stat() {
    mkdir -p "$STATDIR" 2>/dev/null || true
    stat_off && warn "сбор статистики выключен — включить: uci set byway.main.show_usage=1 && uci commit byway && /etc/init.d/byway reload (в панели: Обслуживание → Сбор статистики)"
    _p=$(xray_pid)
    [ -n "$_p" ] || { warn "xray не запущен, считать нечего"; return 0; }
    _l=$(dns_addr)

    _oldpid=$(sed -n 1p "$MARK" 2>/dev/null || true)
    stat_map
    stat_collect
    stat_count
    : > "$_tmp"
}

# Карта адрес -> домен через FakeDNS, порциями.
# Домены для карты адрес -> домен: общий список и списки включённых
# направлений (их соединения идут в учёт наравне с основными).
stat_domains() {
    {
        cat "$(merged_domains)" 2>/dev/null || true
        for _rn in $(route_names); do
            [ "$(uci -q get "byway.$_rn.enabled")" = "0" ] && continue
            route_list "$ROUTES_DIR/$_rn.lst" dom
        done
    } > $STATDIR/stat-doms
    plain_domains $STATDIR/stat-doms
}

stat_map() {
    # Таблица привязана к PID: после рестарта прежние адреса недействительны.
    # Порциями (_MSTEP доменов за прогон, позиция в MAPPOS): полный обход --
    # около семи форков на домен, при 200 000 доменов прогон длиннее часа, и
    # следующий cron стартовал бы поверх. Неназванный адрес -- «(по IP)».
    _MSTEP=200
    _newmap=0
    if [ "$_oldpid" != "$_p" ]; then : > "$MAP"; : > "$MAPPOS"; _newmap=1; fi
    _mpos=$(cat "$MAPPOS" 2>/dev/null || echo 0)
    case "$_mpos" in ''|*[!0-9]*) _mpos=0 ;; esac
    stat_domains > $STATDIR/stat-doms.plain
    _mall=$(grep -c . $STATDIR/stat-doms.plain || true); _mall=${_mall:-0}
    if [ "$_newmap" = 1 ] || [ "$_mpos" -lt "$_mall" ]; then
        _fre=$(fakeip_re)
        sed -n "$((_mpos + 1)),$((_mpos + _MSTEP))p" $STATDIR/stat-doms.plain |
        while IFS= read -r _d; do
            _a=$(nslookup "$_d" "$_l" 2>/dev/null |
                 sed -n 's/^Address: *//p' | grep -E "^$_fre" | head -1)
            [ -n "$_a" ] && printf '%s\t%s\n' "$_a" "$_d" >> "$MAP"
        done || true
        # `|| true`: последним в теле цикла AND-список, домен без подставного
        # адреса даёт 1, и под set -e весь учёт умер бы.
        _mpos=$((_mpos + _MSTEP))
        [ "$_mpos" -gt "$_mall" ] && _mpos=$_mall || true
        printf '%s' "$_mpos" > "$MAPPOS" 2>/dev/null || true
        # Отсечка времени -- по сборке таблицы: в буфере строки прежних
        # запусков Xray, их адреса из пула недействительны. Только при смене
        # pid, иначе учёт обнулялся бы каждый час, пока карта достраивается.
        # Время в UTC: Xray пишет в нём, syslog -- в местном.
        if [ "$_newmap" = 1 ]; then
            printf '%s\n%s\n' "$_p" "$(date -u '+%Y/%m/%d %H:%M:%S')" > "$MARK"
        fi
        sayf "карта: %s из %s доменов, адресов %s" \
             "$_mpos" "$_mall" "$(grep -c . "$MAP" || true)"
    fi
    return 0
}

# Отбор строк журнала обращений после последней учтённой.
stat_collect() {
    _since=$(sed -n 2p "$MARK" 2>/dev/null || true)
    _tmp=$STATDIR/stat.tmp

    # Метка -- время Xray из начала строки (монотонно в журнале, у syslog
    # другой пояс). Ветка logread -- для конфига версии до 2026-09-05, где
    # обращения шли в syslog: без неё учёт обнулился бы до пересборки.
    if [ -s "$ACCESS" ]; then
        grep -E 'tproxy-in -> (proxy|route-)' "$ACCESS" > "$_tmp" 2>/dev/null || true
        # Обрезаем сразу, оставляя хвост 50 строк: из него cmd_status берёт имя
        # работающего ключа. Двойного счёта нет: метка по последней учтённой.
        # cat, а не mv: движок держит файл открытым, подмена уведёт запись в
        # удалённый. Строки между grep и обрезкой теряются -- единицы.
        tail -50 "$ACCESS" > "$ACCESS.n" 2>/dev/null &&
            cat "$ACCESS.n" > "$ACCESS" && rm -f "$ACCESS.n" || true
    else
        logread -e xray 2>/dev/null |
          sed -n 's/.*xray[^:]*\[[0-9]*\]: //p' |
          grep -E 'tproxy-in -> (proxy|route-)' > "$_tmp" || true
    fi
    if [ -n "$_since" ]; then
        # substr: метка -- ровно 19 знаков, строка с той же секундой строго
        # больше неё, а хвост в 50 строк содержит последнюю учтённую: без
        # substr она засчитывалась бы заново каждый час.
        awk -v s="$_since" 'substr($0,1,19) > s' "$_tmp" > "$_tmp.new" && mv "$_tmp.new" "$_tmp"
    fi
    return 0
}

# Подсчёт обращений по таблице и запись итога.
stat_count() {
    _last=$(tail -1 "$_tmp" 2>/dev/null | cut -d' ' -f1-2 || true)
    # grep -c при нуле совпадений даёт 1 -- под set -e смерть, а ноль здесь
    # штатен.
    _n=$(grep -c . "$_tmp" 2>/dev/null || true); _n=${_n:-0}

    if [ "${_n:-0}" -gt 0 ]; then
        _today=$(date '+%Y-%m-%d')
        # Всё в awk одним проходом: дешевле shell-цикла по тысяче строк.
        awk -v map="$MAP" -v stat="$STAT" -v today="$_today" '
          BEGIN {
            while ((getline l < map) > 0) { split(l, a, "\t"); name[a[1]] = a[2] }
            close(map)
            while ((getline l < stat) > 0) {
              split(l, b, "\t"); cnt[b[1]] = b[2]; seen[b[1]] = b[3]
            }
            close(stat)
          }
          {
            if (match($0, /tcp:[0-9.]+:/) || match($0, /udp:[0-9.]+:/)) {
              s = substr($0, RSTART + 4, RLENGTH - 5)
              d = (s in name) ? name[s] : "(по IP)"
              cnt[d]++; seen[d] = today
            }
          }
          END { for (d in cnt) printf "%s\t%d\t%s\n", d, cnt[d], seen[d] }
        ' "$_tmp" | sort > $STATDIR/stat.new
        # Во флеш -- только если итог изменился.
        if ! cmp -s $STATDIR/stat.new "$STAT"; then
            mv $STATDIR/stat.new "$STAT"
            chmod 600 "$STAT" 2>/dev/null || true
        else
            rm -f $STATDIR/stat.new
        fi
        [ -n "$_last" ] && printf '%s\n%s\n' "$_p" "$_last" > "$MARK"
        sayf "учтено соединений: %s, всего доменов в учёте: %s" "$_n" "$(grep -c . "$STAT")"
    else
        say "новых соединений в журнале нет"
    fi
    return 0
}

# Показать накопленное. Без аргумента — двадцать самых частых.
cmd_top() {
    if [ ! -s "$STAT" ]; then
        stat_off && die "сбор статистики выключен — включить: uci set byway.main.show_usage=1 && uci commit byway && /etc/init.d/byway reload (в панели: Обслуживание → Сбор статистики)"
        die "учёт пуст. Собирается задачей cron; вручную: byway stat"
    fi
    _n=${1:-20}
    # Ширина колонки -- в символах: printf в busybox считает байты, и
    # кириллица сдвигала колонку. Всё печатает один awk (`_len` на строку --
    # сотня процессов, 0.15 с из 0.29 с, замер 2026-09-05); ширина -- байты
    # минус продолжающие байты UTF-8, как в _len. Отступ циклом: busybox awk
    # не поддерживает %*s.
    sort -t"$(printf '\t')" -k2 -rn "$STAT" | head -"$_n" |
      awk -F'\t' -v h1="$(_t домен)" -v h2="$(_t обращений)" \
              -v h3="$(_t 'последний раз')" -v cont='[\200-\277]' '
        function w(s,   t) { t = s; gsub(cont, "", t); return length(t) }
        function pad(n,   s) { s = ""; while (n-- > 0) s = s " "; return s }
        function row(a, b, c) { printf "  %s%s%8s  %s\n", a, pad(42 - w(a)), b, c }
        BEGIN { row(h1, h2, h3) }
        { row($1, $2, $3) }'
    printf "$(_t '\n  всего в учёте %s доменов из %s в списке\n')" \
      "$(grep -c . "$STAT")" "$(count_list "$(merged_domains)")"
}
