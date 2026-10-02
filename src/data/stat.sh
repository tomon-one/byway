# Учёт обращений по журналу Xray (stat из cron) и top -- чем пользуются.

# ── учёт использования ─────────────────────────────────────────────────────
#
# Xray пишет строку в момент приёма, до сниффинга: в ней адрес из пула, не
# имя (`accepted tcp:198.19.14.63:443 [tproxy-in -> proxy]`). FakeDNS отдаёт
# домену один адрес до рестарта Xray -- раз за PID строим таблицу адрес ->
# имя. logqueries у dnsmasq отвергнут: раздувает буфер журнала (256 КБ) и
# чаще пишет во флеш. Подсети идут по настоящим адресам -- строка «(по IP)».

STAT=$LISTS/usage.tsv        # домен, обращений, последний раз

MAP=/tmp/byway-fakemap       # адрес -> домен, живёт в памяти как и сам Xray

MARK=/tmp/byway-statmark     # PID и метка времени последней обработанной строки

MAPPOS=/tmp/byway-fakemap.pos # докуда дошли, строя карту порциями

cmd_stat() {
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
    _mall=$(plain_domains "$(merged_domains)" | grep -c . || true); _mall=${_mall:-0}
    if [ "$_newmap" = 1 ] || [ "$_mpos" -lt "$_mall" ]; then
        _fre=$(fakeip_re)
        plain_domains "$(merged_domains)" |
        sed -n "$((_mpos + 1)),$((_mpos + _MSTEP))p" |
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
    _tmp=/tmp/byway-stat.tmp

    # Метка -- время Xray из начала строки (монотонно в журнале, у syslog
    # другой пояс). Ветка logread -- для конфига версии до 2026-09-05, где
    # обращения шли в syslog: без неё учёт обнулился бы до пересборки.
    if [ -s "$ACCESS" ]; then
        grep 'tproxy-in -> proxy' "$ACCESS" > "$_tmp" 2>/dev/null || true
        # Обрезаем сразу, оставляя хвост 50 строк: из него cmd_status берёт имя
        # работающего ключа. Двойного счёта нет: метка по последней учтённой.
        # cat, а не mv: движок держит файл открытым, подмена уведёт запись в
        # удалённый. Строки между grep и обрезкой теряются -- единицы.
        tail -50 "$ACCESS" > "$ACCESS.n" 2>/dev/null &&
            cat "$ACCESS.n" > "$ACCESS" && rm -f "$ACCESS.n" || true
    else
        logread -e xray 2>/dev/null |
          sed -n 's/.*xray[^:]*\[[0-9]*\]: //p' |
          grep 'tproxy-in -> proxy' > "$_tmp" || true
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
        ' "$_tmp" | sort > /tmp/byway-stat.new
        # Во флеш -- только если итог изменился.
        if ! cmp -s /tmp/byway-stat.new "$STAT"; then
            mv /tmp/byway-stat.new "$STAT"
            chmod 600 "$STAT" 2>/dev/null || true
        else
            rm -f /tmp/byway-stat.new
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
    [ -s "$STAT" ] || die "учёт пуст. Собирается задачей cron; вручную: byway stat"
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
