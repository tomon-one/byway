# Маршрут и ip rule для помеченного трафика; метка своего трафика роутера.

# Номер таблицы не больше 255: busybox ip на 1602 отвечает 'invalid argument to
# table ID' (проверено 2026-09-03).
RT_TABLE=100

# Отметка «маршрут завёл byway», в памяти: маршрут перезагрузку не переживает.
RT_MINE=/tmp/byway-route-mine

RT_MINE6=/tmp/byway-route-mine6

# Метка на исходящих сокетах движка (sockopt.mark), не та же, что у обвязки.
# Цепочка output ловит по адресу назначения, а движок на том же хосте: пакет,
# не восстановленный в домен, заворачивался бы обратно -- петля съедает лимит
# файлов, и движок перестаёт принимать всё. Исключить можно только меткой, и
# бит другой, чем у mark: ip rule ловит по маске любую метку с ним.
self_mark() {
    # Образец заякорен: иначе мусор после префикса шёл в правила nft, а в
    # конфиг движка -- другое число, и метки расходились.
    _sm=$(nft_val self_mark "$(u self_mark)" \
          '^(0[xX][0-9a-fA-F]{1,8}|[0-9]{1,10})$' 0x400000)
    if [ "$(( _sm ))" -gt 4294967295 ] || [ "$(( _sm ))" -le 0 ]; then
        warnf "self_mark %s не влезает в 32 бита -- взято умолчание 0x400000" "$_sm"
        _sm=0x400000
    fi
    # Бит не должен пересекаться с mark: пакеты движка ушли бы в таблицу 100 на
    # петлю, а все проверки зелёные (проба отвечает от локального fakedns).
    _smk=$(eff_mark)
    if [ "$(( _sm & _smk ))" -ne 0 ]; then
        _sm=0x400000
        [ "$(( _sm & _smk ))" -ne 0 ] && _sm=0x800000
        warnf "self_mark пересекается битами с mark %s -- взято %s" "$_smk" "$_sm"
    fi
    printf '%s' "$_sm"
}

# То же десятичным: в конфиг движка идёт числом JSON. Арифметика оболочки, а не
# `printf '%d'`: при негодном числе тот дописывает запасной вывод к частичному.
self_mark_dec() {
    printf '%d' "$(( $(self_mark) ))"
}

# Образец по fwmark и таблице, а не по «lookup 100»: чужой tproxy (openclash,
# passwall, nikki) занимает ту же таблицу, и его правило принималось за своё.
# Конец закреплён: «lookup 100» совпадает и с «lookup 1000».
rule_re() {
    _rm=$(eff_mark)
    printf 'fwmark %s(/%s)?[[:space:]]+lookup %s([[:space:]]|$)' "$_rm" "$_rm" "$RT_TABLE"
}

# ip rule: помеченное -- в локальную таблицу, иначе tproxy-сокет пакета не
# увидит.
route_up() {
    # Чужие маршруты в таблице не трогаем, но говорим: наложение
    # непредсказуемо.
    if ip route show table "$RT_TABLE" 2>/dev/null | grep -qv "^local default dev lo"; then
        if ip route show table "$RT_TABLE" 2>/dev/null | grep -q .; then
            warnf "в таблице маршрутизации %s есть чужие маршруты -- byway их не трогает" "$RT_TABLE"
        fi
    fi
    _mark=$(eff_mark)
    ip rule show 2>/dev/null | grep -qE "$(rule_re)" ||
        ip rule add fwmark "$_mark/$_mark" lookup "$RT_TABLE"
    # Отметка «маршрут наш»: формой от чужого не отличить; в памяти, как и
    # маршрут.
    ip route show table "$RT_TABLE" 2>/dev/null | grep -q "^local default" ||
        { ip route add local default dev lo table "$RT_TABLE" && : > "$RT_MINE"; }
    # IPv6 -- та же таблица: маршруты v4 и v6 живут в разных пространствах.
    if v6on; then
        ip -6 rule show 2>/dev/null | grep -qE "$(rule_re)" ||
            ip -6 rule add fwmark "$_mark/$_mark" lookup "$RT_TABLE"
        # `list table all`, а не `show table N`: у busybox
        # `ip -6 route show table 100` при существующем маршруте молчит (код
        # 0), повторный подъём ловил «File exists», RT_MINE6 не ставилась, и
        # route_down не убирал за собой (стенд 22.03.7, 2026-09-08).
        ip -6 route list table all 2>/dev/null |
            grep -q "^local default dev lo table $RT_TABLE" ||
            { ip -6 route add local ::/0 dev lo table "$RT_TABLE" && : > "$RT_MINE6"; }
    fi
}

route_down() {
    _mark=$(eff_mark)
    while ip rule show 2>/dev/null | grep -qE "$(rule_re)"; do
        ip rule del fwmark "$_mark/$_mark" lookup "$RT_TABLE" 2>/dev/null || break
    done
    # Убирается только свой маршрут (по RT_MINE, не по форме): таблицу мог
    # занять другой tproxy, и flush сломал бы соседа.
    if [ -f "$RT_MINE" ]; then
        ip route del local default dev lo table "$RT_TABLE" 2>/dev/null || true
        rm -f "$RT_MINE" 2>/dev/null || true
    elif ip route show table "$RT_TABLE" 2>/dev/null |
         grep -qv "^local default dev lo"; then
        # Говорим, только когда в таблице есть чужое: осиротевший
        # `local default dev lo` без отметки безобиден (у установок до 0.1.4
        # отметки нет).
        warnf "маршрут в таблице %s оставлен: его завёл не byway" "$RT_TABLE"
    fi
    # Без проверки v6on: настройку могли выключить после подъёма, и убрать
    # правило и маршрут v6 было бы некому.
    while ip -6 rule show 2>/dev/null | grep -qE "$(rule_re)"; do
        ip -6 rule del fwmark "$_mark/$_mark" lookup "$RT_TABLE" 2>/dev/null || break
    done
    if [ -f "$RT_MINE6" ]; then
        ip -6 route del local ::/0 dev lo table "$RT_TABLE" 2>/dev/null || true
        rm -f "$RT_MINE6" 2>/dev/null || true
    fi
}
