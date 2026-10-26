# Аутбаунды собирает ucode (uc/outbound.uc) для gen, check и probe; здесь --
# метка сокетов.

# Метка исходящих для «VPN для программ на роутере» -- числом (uc/plumb.uc,
# та же, что в правилах nft).
# Метка нужна и движку от root (xray_root=1 или нет procd-ujail): по uid его
# не узнать, и запрет ходить на свои адреса роутера держится на ней (Ф9, п1-17).
# Метка-файл -- от init: пользователя byway подготовить не удалось (н1-19).
ob_env_mark() {
    if [ "$(u router_via_vpn)" = "1" ] || [ "$(u xray_root)" = "1" ] || [ ! -x /sbin/ujail ] ||
       [ -e /var/run/byway-xray-root ]; then
        bw_uc selfmark
    fi
}
