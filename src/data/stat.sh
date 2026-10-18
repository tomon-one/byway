# Учёт обращений (stat из cron) и top -- в ucode (uc/stat.uc). Здесь пути,
# которые читают и другие команды (clear в data/transfer.sh), и склейка
# списков, пока она на shell.

STATDIR=/var/run/byway
STAT=$LISTS/usage.tsv        # домен, обращений, последний раз
MAP=$STATDIR/fakemap         # адрес -> домен, живёт в памяти как и сам Xray
MARK=$STATDIR/statmark       # PID и метка времени последней обработанной строки
MAPPOS=$STATDIR/fakemap.pos  # докуда дошли, строя карту порциями

cmd_stat() {
    BW_OUT=$OUT BW_LISTS=$LISTS BW_ACCESS=$ACCESS BW_ROUTES=$ROUTES_DIR \
    BW_MERGED=$(merged_domains) bw_uc stat
}

cmd_top() {
    BW_LISTS=$LISTS BW_MERGED=$(merged_domains) bw_uc top "$@"
}
