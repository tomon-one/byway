# Справка и разбор команды.

_help() {
    _hc=$(_t "$1")
    _hp=$((18 - $(_len "$_hc"))); [ "$_hp" -lt 1 ] && _hp=1
    printf '  %s%s%s\n' "$_hc" "$(printf "%${_hp}s" '')" "$(_t "$2")"
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
  clear)  shift; cmd_clear "$@" ;;
  import) shift; cmd_import "$@" ;;
  version|--version|-v) echo "byway $BYWAY_VERSION" ;;
  watch)  cmd_watch ;;
  job)    shift; cmd_job "$@" ;;
  stat)   cmd_stat ;;
  top)    shift; cmd_top "$@" ;;
  nft)    cmd_nft ;;
  nftsig) cmd_nftsig ;;
  plumb)  shift; cmd_plumb "$@" ;;
  status) cmd_status "${2:-}" ;;
  "")
    # Без аргументов -- состояние и список команд.
    printf "$(_t 'byway %s — раздельное туннелирование через VPN\n\n')" "$BYWAY_VERSION"
    cmd_status 2>/dev/null || true
    # Построчно, не одним heredoc: перевод ищется по строке целиком.
    printf '
%s
' "$(_t 'Команды:')"
    _help 'menu' 'те же действия пунктами меню, без набора команд'
    _help 'status [--short]' 'что сейчас работает'
    _help 'health' 'быстрая проверка: служба, VPN, трафик, DNS'
    _help 'doctor' 'проверка окружения: модули, утилиты, место, конфликты'
    _help 'gen' 'пересобрать конфиг из настроек и списков'
    _help 'plumb on | off' 'включить или снять перехват трафика (nft, маршрут, DNS)'
    _help 'check [ссылка]' 'разобрать ключ и проверить конфиг, без соединений'
    _help 'probe [ссылка|--all]' 'проверить ключ отдельно, не трогая работающий туннель'
    _help 'sub АДРЕС' 'скачать подписку'
    _help 'presets' 'обновить готовые списки'
    _help 'top [N]' 'чем реально пользуются'
    _help 'update [--check|--force]' 'проверить, есть ли новая версия byway, и поставить её; --check — только проверить, --force — переустановить ту же'
    _help 'engine [ВЕРСИЯ|tested|newest|stable|restore|/tmp/ФАЙЛ]' 'есть ли обновление ядра Xray-core, и его замена; без аргумента — ещё и подробности'
    _help 'lang [ru|en]' 'язык вывода и панели; английский словарь докачивается при переключении'
    _help 'report [файл]' 'собрать отчёт для обращения, без ключа от VPN'
    _help 'export [файл] [--with-key]' 'выгрузить настройки без ключа от VPN; --with-key — с ключом'
    _help 'import ФАЙЛ' 'принять настройки из выгрузки'
    _help 'clear log|stat|all' 'очистить журнал состояния, статистику или то и другое'
    _help 'version' 'версия'
    ;;
  *)     printf "$(_f 'byway: неизвестная команда «%s». Список: byway\n' "$1")"; exit 1 ;;
esac
