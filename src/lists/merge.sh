# Общие списки доменов и подсетей: свои + готовые наборы, склейка и чистка.

# Записи, не прошедшие проверку формы при сборке, откладываются сюда и
# называются вслух: молча выкинуть часть чужого списка -- оставить гадать,
# почему домен не работает.
BADLIST=/tmp/byway-bad-entries

# Записи списка, которые можно спросить у резолвера: без regexp:/keyword:
# (по ним nslookup не отвечает, и проба на одной такой строке объявила бы отказ
# исправному туннелю) и без префиксов domain:/full:. return 0 нужен: grep без
# совпадений даёт 1, а `_d=$(plain_domains …)` под set -e на нём молча умирает.
plain_domains() {
    grep -vE '^[[:space:]]*(//|#|$)' "$1" 2>/dev/null | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
      sed -e 's/^domain://' -e 's/^full://' |
      grep -E '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' |
      grep -E '\.[A-Za-z][A-Za-z]+$' || true
    return 0
}

# Свой список подсетей плюс подключённых пресетов и включённых направлений,
# одним файлом (отдаётся путь). Читают сборка конфига, набор nft и kill
# switch -- все обязаны видеть одно и то же, иначе подсеть из конфига, но не
# из правил ядра, снимает обвязку целиком.
# Кэш нужен, потому что потребителей семеро (сторож раз в 5 мин, health, top)
# и без него каждый гнал бы полную склейку и сортировку: на 200 000 записей
# 12 МБ в tmpfs, 288 раз в сутки. Годен, если слепок источников совпал,
# источники не новее файла и файл не новее слепка: /tmp общий, подложенный
# список решал бы, что идёт в туннель. Слепок нужен, потому что снятая в
# панели галочка пресета файлов не трогает.
merged_subnets() {
    _s=/tmp/byway-subnets-all.lst
    _st=$_s.$$
    # Слепок источников; свой файл не входит -- ловится временем правки.
    _ssig="$(u preset)|"
    for _rs2 in $(route_names); do
        [ "$(uci -q get "byway.$_rs2.enabled")" = "0" ] && continue
        _ssig="$_ssig$_rs2 "
    done
    if [ -f "$_s" ] && [ "$(cat "$_s.sig" 2>/dev/null || true)" = "$_ssig" ]; then
        _sold=0
        # Файл новее своего слепка -- трогали не мы (слепок пишется сразу после
        # файла): пересобрать.
        [ -n "$(find "$_s" -newer "$_s.sig" 2>/dev/null)" ] && _sold=1
        for _mf in "$LISTS/subnets.lst" \
                   $(for _p in $(u preset); do echo "$PRESETS_DIR/$_p.sub"; done) \
                   $(for _r in $(route_names); do echo "$ROUTES_DIR/$_r.lst"; done); do
            [ -f "$_mf" ] || continue
            if [ -n "$(find "$_mf" -newer "$_s" 2>/dev/null)" ]; then _sold=1; break; fi
        done
        if [ "$_sold" = 0 ]; then printf '%s' "$_s"; return 0; fi
    fi
    cat "$LISTS/subnets.lst" 2>/dev/null > "$_st"
    # Подсети включённых направлений тоже: иначе адресная половина не попадала
    # в набор nft, трафик шёл напрямую, а доменная работала («направление
    # работает через раз»).
    for _rn3 in $(route_names); do
        [ "$(uci -q get "byway.$_rn3.enabled")" = "0" ] && continue
        [ -f "$ROUTES_DIR/$_rn3.lst" ] && route_list "$ROUTES_DIR/$_rn3.lst" net >> "$_st"
    done
    for _pn3 in $(u preset); do
        _pfs=$PRESETS_DIR/$_pn3.sub
        [ -f "$_pfs" ] && cat "$_pfs" >> "$_st"
    done
    # Пробел внутри строки не вырезается (см. fetch_list): проверки формы
    # дальше нет, склеенная запись ушла бы прямо в маршрутизацию.
    grep -vE '^[[:space:]]*(//|#|$)' "$_st" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
      sort -u > "$_st.s"
    mv "$_st.s" "$_s"
    printf '%s' "$_ssig" > "$_s.sig" 2>/dev/null || true
    rm -f "$_st" 2>/dev/null || true
    printf '%s' "$_s"
}

# Свой список доменов плюс включённые направления и подключённые пресеты,
# без повторов; отдаётся путь. Кэш и слепок -- как у merged_subnets.
merged_domains() {
    # Собирается сбоку и встаёт на место одним mv: читателей семеро, а усечение
    # рабочего файла держало его неполным до конца (gen читает путь секундами
    # позже). Замок в gen защищает только сборку от сборки.
    _m=/tmp/byway-domains-all.lst
    _mt=$_m.$$
    # Слепок: подключённые пресеты и включённые направления; снятая в UCI
    # галочка файлов не трогает.
    _msig="$(u preset)|"
    for _rs in $(route_names); do
        [ "$(uci -q get "byway.$_rs.enabled")" = "0" ] && continue
        _msig="$_msig$_rs "
    done
    if [ -f "$_m" ] && [ "$(cat "$_m.sig" 2>/dev/null || true)" = "$_msig" ]; then
        _mold=0
        # Файл новее слепка -- трогали не мы.
        [ -n "$(find "$_m" -newer "$_m.sig" 2>/dev/null)" ] && _mold=1
        for _mf in "$LISTS/domains.lst" \
                   $(for _p in $(u preset); do echo "$PRESETS_DIR/$_p.lst"; done) \
                   $(for _r in $(route_names); do echo "$ROUTES_DIR/$_r.lst"; done); do
            [ -f "$_mf" ] || continue
            if [ -n "$(find "$_mf" -newer "$_m" 2>/dev/null)" ]; then _mold=1; break; fi
        done
        if [ "$_mold" = 0 ]; then printf '%s' "$_m"; return 0; fi
    fi
    cat "$LISTS/domains.lst" 2>/dev/null > "$_mt"
    # Домены включённых направлений тоже: без подставного адреса их трафик не
    # попадёт в перехват. Только заведённые, не весь каталог: файл удалённого
    # направления продолжал бы уводить домены.
    for _rn2 in $(route_names); do
        [ "$(uci -q get "byway.$_rn2.enabled")" = "0" ] && continue
        [ -f "$ROUTES_DIR/$_rn2.lst" ] && route_list "$ROUTES_DIR/$_rn2.lst" dom >> "$_mt"
    done
    # Только подключённые пресеты, не весь каталог: иначе снятая в панели
    # галочка не отключала скачанную копию.
    for _pn in $(u preset); do
        _pf=$PRESETS_DIR/$_pn.lst
        [ -f "$_pf" ] && cat "$_pf" >> "$_mt"
    done
    grep -vE '^[[:space:]]*(//|#|$)' "$_mt" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
      sort -u > "$_mt.s"
    # Черновик с $$ в имени: общий делили бы два сборщика.
    mv "$_mt.s" "$_m"
    printf '%s' "$_msig" > "$_m.sig" 2>/dev/null || true
    rm -f "$_mt" 2>/dev/null || true
    printf '%s' "$_m"
}
