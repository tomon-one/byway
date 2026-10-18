# Подписка: загрузка и вывод ключей построчно -- в ucode (uc/presets.uc,
# cmd_sub). Адрес -- окружением: аргументы видны всем в /proc/*/cmdline.

cmd_sub() {
    BW_SUB_URL=${1:-} bw_uc sub
}
