# byway health: служба, VPN, трафик, DNS строками «ключ<таб>состояние<таб>
# подробность» -- в ucode (uc/status.uc, cmd_health).

# В терминале -- для человека (точки цветом и что делать, uc/cli.uc); не в
# терминал (панель, скрипты) -- прежние строки «проверка<TAB>состояние<TAB>пояснение».
cmd_health() {
    if [ -t 1 ]; then
        BW_OUT=$OUT BW_PROBE=$PROBE_DOMAIN bw_uc health | cli_uc hfmt
    else
        BW_OUT=$OUT BW_PROBE=$PROBE_DOMAIN bw_uc health
    fi
}
