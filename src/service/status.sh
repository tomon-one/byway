# byway status: что поднято -- в ucode (uc/status.uc). Здесь пути и номера,
# которые пока живут в shell. --short: панели нужна только голова, склейка
# списков ей не нужна.

cmd_status() {
    _sm=""
    [ "${1:-}" = "--short" ] || _sm=$(merged_domains)
    BW_OUT=$OUT BW_ACCESS=$ACCESS BW_MERGED=$_sm BW_NUM=$BYWAY_NUM \
    BW_AULOG=$AULOG BW_NEWVER=$NEWVER BW_RELNOTE=$RELNOTE bw_uc status "$@"
}
