# Обновление самого byway -- в ucode (uc/update.uc). Здесь пути меток проверки
# обновлений и автообновления: их читают status и doctor (UP_* в ucode -- те же).

# Автопроверка новой версии. Метки в /tmp: ежедневная запись во флеш не
# нужна, а после перезагрузки проверка лишний раз безвредна.
UPMARK=/tmp/byway-upcheck     # когда спрашивали в прошлый раз

UPOK=/tmp/byway-upcheck-ok     # время последней проверки, дошедшей до GitHub
UPFAIL=/tmp/byway-upcheck-fail # код ответа последней неудачной проверки
NEWVER=/tmp/byway-newver      # номер найденной версии, если она новее

RELNOTE=/tmp/byway-relnote    # первая строка описания выпуска

AULOG=/tmp/byway-autoupdate   # чем кончилось ночное обновление

PREVBIN=/etc/byway/byway.prev # прежняя копия одного скрипта (до 0.3.0), удаляется
PREVSET=/etc/byway/prev.tgz   # прежняя версия целиком (скрипт, init, панель) для отката

AUTRY=/etc/byway/.au-try      # когда пробовали обновиться; флеш

SEENF=/etc/byway/.newver-seen # версия и когда увидели впервые; флеш

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
cmd_update() {
    trap '_ud=$(cat /var/run/byway-update.dir 2>/dev/null); [ -n "$_ud" ] && rm -rf "$_ud"; rm -f /var/run/byway-update.dir; exit 130' INT
    trap '_ud=$(cat /var/run/byway-update.dir 2>/dev/null); [ -n "$_ud" ] && rm -rf "$_ud"; rm -f /var/run/byway-update.dir; exit 143' TERM
    _urc=0
    update_env bw_uc update "$@" || _urc=$?
    trap - INT TERM
    return "$_urc"
}
