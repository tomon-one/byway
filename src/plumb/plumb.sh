# Перехват (nft, маршрут, dnsmasq, запрет «не пускать мимо VPN») -- в ucode
# (uc/plumb.uc). Здесь замок и снятие по сигналу, имена, которые читают
# сторож и проверки (service/*), и обёртки команд.

TABLE=byway
RT_TABLE=100
BLOCK_MARK=/tmp/byway-blocked
DNSSEC="dhcp.@dnsmasq[0]"
# Умолчание пула IPv6 для конфига движка -- константа Xray (fakedns.go).
POOL6_DEF="fc00::/18"

# Образец ip rule по fwmark и таблице (сторож считает правила). Конец
# закреплён: «lookup 100» совпадает и с «lookup 1000».
rule_re() {
    _rm=$(eff_mark)
    printf 'fwmark %s(/%s)?[[:space:]]+lookup %s([[:space:]]|$)' "$_rm" "$_rm" "$RT_TABLE"
}

plumb_env() {
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR \
    BW_BADLIST=$BADLIST BW_PKGFIX=$PKG_FIX BW_VERSION=$BYWAY_VERSION BW_LANG=$BW_LANG "$@"
}

# cmd_plumb on|off|close -- единственный вход для службы и сторожа, под
# замком: у перехвата пять хозяев (старт службы, её фоновый цикл до 65 с,
# reload, сторож из cron, консоль). return, а не die: cmd_watch зовёт через
# `if`, exit оборвал бы весь прогон сторожа.
cmd_plumb() {
    _plock=/var/run/byway-plumb.lock
    take_lock "$_plock" "$(_t 'настройка перехвата')" || {
        warn "перехват уже настраивается другим запуском -- пропущено"
        return 1
    }
    # ucode -- фоном, и shell ждёт его через wait: по INT/TERM (stop_service
    # убивает идущий подъём, чтобы тот не ставил перехват поверх снятого)
    # ловушка гасит его. Ждал бы shell ucode напрямую -- ловушка сработала бы
    # только после конца подъёма.
    _ppid=""
    trap 'rm -rf "$_plock" 2>/dev/null; true' EXIT
    trap '[ -n "$_ppid" ] && kill "$_ppid" 2>/dev/null; rm -rf "$_plock" 2>/dev/null; exit 143' INT TERM
    # Простой командой, не через plumb_env: фоном функция идёт подоболочкой,
    # $! -- её номер, и kill оставлял ucode доделывать подъём.
    bw_uc_prep
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR \
    BW_BADLIST=$BADLIST BW_PKGFIX=$PKG_FIX BW_VERSION=$BYWAY_VERSION BW_LANG=$BW_LANG \
        ucode -S "$BW_UCF" plumb "$@" &
    _ppid=$!
    _prc=0
    wait "$_ppid" || _prc=$?
    _ppid=""
    rm -rf "$_plock" 2>/dev/null || true
    return "$_prc"
}

# Снять запрет (сторож: служба выключена).
block_off() { plumb_env bw_uc plumb unblock; }

cmd_nft() { plumb_env bw_uc nft; }

# Слепок обвязки для init-скрипта (reload сверяет его).
cmd_nftsig() { plumb_env bw_uc nftsig; }
