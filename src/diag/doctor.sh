# byway doctor и report -- в ucode (uc/doctor.uc). Здесь пути и номера,
# которые пока живут в shell (обновление, списки, сторож), одним набором.

diag_uc() {
    BW_NUM=$BYWAY_NUM BW_OUT=$OUT BW_CONF=$CONF BW_LISTS=$LISTS \
    BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR BW_MERGED=$(merged_domains) \
    BW_SUBNETS=$(merged_subnets) BW_NEWVER=$NEWVER BW_RELNOTE=$RELNOTE \
    BW_UPFAIL=$UPFAIL BW_UPOK=$UPOK BW_BINSUM=$BINSUM BW_AUFAIL=$AUFAIL \
    BW_PKG_FIX=$PKG_FIX BW_ACCESS=$ACCESS BW_AULOG=$AULOG BW_PROBE=$PROBE_DOMAIN \
    BW_BADLIST=$BADLIST BW_WATCH_LOG=$WATCH_LOG bw_uc "$@"
}

cmd_doctor() {
    diag_uc doctor
}
