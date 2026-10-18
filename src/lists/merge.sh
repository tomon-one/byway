# Общие списки доменов и подсетей: свои + готовые наборы, склейка и чистка.

# Записи, не прошедшие проверку формы при сборке, откладываются сюда и
# называются вслух: молча выкинуть часть чужого списка -- оставить гадать,
# почему домен не работает.
BADLIST=/tmp/byway-bad-entries

# Записи списка, которые можно спросить у резолвера: без regexp:/keyword:
# (по ним nslookup не отвечает, и проба на одной такой строке объявила бы отказ
# исправному туннелю) и без префиксов domain:/full:. return 0 нужен: grep без
# совпадений даёт 1, а `_d=$(plain_domains …)` под set -e на нём молча умирает.
plain_domains() {
    grep -vE '^[[:space:]]*(//|#|$)' "$1" 2>/dev/null | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
      sed -e 's/^domain://' -e 's/^full://' |
      grep -E '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' |
      grep -E '\.([A-Za-z][A-Za-z]+|xn--[A-Za-z0-9-]+)$' || true
    return 0
}

# Склейка свой + направления + пресеты, одним файлом без повторов (отдаётся
# путь) -- в ucode (uc/merge.uc, кэш с подписью). Читают сборка конфига, nft,
# запрет и проверки -- все видят одно и то же.
merged_env() {
    BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR BW_BADLIST=$BADLIST bw_uc merged "$1"
}
merged_subnets() { merged_env subnets; }
merged_domains() { merged_env domains; }
