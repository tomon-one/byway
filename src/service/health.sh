# byway health: служба, VPN, трафик, DNS строками «ключ<таб>состояние<таб>
# подробность» -- в ucode (uc/status.uc, cmd_health).

cmd_health() {
    BW_OUT=$OUT BW_PROBE=$PROBE_DOMAIN bw_uc health
}
