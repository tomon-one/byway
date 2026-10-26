# byway doctor и report -- в ucode (uc/doctor.uc). Здесь пути и номера,
# которые знает shell (метки обновления, списки, журнал сторожа), одним набором.

diag_uc() {
    BW_NUM=$BYWAY_NUM BW_OUT=$OUT BW_CONF=$CONF BW_LISTS=$LISTS \
    BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR BW_MERGED=$(merged_domains) \
    BW_SUBNETS=$(merged_subnets) BW_NEWVER=$NEWVER BW_RELNOTE=$RELNOTE \
    BW_UPFAIL=$UPFAIL BW_UPOK=$UPOK BW_BINSUM=$BINSUM BW_AUFAIL=$AUFAIL \
    BW_PKG_FIX=$PKG_FIX BW_ACCESS=$ACCESS BW_AULOG=$AULOG BW_PROBE=$PROBE_DOMAIN \
    BW_BADLIST=$BADLIST BW_WATCH_LOG=$WATCH_LOG bw_uc "$@"
}

cmd_doctor() {
    # В терминале -- подсказки по словам в 78 знаков (uc/doctor.uc): stty в
    # busybox OpenWrt не собран, ширину экрана не узнать.
    _dw=; [ -t 1 ] && _dw=78
    BW_WRAP=${BW_WRAP:-$_dw} diag_uc doctor "$@"
}
