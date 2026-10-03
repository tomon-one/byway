# Словари перевода для консоли и панели (byway lang).

# Словари лежат только выбранного языка (~73 КБ консоли и ~38 КБ панели на
# флеше для en; у ru файлов нет, ключи и есть русский текст). Английский
# докачивается с ТЕГА текущей версии, не с main: иначе ключи разойдутся с
# кодом. Панель зовёт эту же команду при смене языка.
PANEL_LANG=/www/luci-static/resources/byway/lang.js

# Полный ли словарь панели: у урезанного строк перевода нет вовсе.
lang_panel_full() { grep -q '"Служба": "Service"' "$PANEL_LANG" 2>/dev/null; }

# Не вышло переключить на английский: настройка языка, которую уже записала
# панель, возвращается на русский (словаря нет) -- иначе панель показывала бы
# «язык остался прежним» при lang=en в настройках.
lang_back() {
    [ -s "$LANGDIR/en.tsv" ] && return 0
    [ "$(u lang)" = en ] || return 0
    uci set byway.main.lang=ru 2>/dev/null && uci commit byway 2>/dev/null || true
}

cmd_lang() {
    _lw=${1:-}
    case "$_lw" in
      '') sayf "язык: %s" "$BW_LANG"
          say "  сменить: byway lang ru | en"
          return 0 ;;
      ru|en) ;;
      *) dief "непонятный язык «%s» — нужен ru или en" "$_lw" ;;
    esac
    if [ "$_lw" = en ]; then
        _lt=$(mktemp -d /tmp/byway-lang.XXXXXX) || die "не создать рабочий каталог в /tmp"
        mkdir -p "$LANGDIR"
        # refs/tags: ветка с тем же именем, что тег, иначе перебила бы его.
        _lb="https://raw.githubusercontent.com/$BYWAY_REPO/refs/tags/v$BYWAY_NUM"
        # Словари -- строки форматов printf, которые byway печатает от root:
        # берутся только сверенными с подписанным списком сумм выпуска.
        _lnv=0
        if [ "${BYWAY_NO_VERIFY:-0}" = 1 ]; then
            warn "BYWAY_NO_VERIFY=1: подпись выпуска не проверяется"
        else
            _lsr=0; rel_sums "$BYWAY_NUM" "$_lt" || _lsr=$?
            case "$_lsr" in
              0) _lnv=1 ;;
              1) rm -rf "$_lt"
                 lang_back
                 die "словарь не сверить с подписью выпуска — язык не переключён; без проверки: BYWAY_NO_VERIFY=1 byway lang en" ;;
              *) rm -rf "$_lt"
                 lang_back
                 die "подпись выпуска не сошлась — язык не переключён" ;;
            esac
        fi
        if [ ! -s "$LANGDIR/en.tsv" ]; then
            say "загрузка английского словаря"
            if ! eng_dl --max-time 30 -o "$_lt/en.tsv" "$_lb/lang/en.tsv" ||
               ! grep -q '	' "$_lt/en.tsv" 2>/dev/null; then
                rm -rf "$_lt"; eng_nonet
                lang_back
                die "словарь не скачался — язык не переключён"
            fi
            if [ "$_lnv" = 1 ] && ! rel_sum_ok "$_lt/en.tsv" lang/en.tsv "$_lt/SHA256SUMS"; then
                rm -rf "$_lt"
                lang_back
                die "словарь не совпал с подписанным выпуском — язык не переключён"
            fi
            mv "$_lt/en.tsv" "$LANGDIR/en.tsv" && chmod 644 "$LANGDIR/en.tsv"
        fi
        if [ -f "$PANEL_LANG" ] && ! lang_panel_full; then
            say "загрузка английского словаря панели"
            if ! eng_dl --max-time 30 -o "$_lt/lang.js" "$_lb/luci/lang.js" ||
               ! grep -q '"Служба": "Service"' "$_lt/lang.js" 2>/dev/null; then
                rm -rf "$_lt"; eng_nonet
                lang_back
                die "словарь панели не скачался — язык не переключён"
            fi
            if [ "$_lnv" = 1 ] && ! rel_sum_ok "$_lt/lang.js" luci/lang.js "$_lt/SHA256SUMS"; then
                rm -rf "$_lt"
                lang_back
                die "словарь не совпал с подписанным выпуском — язык не переключён"
            fi
            mv "$_lt/lang.js" "$PANEL_LANG" && chmod 644 "$PANEL_LANG"
        fi
        rm -rf "$_lt" 2>/dev/null || true
    else
        rm -f "$LANGDIR/en.tsv" 2>/dev/null || true
        # Строки перевода в lang.js -- ровно те, что с двух табов и кавычки.
        if [ -f "$PANEL_LANG" ] && lang_panel_full; then
            _tb=$(printf '\t')
            sed "/^$_tb$_tb\"/d" "$PANEL_LANG" > "$PANEL_LANG.new" &&
                mv "$PANEL_LANG.new" "$PANEL_LANG" && chmod 644 "$PANEL_LANG"
        fi
    fi
    if [ "$(u lang)" != "$_lw" ]; then
        uci set byway.main.lang="$_lw" && uci commit byway
    fi
    BW_LANG=$_lw
    sayf "язык: %s" "$_lw"
}
