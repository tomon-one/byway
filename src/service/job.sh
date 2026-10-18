# Фоновые задачи панели (обновление, ядро, проба ключа): отвязаны от сессии, ход в журнале.

# Фоновая задача панели: обновление и замена ядра идут минуты, запрос панели
# живёт секунды. `job update|engine [ВЕРСИЯ]|probe [ССЫЛКА|--all]` запускает и
# сразу отвечает, `job log` отдаёт ход (конец -- строка «== конец»). Одна
# задача за раз. Проба -- ~6 с на ключ, при нескольких ключах дольше запроса.
JOBLOG=/tmp/byway-job.log

JOBPID=/var/run/byway-job.pid

cmd_job() {
    case "${1:-}" in
      update|engine|probe)
        if [ -f "$JOBPID" ] && kill -0 "$(cat "$JOBPID" 2>/dev/null)" 2>/dev/null; then
            die "уже идёт другая задача — дождаться её конца"
        fi
        case "$1" in
          update) set -- update ;;
          engine) set -- engine "${2:-tested}" ;;
          *) if [ -n "${2:-}" ]; then set -- probe "$2"; else set -- probe; fi ;;
        esac
        : > "$JOBLOG"
        _js=""; command -v setsid >/dev/null 2>&1 && _js=setsid
        $_js "$0" job run "$@" </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$JOBPID"
        # Ссылку ключа не печатаем: ответ уходит в панель.
        if [ "$1" = probe ]; then sayf "задача запущена: byway %s" probe
        else sayf "задача запущена: byway %s" "$*"; fi
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
      *) die "byway job update|engine [ВЕРСИЯ]|probe [ССЫЛКА|--all]|log" ;;
    esac
}
