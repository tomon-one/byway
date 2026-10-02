# Аутбаунд Xray из разобранного ключа (N_*).

# Блок аутбаунда под свой протокол.
build_outbound() {
    case "$N_PROTO" in
      vless)
        OUTBOUND="\"protocol\": \"vless\", \"settings\": { \"vnext\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT, \"users\": [ { \"id\": \"$N_UUID\", \"encryption\": \"${N_ENC:-none}\"$FLOWJ } ] } ] }" ;;
      hysteria)
        OUTBOUND="\"protocol\": \"hysteria\", \"settings\": { \"version\": 2, \"address\": \"$N_HOST\", \"port\": $N_PORT }" ;;
      wireguard)
        # address -- список через запятую, уже сверенный образцом в parse_uc.
        _wa=$(printf '%s' "$N_WGADDR" | sed 's/,/", "/g')
        _wp="\"publicKey\": \"$N_WGPUB\", \"endpoint\": \"$N_HOST:$N_PORT\""
        if [ -n "$N_WGPSK" ]; then _wp="$_wp, \"preSharedKey\": \"$N_WGPSK\""; fi
        if [ -n "$N_WGKA" ]; then _wp="$_wp, \"keepAlive\": $N_WGKA"; fi
        _wo=""
        if [ -n "$N_WGMTU" ]; then _wo=", \"mtu\": $N_WGMTU"; fi
        if [ -n "$N_WGRES" ]; then _wo="$_wo, \"reserved\": [ $N_WGRES ]"; fi
        # noKernelTun: wireguard внутри процесса, не интерфейсом ядра. С
        # 24.11.30 Xray по умолчанию поднимает wg0 через /dev/net/tun: без
        # kmod-tun «CreateTUN failed» (стенд 25.12.5, 2026-10-01), с ним
        # появляется интерфейс, неизвестный маршрутизации. Старые версии поле
        # игнорируют.
        OUTBOUND="\"protocol\": \"wireguard\", \"settings\": { \"noKernelTun\": true, \"secretKey\": \"$N_WGKEY\", \"address\": [ \"$_wa\" ], \"peers\": [ { $_wp } ]$_wo }" ;;
      vmess)
        OUTBOUND="\"protocol\": \"vmess\", \"settings\": { \"vnext\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT, \"users\": [ { \"id\": \"$N_UUID\", \"alterId\": ${N_AID:-0}, \"security\": \"${N_METHOD:-auto}\" } ] } ] }" ;;
      trojan)
        OUTBOUND="\"protocol\": \"trojan\", \"settings\": { \"servers\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT, \"password\": $J_PASS } ] }" ;;
      shadowsocks)
        OUTBOUND="\"protocol\": \"shadowsocks\", \"settings\": { \"servers\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT, \"method\": \"$N_METHOD\", \"password\": $J_PASS } ] }" ;;
      socks)
        _su=""
        if [ -n "$N_USER" ]; then
          _su=", \"users\": [ { \"user\": $J_USER, \"pass\": $J_PASS } ]"
        fi
        OUTBOUND="\"protocol\": \"socks\", \"settings\": { \"servers\": [ { \"address\": \"$N_HOST\", \"port\": $N_PORT$_su } ] }" ;;
      *) dief "протокол %s не собран" "$N_PROTO" ;;
    esac
}
