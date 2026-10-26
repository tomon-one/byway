# Учёт обращений (stat из cron) и top -- в ucode (uc/stat.uc: пути учёта и
# карты адрес -> домен заданы там же). Здесь только вызов.

cmd_stat() {
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ACCESS=$ACCESS BW_ROUTES=$ROUTES_DIR \
    BW_MERGED=$(merged_domains) bw_uc stat
}

cmd_top() {
    BW_LISTS=$LISTS BW_MERGED=$(merged_domains) bw_uc top "$@"
}
