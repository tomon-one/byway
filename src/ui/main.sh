# Разбор команды.

# Команды для человека (сводка, справка, ключ, списки) -- в ucode (uc/cli.uc);
# самого byway они зовут как отдельный процесс (BW_SELF).
cli_uc() {
    BW_SELF=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0") \
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR \
    BW_BADLIST=$BADLIST bw_uc "$@"
}

# Потолок журнала обращений. Без него потеря cron-задач растит журнал в
# памяти без предела (~18 МБ в сутки), а когда кончится tmpfs, dnsmasq и
# procd не смогут писать в /tmp. Цена -- один `wc -c` на команду.
if [ -s "$ACCESS" ] &&
   [ "$(wc -c < "$ACCESS" 2>/dev/null || echo 0)" -gt 4194304 ]; then
    : > "$ACCESS"
    logt "журнал обращений перевалил 4 МБ и обрезан -- задачи cron на месте?"
fi

case "${1:-}" in
  gen)   cmd_gen ;;
  show)  cmd_show ;;
  probe) shift; cmd_probe "$@" ;;
  check)  shift; cmd_check "$@" ;;
  sub)    shift; cmd_sub "$@" ;;
  presets) cmd_presets ;;
  health) cmd_health ;;
  doctor) cmd_doctor ;;
  menu|меню) cmd_menu ;;
  export) shift; cmd_export "$@" ;;
  report) shift; cmd_report "$@" ;;
  update) shift; cmd_update "$@" ;;
  engine) shift; cmd_engine "$@" ;;
  lang)   shift; cmd_lang "$@" ;;
  # Служебная: перевод сообщения службы (init-скрипт), формат и доводы printf.
  xlat)   shift; bw_uc xlat "$@" ;;
  clear)  shift; cmd_clear "$@" ;;
  import) shift; cmd_import "$@" ;;
  version|--version|-v) bw_uc version ;;
  watch)  cmd_watch ;;
  pulse)  cmd_pulse ;;
  job)    shift; cmd_job "$@" ;;
  stat)   cmd_stat ;;
  top)    shift; cmd_top "$@" ;;
  nft)    cmd_nft ;;
  nftsig) cmd_nftsig ;;
  plumb)  shift; cmd_plumb "$@" ;;
  status) cmd_status "${2:-}" ;;
  key)    shift; cli_uc key "$@" ;;
  on)     cli_uc onoff 1 ;;
  off)    cli_uc onoff ;;
  add)    shift; cli_uc add "$@" ;;
  del)    shift; cli_uc del "$@" ;;
  # Без доводов -- сводка как «Основное» в панели; help -- все команды.
  "")     cli_uc home ;;
  help|--help|-h) cli_uc help ;;
  *)     printf "$(_f 'byway: неизвестная команда «%s». Все команды: byway help\n' "$1")"; exit 1 ;;
esac
