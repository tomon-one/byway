# Аутбаунды собирает ucode (uc/outbound.uc) для gen, check и probe; здесь --
# метка сокетов, пока перехват на shell.

# Метка исходящих для «VPN для программ на роутере» -- числом, пока перехват
# на shell. Последняя строка: self_mark печатает жалобы в тот же вывод.
ob_env_mark() {
    if [ "$(u router_via_vpn)" = "1" ]; then self_mark_dec | tail -1; fi
}
