# Показ собранного конфига без секретов.

cmd_show() {
    [ -f "$OUT" ] || die "конфиг не собран, собрать: byway gen"
    sayf "%s — %s байт" "$OUT" "$(wc -c < "$OUT")"
    # Счётчики -- первыми: ради них команду зовут. Считаем по источнику: список
    # печатается в конфиг дважды (fakedns и маршрут), и счёт по «"domain:»
    # завышал вдвое, непостоянно (зависит от записей с префиксом).
    printf "$(_t '    доменов в правиле: %s\n')" "$(count_list "$(merged_domains)")"
    printf "$(_t '    подсетей:          %s\n')" "$(count_list "$(merged_subnets)")"
    grep -oE '"(tag|protocol|network|security|address|ipPool)": *"[^"]*"' "$OUT" |
      grep -viE 'uuid|id"' | sed 's/^/    /' | head -20
}
