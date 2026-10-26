# Общие списки доменов и подсетей: свои + готовые наборы, склейка и чистка.

# Записи, не прошедшие проверку формы при сборке, откладываются сюда и
# называются вслух: молча выкинуть часть чужого списка -- оставить гадать,
# почему домен не работает.
BADLIST=/var/run/byway-bad-entries

# Склейка свой + направления + пресеты, одним файлом без повторов (отдаётся
# путь) -- в ucode (uc/merge.uc, кэш с подписью). Читают сборка конфига, nft,
# запрет и проверки -- все видят одно и то же.
merged_env() {
    BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR BW_BADLIST=$BADLIST bw_uc merged "$1"
}
merged_subnets() { merged_env subnets; }
merged_domains() { merged_env domains; }
