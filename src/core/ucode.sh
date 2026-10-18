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

bw_uc_prep() {
    [ -n "$BW_SELF" ] || BW_SELF=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    _ust=$(ls -lni "$BW_SELF" 2>/dev/null || true)
    if [ -z "$_ust" ] || [ "$(head -n 1 "$BW_UCF" 2>/dev/null)" != "// $_ust" ]; then
        # Без своей части файл -- не byway (стенд подгрузил кусок под чужим
        # именем): пустая программа молча отдала бы пустой вывод.
        grep -q '^#@uc-begin$' "$BW_SELF" 2>/dev/null ||
            die "часть byway на ucode не извлечена в /var/run"
        { printf '// %s\n' "$_ust"
          sed -n '/^#@uc-begin$/,/^#@uc-end$/{/^#@uc-/d;p}' "$BW_SELF"; } > "$BW_UCF.$$" &&
            mv "$BW_UCF.$$" "$BW_UCF" || {
                rm -f "$BW_UCF.$$" 2>/dev/null || true
                die "часть byway на ucode не извлечена в /var/run"
            }
    fi
}

bw_uc() {
    bw_uc_prep
    BW_VERSION=$BYWAY_VERSION BW_LANG=$BW_LANG ucode -S "$BW_UCF" "$@"
}
