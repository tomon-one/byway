# Словари перевода для консоли и панели (byway lang).

# Словари лежат только выбранного языка (~73 КБ консоли и ~38 КБ панели на
# флеше для en; у ru файлов нет, ключи и есть русский текст). Английский
# докачивается с ТЕГА текущей версии, не с main: иначе ключи разойдутся с
# кодом. Панель зовёт эту же команду при смене языка.
PANEL_LANG=/www/luci-static/resources/byway/lang.js

# Полный ли словарь панели: у урезанного строк перевода нет вовсе.
lang_panel_full() { grep -q '"Служба": "Service"' "$PANEL_LANG" 2>/dev/null; }

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
        _lt=/tmp/byway-lang.$$
        rm -rf "$_lt" 2>/dev/null || true
        mkdir -p "$_lt" "$LANGDIR"
        _lb="https://raw.githubusercontent.com/$BYWAY_REPO/v$BYWAY_NUM"
        if [ ! -s "$LANGDIR/en.tsv" ]; then
            say "загрузка английского словаря"
            if ! eng_dl --max-time 30 -o "$_lt/en.tsv" "$_lb/lang/en.tsv" ||
               ! grep -q '	' "$_lt/en.tsv" 2>/dev/null; then
                rm -rf "$_lt"; eng_nonet
                die "словарь не скачался — язык не переключён"
            fi
            mv "$_lt/en.tsv" "$LANGDIR/en.tsv" && chmod 644 "$LANGDIR/en.tsv"
        fi
        if [ -f "$PANEL_LANG" ] && ! lang_panel_full; then
            say "загрузка английского словаря панели"
            if ! eng_dl --max-time 30 -o "$_lt/lang.js" "$_lb/luci/lang.js" ||
               ! grep -q '"Служба": "Service"' "$_lt/lang.js" 2>/dev/null; then
                rm -rf "$_lt"; eng_nonet
                die "словарь панели не скачался — язык не переключён"
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
