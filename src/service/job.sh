# Фоновые задачи панели (обновление, ядро): отвязаны от сессии, ход в журнале.

# Фоновая задача панели: обновление и замена ядра идут минуты, запрос панели
# живёт секунды. `job update|engine [ВЕРСИЯ]` запускает и сразу отвечает,
# `job log` отдаёт ход (конец -- строка «== конец»). Одна задача за раз.
JOBLOG=/tmp/byway-job.log

JOBPID=/var/run/byway-job.pid

cmd_job() {
    case "${1:-}" in
      update|engine)
        if [ -f "$JOBPID" ] && kill -0 "$(cat "$JOBPID" 2>/dev/null)" 2>/dev/null; then
            die "уже идёт другая задача — дождаться её конца"
        fi
        if [ "$1" = update ]; then set -- update
        else set -- engine "${2:-tested}"; fi
        : > "$JOBLOG"
        _js=""; command -v setsid >/dev/null 2>&1 && _js=setsid
        $_js "$0" job run "$@" </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$JOBPID"
        sayf "задача запущена: byway %s" "$*"
        ;;
      run)
        # Прямо в файл, без конвейера: sed в конвейере пишет блоками, ход был
        # бы виден только в конце. Цвета снимает `job log`.
        shift
        { "$0" "$@" 2>&1; printf '\n== %s\n' "$(_t конец)"; } > "$JOBLOG"
        rm -f "$JOBPID" 2>/dev/null || true
        ;;
      log)
        sed "s/$(printf '\033')\[[0-9;]*m//g" "$JOBLOG" 2>/dev/null || true
        # Код 3 -- «ещё идёт»: панель судит по коду, а не по тексту.
        if [ -f "$JOBPID" ] && kill -0 "$(cat "$JOBPID" 2>/dev/null)" 2>/dev/null; then
            printf '%s\n' "$(_t '… идёт')"
            return 3
        fi
        ;;
      *) die "byway job update|engine [ВЕРСИЯ]|log" ;;
    esac
}
