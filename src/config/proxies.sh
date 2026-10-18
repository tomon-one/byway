# Аутбаунды собирает ucode (uc/outbound.uc) для gen, check и probe; здесь --
# метка сокетов.

# Метка исходящих для «VPN для программ на роутере» -- числом (uc/plumb.uc,
# та же, что в правилах nft).
ob_env_mark() {
    if [ "$(u router_via_vpn)" = "1" ]; then bw_uc selfmark; fi
}
