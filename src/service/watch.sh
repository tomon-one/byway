# Сторож (раз в 5 минут) и pulse (раз в минуту) из cron -- в ucode
# (uc/watch.uc). Здесь путь журнала состояния -- его читают doctor и
# report.

# Журнал состояния: отвалы и перезапуски, только при изменении.
WATCH_LOG=$LISTS/health.log

watch_env() {
    BW_SELF=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0") \
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR \
    BW_BADLIST=$BADLIST BW_ACCESS=$ACCESS BW_NUM=$BYWAY_NUM \
    BW_REPO=$BYWAY_REPO BW_WATCH_LOG=$WATCH_LOG "$@"
}

cmd_watch() { watch_env bw_uc watch; }

cmd_pulse() { watch_env bw_uc pulse; }
