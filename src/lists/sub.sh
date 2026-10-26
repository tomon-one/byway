# Подписка: загрузка и вывод ключей построчно -- в ucode (uc/presets.uc,
# cmd_sub). Адрес -- окружением или файлом /var/run/byway-sub.url (панель,
# меню): аргументы видны всем в /proc/*/cmdline.

cmd_sub() {
    BW_SUB_URL=${1:-${BW_SUB_URL:-}} bw_uc sub
}
