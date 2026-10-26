# Обновление самого byway -- в ucode (uc/update.uc). Здесь пути меток проверки
# обновлений и автообновления, которые читают status и doctor (в ucode, UP_*,
# пути те же; прочие метки -- UP_MARK, архивы отката, .au-try, .newver-seen --
# знает только ucode).

# Автопроверка новой версии. Метки в /var/run: ежедневная запись во флеш не
# нужна, а после перезагрузки проверка лишний раз безвредна.
UPOK=/var/run/byway-upcheck-ok     # время последней проверки, дошедшей до GitHub
UPFAIL=/var/run/byway-upcheck-fail # код ответа последней неудачной проверки
NEWVER=/var/run/byway-newver      # номер найденной версии, если она новее

RELNOTE=/var/run/byway-relnote    # первая строка описания выпуска

AULOG=/var/run/byway-autoupdate   # чем кончилось ночное обновление

BINSUM=/etc/byway/.binmd5     # сумма выложенной версии (правку руками не трогаем)

AUFAIL=/etc/byway/.au-failed  # выпуск, который уже не поднялся: второй раз не ставим

update_env() {
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR \
    BW_BADLIST=$BADLIST BW_NUM=$BYWAY_NUM BW_REPO=$BYWAY_REPO BW_PUBKEY=$BYWAY_PUBKEY \
    BW_PROBE=$PROBE_DOMAIN "$@"
}

# ucode сигналов не ловит: рабочий каталог после Ctrl+C убирает обёртка (путь
# -- в /var/run/byway-update.dir). Код выхода -- как у ucode (ночное
# обновление судит по нему).
# Идёт установка (метка byway-update.inst) -- каталог не трогаем: установщик
# с игнором сигналов доводит её из него сам.
cmd_update() {
    trap '[ -f /var/run/byway-update.inst ] || { _ud=$(cat /var/run/byway-update.dir 2>/dev/null); [ -n "$_ud" ] && rm -rf "$_ud"; rm -f /var/run/byway-update.dir; }; exit 130' INT
    trap '[ -f /var/run/byway-update.inst ] || { _ud=$(cat /var/run/byway-update.dir 2>/dev/null); [ -n "$_ud" ] && rm -rf "$_ud"; rm -f /var/run/byway-update.dir; }; exit 143' TERM
    # Одно обновление за раз: консоль, панель и ночное шли разом, и копия для
    # отката получала уже новую версию (Ф9, п2-2). --check ничего не ставит.
    case " $* " in
      *" --check "*) ;;
      *) take_lock /var/run/byway-update.lock "$(_t 'обновление')" || die "обновление уже идёт"
         trap 'rm -rf /var/run/byway-update.lock 2>/dev/null; true' EXIT ;;
    esac
    _urc=0
    update_env bw_uc update "$@" || _urc=$?
    trap - INT TERM
    return "$_urc"
}
