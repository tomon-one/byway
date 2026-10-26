# byway report: отчёт для обращения, адреса и имена вымараны, ключа нет.
# Отчёт собирает ucode (uc/doctor.uc, cmd_report); здесь -- запись в файл.

cmd_report() {
    _out=${1:-}
    # Флаг и каталог файлом не считаются: `report --foo` и `report /tmp`
    # отвечали «записан», а отчёт ложился в /tmp/tmp.new.PID (Ф9, п3-20).
    case "$_out" in -*) die "byway report [файл]" ;; esac
    if [ -n "$_out" ]; then
        [ -d "$_out" ] && dief "это каталог, нужен файл: %s" "$_out"
        path_ok "$_out" || dief "сюда писать нельзя: %s" "$_out"
        # Сразу под 600, не chmod после: существующий файл сохраняет прежние
        # права.
        ( umask 077; diag_uc report > "$_out.new.$$" 2>&1 )
        mv "$_out.new.$$" "$_out" || { rm -f "$_out.new.$$"; dief "не записан: %s" "$_out"; }
        sayf "отчёт записан: %s" "$_out"
        say "  секреты убраны, но перед отправкой файл стоит просмотреть"
    else
        diag_uc report
    fi
}
