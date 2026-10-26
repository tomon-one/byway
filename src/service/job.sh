# Фоновые задачи панели (обновление, ядро, проба ключа): отвязаны от сессии, ход в журнале.

# Фоновая задача панели: обновление и замена ядра идут минуты, запрос панели
# живёт секунды. `job update|engine [ВЕРСИЯ]|probe [ССЫЛКА|--all]|gen|presets|restart|reload|import` запускает и
# сразу отвечает, `job log` отдаёт ход (конец -- строка «== конец»). Одна
# задача за раз. Проба -- ~6 с на ключ, при нескольких ключах дольше запроса.
JOBLOG=/var/run/byway-job.log

JOBPID=/var/run/byway-job.pid
# Код возврата задачи: панель судит по нему, а не по тексту журнала.
JOBRC=/var/run/byway-job.rc
JOBLCK=/var/run/byway-job.lock

# Сборку, готовые списки и перезапуск службы панель тоже зовёт задачей: rpcd
# убивает свой вызов через 30 секунд, и restart, оборванный между stop и start,
# оставлял дом без DNS до перезагрузки (Ф9, п2-8). Задача отвязана от сессии.
cmd_job() {
    case "${1:-}" in
      update|engine|probe|gen|presets|restart|reload|import)
        # Проверка и захват -- одним mkdir: «pid жив?» и запись pid порознь
        # пропускали двоих в одну долю секунды (Ф9, п2-2).
        # Хозяин пишет pid в замок сразу после mkdir; пустой -- перечитать через
        # секунду. Брошенный (pid мёртв) забирается переименованием: оно
        # удаётся одному (как take_lock).
        if ! mkdir "$JOBLCK" 2>/dev/null; then
            _jp=$(cat "$JOBLCK/pid" 2>/dev/null || true)
            [ -n "$_jp" ] || { sleep 1; _jp=$(cat "$JOBLCK/pid" 2>/dev/null || true); }
            if [ -n "$_jp" ] && kill -0 "$_jp" 2>/dev/null; then
                die "уже идёт другая задача — дождаться её конца"
            fi
            { [ "$(cat "$JOBLCK/pid" 2>/dev/null || true)" = "$_jp" ] &&
              mv "$JOBLCK" "$JOBLCK.gone.$$" 2>/dev/null && rm -rf "$JOBLCK.gone.$$" &&
              mkdir "$JOBLCK" 2>/dev/null; } || die "уже идёт другая задача — дождаться её конца"
        fi
        echo $$ > "$JOBLCK/pid"
        case "$1" in
          update) if [ "${2:-}" = --check ]; then set -- update --check; else set -- update; fi ;;
          engine) set -- engine "${2:-tested}" ;;
          # Ссылка ключа -- окружением: аргументом она висела в cmdline трёх
          # процессов root на всё время пробы (Ф9, п1-10).
          probe) case "${2:-}" in
                   '') set -- probe ;;
                   -*) set -- probe "$2" ;;
                   *) BW_PROBE_LINK=$2; export BW_PROBE_LINK; set -- probe ;;
                 esac ;;
          # Приём из панели: файл кладёт панель, путь -- только этот.
          import) if [ "${2:-}" = --no-key ]; then set -- import /var/run/byway-import.txt --no-key
                  else set -- import /var/run/byway-import.txt; fi ;;
          *) set -- "$1" ;;
        esac
        rm -f "$JOBRC" 2>/dev/null || true
        : > "$JOBLOG"
        _js=""; command -v setsid >/dev/null 2>&1 && _js=setsid
        $_js "$0" job run "$@" </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$JOBPID"
        printf '%s\n' "$!" > "$JOBLCK/pid"
        # Ссылку ключа не печатаем: ответ уходит в панель.
        if [ "$1" = probe ]; then sayf "задача запущена: byway %s" probe
        else sayf "задача запущена: byway %s" "$*"; fi
        ;;
      run)
        # Прямо в файл, без конвейера: sed в конвейере пишет блоками, ход был
        # бы виден только в конце. Цвета снимает `job log`.
        # Под set -e упавшая команда обрывала бы обёртку: ни «== конец», ни
        # снятого PID (Ф9, п4-51). Код ловится if-ом.
        shift
        _jr=0
        {
            case "$1" in
              restart|reload) if /etc/init.d/byway "$1" 2>&1; then :; else _jr=$?; fi ;;
              # Скачать -- ещё не применить: файлы в работу переносит reload.
              presets) if "$0" presets 2>&1; then :; else _jr=$?; fi
                       /etc/init.d/byway reload 2>&1 || true ;;
              *) if "$0" "$@" 2>&1; then :; else _jr=$?; fi ;;
            esac
            printf '\n== %s\n' "$(_t конец)"
        } > "$JOBLOG"
        printf '%s\n' "$_jr" > "$JOBRC" 2>/dev/null || true
        rm -f "$JOBPID" 2>/dev/null || true
        rm -rf "$JOBLCK" 2>/dev/null || true
        ;;
      log)
        sed "s/$(printf '\033')\[[0-9;]*m//g" "$JOBLOG" 2>/dev/null || true
        # Код 3 -- «ещё идёт»: панель судит по коду, а не по тексту. Конец --
        # 0, если задача удалась, иначе 1.
        if [ -f "$JOBPID" ] && kill -0 "$(cat "$JOBPID" 2>/dev/null)" 2>/dev/null; then
            printf '%s\n' "$(_t '… идёт')"
            return 3
        fi
        [ "$(cat "$JOBRC" 2>/dev/null || echo 0)" = 0 ] || return 1
        ;;
      *) die "byway job update|engine [ВЕРСИЯ]|probe [ССЫЛКА|--all]|gen|presets|restart|reload|import [--no-key]|log" ;;
    esac
}
