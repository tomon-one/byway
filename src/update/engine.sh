# Ядро Xray (byway engine) -- в ucode (uc/engine.uc). Здесь замок и уборка
# рабочего каталога после Ctrl+C: ucode сигналов не ловит. На фазе «через
# память» (метка /var/run/byway-engine.ram) каталог и замок не трогаются: там
# архив прежнего ядра, а замену доводит до конца её процесс, не прерываемый
# INT и HUP.

engine_env() {
    BW_SELF=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0") \
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR \
    BW_BADLIST=$BADLIST BW_PROBE=$PROBE_DOMAIN BW_XRAY=${XRAY:-} BW_PKGFIX=$PKG_FIX \
    BW_XTESTED=$XRAY_TESTED BW_XSUMS=$XRAY_TESTED_SUMS BW_UCRUN=$BW_UCRUN "$@"
}

engine_clean() {
    [ -f /var/run/byway-engine.ram ] && return 0
    _ecd=$(cat /var/run/byway-engine.dir 2>/dev/null || true)
    [ -n "$_ecd" ] && rm -rf "$_ecd" 2>/dev/null
    rm -f /var/run/byway-engine.dir 2>/dev/null
    rm -rf /var/run/byway-engine.lock 2>/dev/null
    return 0
}

cmd_engine() {
    bw_uc_prep
    case "${1:-}" in
      ''|--check) engine_env bw_uc engine "$@"; return $? ;;
    esac
    take_lock /var/run/byway-engine.lock "$(_t 'замена движка')" || die "замена движка уже идёт"
    trap 'engine_clean' EXIT
    trap 'engine_clean; exit 130' INT
    trap 'engine_clean; exit 143' TERM
    _erc=0
    engine_env bw_uc engine "$@" || _erc=$?
    return "$_erc"
}
