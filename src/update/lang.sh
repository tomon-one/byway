# Словари перевода для консоли и панели (byway lang) -- в ucode (uc/update.uc).

cmd_lang() {
    BW_LISTS=$LISTS BW_REPO=$BYWAY_REPO BW_NUM=$BYWAY_NUM BW_PUBKEY=$BYWAY_PUBKEY \
        bw_uc lang "$@"
}
