# Часть byway на ucode (переход с shell по группам команд, план
# docs/plans/2026-10-16-improvements.md): программа -- в конце этого же файла,
# между метками #@uc-begin и #@uc-end.

# ucode читает программу только из файла, который можно перематывать:
# конвейер падает на 25.12 («Invalid seek»), /dev/fd нет на 22.03 (стенды
# 2026-10-16). Поэтому она вырезается в файл -- заново, когда сменился сам
# byway (inode, размер, время). /var/run, а не /var/run/byway: файл исполняет
# root, и каталог, куда пишет кто-то ещё, дал бы подменить программу.
# BW_SELF -- путь к byway: стенды подгружают его кусок под другим именем.
BW_SELF=${BW_SELF:-}
BW_UCF=/var/run/byway.uc
# Скомпилированная (ucode -c): разбор 260 КБ исходника стоит ~0,15 с на
# роутере при каждом вызове, байткод грузится впятеро быстрее (стенд
# 2026-10-18). Строгий режим (-S) задаётся при компиляции. Не скомпилировалась
# -- идёт исходник.
BW_UCC=/var/run/byway.ucc

bw_uc_prep() {
    [ -n "$BW_SELF" ] || BW_SELF=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    _ust=$(ls -lni "$BW_SELF" 2>/dev/null || true)
    if [ -z "$_ust" ] || [ "$(head -n 1 "$BW_UCF" 2>/dev/null)" != "// $_ust" ]; then
        # Без своей части файл -- не byway (стенд подгрузил кусок под чужим
        # именем): пустая программа молча отдала бы пустой вывод.
        grep -q '^#@uc-begin$' "$BW_SELF" 2>/dev/null ||
            die "часть byway на ucode не извлечена в /var/run"
        # Байткод прежней версии -- прочь ДО подмены исходника: параллельный
        # вызов увидел бы новый исходник и запустил старый байткод.
        rm -f "$BW_UCC" 2>/dev/null || true
        { printf '// %s\n' "$_ust"
          sed -n '/^#@uc-begin$/,/^#@uc-end$/{/^#@uc-/d;p}' "$BW_SELF"; } > "$BW_UCF.$$" &&
            mv "$BW_UCF.$$" "$BW_UCF" || {
                rm -f "$BW_UCF.$$" 2>/dev/null || true
                die "часть byway на ucode не извлечена в /var/run"
            }
        ucode -c -S -o "$BW_UCC.$$" "$BW_UCF" >/dev/null 2>&1 &&
            mv "$BW_UCC.$$" "$BW_UCC" 2>/dev/null || rm -f "$BW_UCC.$$" 2>/dev/null || true
    fi
    if [ -f "$BW_UCC" ]; then BW_UCRUN=$BW_UCC; else BW_UCRUN="-S $BW_UCF"; fi
}

bw_uc() {
    bw_uc_prep
    # shellcheck disable=SC2086
    BW_VERSION=$BYWAY_VERSION BW_LANG=$BW_LANG ucode $BW_UCRUN "$@"
}
