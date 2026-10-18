# Текстовое меню (byway menu) -- в ucode (uc/menu.uc).

cmd_menu() {
    BW_SELF=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0") \
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR \
    BW_BADLIST=$BADLIST bw_uc menu
}
