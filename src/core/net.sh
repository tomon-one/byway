# Загрузки, которые обязаны пройти и при сломанном туннеле: net_get пробует
# прокси-вход, потом напрямую, потом адреса GitHub из DoH. a_of -- адрес имени.

# Имя -> адрес IPv4; $2 -- резолвер вместо системного. sed отрезает шапку с
# адресом самого резолвера (там тоже «Address», и он первый).
a_of() {   # $1 -- имя, $2 -- резолвер или пусто
    nslookup "$1" ${2:+"$2"} 2>/dev/null | sed -n '/^Name:/,$p' |
      awk '/^Address/ {print $NF}' |
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

# Все адреса имени: у имени с несколькими A-записями (round-robin) порядок
# ответов меняется от запроса к запросу.
a_all() {   # $1 -- имя, $2 -- резолвер или пусто
    nslookup "$1" ${2:+"$2"} 2>/dev/null | sed -n '/^Name:/,$p' |
      awk '/^Address/ {print $NF}' |
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

# Адрес имени по DoH, запросом К АДРЕСУ, не к имени: при сломанном туннеле
# локальный DNS отдаёт подставной адрес на всё из списка, и GitHub не достать.
# Тот же приём в install.sh (doh_a).
doh_a() {   # 1 -- имя
    for _dq in "https://8.8.8.8/resolve?name=$1&type=A" \
               "https://1.1.1.1/dns-query?name=$1&type=A"; do
        _da=$(curl -fsSL --max-time 8 -H "accept: application/dns-json" "$_dq" 2>/dev/null |
              tr ',' '\n' | sed -n 's/.*"data":"\([0-9][0-9.]*\)".*/\1/p' | head -1)
        case "$_da" in
          [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf '%s' "$_da"; return 0 ;;
        esac
    done
    return 1
}

# --resolve для имён GitHub (и переадресаций выпусков), один раз за запуск.
gh_resolve() {
    [ "${GH_RES_DONE:-0}" = 1 ] && return 0
    GH_RES_DONE=1; GH_RES=""
    for _gh in github.com api.github.com raw.githubusercontent.com codeload.github.com \
               objects.githubusercontent.com release-assets.githubusercontent.com; do
        _gi=$(doh_a "$_gh") || continue
        GH_RES="$GH_RES --resolve $_gh:443:$_gi"
    done
}

# Порядок: прокси-вход, напрямую, напрямую с адресами GitHub из DoH.
net_get() {   # аргументы curl как есть
    _npx=$(u local_proxy_port); _npx=${_npx:-1603}
    curl -fsSL -A "Mozilla/5.0" --proxy "http://127.0.0.1:$_npx" "$@" 2>/dev/null && return 0
    curl -fsSL -A "Mozilla/5.0" "$@" 2>/dev/null && return 0
    gh_resolve
    [ -n "$GH_RES" ] || return 1
    # shellcheck disable=SC2086
    curl -fsSL -A "Mozilla/5.0" $GH_RES "$@" 2>/dev/null
}
