# Показ собранного конфига без секретов -- в ucode (uc/probe.uc, cmd_show);
# счётчики -- по объединённым спискам, их склейка пока на shell.

cmd_show() {
    BW_OUT=$OUT BW_MERGED=$(merged_domains) BW_SUBNETS=$(merged_subnets) bw_uc show
}
