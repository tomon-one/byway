# Сборка конфига Xray: cmd_gen и его шаги gen_*. $OUT меняется, только если
# ядро приняло конфиг (run -test).

# Список -> строки JSON-массива. Строка из списка попадает в конфиг как есть,
# поэтому пропускаются только буквы, цифры, . - : / _ до 253 знаков: кавычки
# и обратной косой в наборе нет, выйти из JSON-строки нечем (экранирование
# busybox awk не принимает). Отброшенное -- в $BADLIST, его называет cmd_gen.
list_to_json() {
    awk -v pfx="$2" -v bad="$BADLIST" '
      { sub(/\r$/, "") }
      /^[[:space:]]*$/          { next }
      /^[[:space:]]*(\/\/|#)/   { next }
      { gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if (!length($0)) next
        if (length($0) > 253)              { print $0 >> bad; next }
        # Форма проверяется по тому, ЧЕМ будет запись, а не одним общим
        # набором знаков. Прежний набор [A-Za-z0-9._:/-] пропускал и
        # «/d8d/s.com», и «full:example.com»: byway приписывает свой префикс
        # domain:, такая запись становилась «domain:full:example.com», ни с
        # чем не совпадала никогда и лежала в списке как живая. Молча
        # мёртвая запись хуже отвергнутой -- отвергнутые byway называет
        # вслух при сборке.
        #
        # Интервалы {2,} не используются намеренно: в awk старых сборок
        # busybox их может не быть, а [A-Za-z][A-Za-z]+ выражает то же.
        if (pfx ~ /^domain:/) {
            v = $0
            # geosite: и ext: не принимаются, и это не лень. Обе требуют
            # файла данных -- geosite.dat либо своего списка, -- которого
            # byway не поставляет, а Xray без указанного файла не стартует
            # вовсе. Человек получил бы «byway перестал собирать конфиг»
            # вместо строки про одну негодную запись.
            if (v ~ /^(geosite|ext):/)     { print $0 >> bad; next }
            pre = ""
            if (v ~ /^(domain|full|keyword|regexp):/) {
                pre = substr(v, 1, index(v, ":"))
                v = substr(v, index(v, ":") + 1)
                if (!length(v))            { print $0 >> bad; next }
            }
            if (pre == "regexp:") {
                # Единственная форма, где обратная косая и кавычка законны по
                # смыслу. Значит их не отвергают, а экранируют по правилам
                # JSON -- иначе кавычка закрыла бы строку и дописала свои
                # поля в конфиг, ровно как это делал extra.
                #
                # По знаку, а не gsub: в строке замены у gsub обратная косая
                # имеет своё значение, и «удвоить косую» пишется там четырьмя
                # уровнями экранирования, которые никто потом не прочтёт.
                esc = ""
                for (k = 1; k <= length(v); k++) {
                    ch = substr(v, k, 1)
                    if (ch == "\\" || ch == "\"") esc = esc "\\"
                    esc = esc ch
                }
                v = esc
            } else if (pre == "keyword:") {
                if (v !~ /^[A-Za-z0-9._-]+$/) { print $0 >> bad; next }
            } else {
                # domain:, full: и запись без префикса -- обычный домен.
                if (v !~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/ ||
                    v !~ /\.([A-Za-z][A-Za-z]+|xn--[A-Za-z0-9-]+)$/ ||
                    v ~ /\.\./)            { print $0 >> bad; next }
                if (pre == "") pre = pfx
            }
            if (n++) printf ",\n"
            printf "        \"%s%s\"", pre, v
            next
        } else {
            # Подсети. Та же форма, что у set_elements для nft, включая
            # проверку чисел: расходиться им нельзя, иначе запись уходит в
            # конфиг движка и не уходит в правила ядра. Одной регулярки мало
            # -- она пропускает и 999.1.2.3, и /33.
            ok = 1
            if ($0 ~ /:/) {
                # IPv6. Строгую форму проверяет set_elements6 -- она решает,
                # что уйдёт в ядро; здесь хватает грубой, потому что дальше
                # строку разбирает сам Xray. Без этой ветки годная подсеть
                # IPv6 уходила в список отброшенных И не попадала в правило
                # маршрутизации вовсе: перехваченный по ней трафик движок
                # отдавал наружу напрямую, то есть обещание «подсети в
                # туннель» для v6 не выполнялось молча.
                if ($0 !~ /^[0-9a-fA-F:]+(\/[0-9]{1,3})?$/) { print $0 >> bad; next }
            } else {
                if ($0 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) ok = 0
                else {
                    np = split($0, oc, /[.\/]/)
                    for (i = 1; i <= 4; i++) if (oc[i] + 0 > 255) ok = 0
                    if (np == 5 && oc[5] + 0 > 32) ok = 0
                }
                if (!ok)                   { print $0 >> bad; next }
            }
        }
        if (n++) printf ",\n"
        printf "        \"%s%s\"", pfx, $0 }
      END { if (!n) printf "" }
    ' "$1"
}

cmd_gen() {
    # Замок: панель и cron могут позвать gen одновременно, а черновик один.
    _lock=/var/run/byway-gen.lock
    take_lock "$_lock" "$(_t 'сборка конфига')" || die "другая сборка конфига не закончилась за 30 секунд"
    # Ловушка -- подстраховка: замок снимается явно в конце каждой ветки (в
    # живом gen EXIT-ловушка его не снимала, и следующая сборка ждала 30 с).
    # INT/TERM -- выйти (EXIT снимет): ловушка без exit оставляла процесс
    # идти дальше после Ctrl+C уже без рабочего каталога.
    trap 'rm -rf "$_lock" 2>/dev/null; true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [ -f "$CONF" ] || dief "нет %s" "$CONF"
    [ -x "$XRAY" ] || die "xray не найден"
    mkdir -p "$LISTS"
    # Черновики частей конфига -- в каталоге root, не в общем /tmp: их пишет
    # root, а потом вставляет в конфиг движка; движок не от root (ujail) мог
    # занять имя в /tmp заранее и подменить содержимое (Д-7). Тот же каталог,
    # что у журнала обращений и рабочих файлов stat.
    GEN_WORK=/var/run/byway
    [ -d "$GEN_WORK" ] || { mkdir -p "$GEN_WORK" && chmod 755 "$GEN_WORK"; } 2>/dev/null || true
    # Список негодных строк -- до сборки списков и направлений: прежде его
    # обнуляли после, и строки с пробелом из направлений терялись молча.
    : > "$BADLIST" 2>/dev/null || true

    D=$LISTS/domains.lst
    S=$(merged_subnets)
    # Объединённый список -- один раз на сборку: читается трижды (DNS, маршрут,
    # отчёт).
    MERGED=$(merged_domains)
    gen_routes
    [ -f "$D" ] || dief "нет списка доменов %s" "$D"
    [ -f "$S" ] || warnf "нет списка подсетей %s — правило по адресам не будет создано" "$S"
    gen_dns
    gen_inbounds
    gen_log
    gen_outbounds
    _dsave=$DIRECT_SET
    gen_dns_route

    # Черновик в память, не во флеш (43.7 МБ): живёт секунды, а на неудачной
    # сборке оставался бы файл с uuid и правами 0644.
    TMP=/tmp/byway-config.new.json
    # Сначала rm, потом создание под umask 077: `: >` усекал бы существующий
    # файл с его правами и чужими открытыми дескрипторами. Имя предсказуемо,
    # /tmp общий, внутри uuid: сосед (dnsmasq) мог создать файл 0666 заранее и
    # читать конфиг; chmod после записи не спасает.
    rm -f "$TMP" 2>/dev/null || true
    (umask 077; : > "$TMP") 2>/dev/null || true
    # Движок не от root читает конфиг группой byway (init, xray_user_prep);
    # нет группы -- остаётся 600.
    chgrp byway "$TMP" 2>/dev/null && chmod 640 "$TMP" 2>/dev/null || true
    gen_json

    # Один прогон движка, не три: из вывода берутся и предупреждения, и причина
    # отказа.
    # Каталог журнала обращений: движок при проверке открывает файл и без
    # каталога отвергает конфиг (первый gen при обновлении с 0.2.4 -- служба
    # ещё не стартовала и каталог не создавала). Права те же, что у init.
    [ -d /var/run/byway ] || { mkdir -p /var/run/byway && chmod 755 /var/run/byway; } 2>/dev/null || true
    _test=$("$XRAY" run -test -c "$TMP" 2>&1) && _testok=1 || _testok=0
    # Автовыбор: ключ, который отвергает только сам движок (vless без TLS к
    # публичному адресу на ядре 26.7.11+, byway такое пропускает), не должен
    # валить сборку целиком -- как и тот, что отверг разбор (Ф-3). Движок
    # называет outbound proxy-N: ключ снимается, сборка повторяется. Хотя бы
    # один ключ остаётся.
    _gtry=0
    SKIP_KEYS=""
    while [ "$_testok" = "0" ] && [ "$_gtry" -lt 6 ] && [ "$(u conn_mode)" = "urltest" ] && [ "${_n:-0}" -gt 1 ]; do
        _bk=$(printf '%s' "$_test" | sed -n 's/.*proxy-\([0-9][0-9]*\).*/\1/p' | head -1)
        [ -n "$_bk" ] || break
        _bki=$(printf '%s' "$PROXY_KEYIDX" | awk -v n="$_bk" '{print $(n + 1)}')
        [ -n "$_bki" ] || break
        warnf "ключ %s отвергнут движком — пропущен: %s" "$(( _bki + 1 ))" "$(printf '%s\n' "$_test" | grep "proxy-$_bk" | head -1 | awk -F'> ' '{print $NF}' | cut -c1-120)"
        SKIP_KEYS="$SKIP_KEYS $_bki"
        build_proxies
        VPN_HOSTS="$VPN_HOSTS $ROUTE_HOSTS"
        DIRECT_SET=$_dsave
        gen_dns_route
        gen_json
        _gtry=$((_gtry + 1))
        _test=$("$XRAY" run -test -c "$TMP" 2>&1) && _testok=1 || _testok=0
    done
    if [ "$_testok" = "1" ]; then
        # Предупреждения движка не глотать: Xray помечает транспорт устаревшим
        # за версию-другую до удаления, другого заблаговременного сигнала нет.
        # h2 и quic прошли путь warning -> удаление; ws и httpupgrade сейчас в
        # warning. Предупреждение может касаться части транспорта (kcp: только
        # поля) -- читать целиком.
        printf '%s\n' "$_test" |
          grep -i "deprecated\|will be removed\|migrate to" |
          sed 's/.*errors: //' | cut -c1-96 | sort -u |
          while IFS= read -r _w; do warnf "движок: %s" "$_w"; done

        # Отброшенные записи называем вслух и до сравнения с рабочим:
        # молчаливая потеря выглядит как «byway не работает с этим доменом».
        # Считаем уникальные: список читается дважды (DNS и маршрут).
        _bad=$(sort -u "$BADLIST" 2>/dev/null | grep -c . || true)
        if [ "${_bad:-0}" -gt 0 ]; then
            warnf "записей отброшено как неподходящие: %s" "$_bad"
            # Через warnf: панель показывает только строки с [!], а голые
            # записи терялись (Д-5).
            sort -u "$BADLIST" 2>/dev/null | head -10 |
                while IFS= read -r _bw; do warnf "    %s" "$_bw"; done
            [ "$_bad" -le 10 ] || warnf "    … и ещё %s (весь список: sort -u %s)" "$(( _bad - 10 ))" "$BADLIST"
            warn "  причина: не похоже ни на домен (буквы, цифры, дефис и точки; последняя часть — не короче двух букв), ни на подсеть IPv4, либо длиннее 253 знаков"
        fi
        # Не изменилось -- рабочий не трогаем: панель и procd зовут gen при
        # каждом «Сохранить и применить», это две записи во флеш на нажатие.
        if cmp -s "$TMP" "$OUT"; then
            rm -f "$TMP" 2>/dev/null || true
            rm -rf "$_lock" 2>/dev/null || true
            say "конфиг не изменился, рабочий оставлен как есть"
            sayf "  доменов %s, подсетей %s" "$(count_list "$MERGED")" "$(count_list "$S")"
            return 0
        fi
        # Место -- до подмены: обрыв записи оставил бы на месте рабочего
        # половину конфига.
        _need=$(( $(wc -c < "$TMP") / 1024 + 32 ))
        _have=$(df -k "$LISTS" 2>/dev/null | awk 'NR==2{print $4}')
        [ "${_have:-999999}" -ge "$_need" ] ||
            dief "на флеше свободно %s КБ, для конфига нужно %s -- рабочий не тронут" \
                 "${_have:-0}" "$_need"
        mv "$TMP" "$OUT"
        # В конфиге uuid ключа: читают root и, когда движок идёт не от root
        # (то же условие, что у xray_user_prep в init), группа byway. Голый
        # 600 оставлял следующий respawn движка без права прочитать конфиг.
        if [ "$(u xray_root)" != "1" ] && [ -x /sbin/ujail ] &&
           chgrp byway "$OUT" 2>/dev/null; then
            chmod 640 "$OUT" 2>/dev/null || true
        else
            chmod 600 "$OUT" 2>/dev/null || true
        fi
        sayf "конфиг собран и проверен движком: %s (%s байт)" "$OUT" "$(wc -c < "$OUT")"
        _own=$(count_list "$D")
        _all=$(count_list "$MERGED")
        if [ "$_all" -gt "$_own" ]; then
            sayf "  доменов %s (свои %s + пресеты), подсетей %s" "$_all" "$_own" "$(count_list "$S")"
        else
            sayf "  доменов %s, подсетей %s" "$_own" "$(count_list "$S")"
        fi
        if [ "$(u conn_mode)" = "urltest" ]; then
            sayf "  подключение: %s — Xray-core выбирает рабочий ключ по задержке" "${N_LABEL}"
        else
            _lb=${N_LABEL:-$N_HOST}
            sayf "  подключение: %s (%s:%s), транспорт %s, защита %s" "$_lb" "$N_HOST" "$N_PORT" "$N_TYPE" "$N_SEC"
        fi
        # Ширина -- по объединённому списку: одна строка 0.0.0.0/0 молча
        # превращает режим «по спискам» в полный туннель, да ещё хуже all --
        # правило «русские зоны напрямую» есть только в нём.
        net_warn "$(merged_subnets)"
        sayf "  пул fakeip %s, DNS-вход %s:53, tproxy %s, прокси роутера 127.0.0.1:%s" "$POOL" "$DNS_LISTEN" "$TP_PORT" "$LOCAL_PORT"
        rm -rf "$_lock" 2>/dev/null || true
    else
        warnf "движок отверг конфиг, черновик остался в %s:" "$TMP"
        printf '%s\n' "$_test" | tail -5 | sed 's/^/    /'
        xray_hint "$_test"
        rm -rf "$_lock" 2>/dev/null || true
        exit 1
    fi
}

# Направления со своим выходом: ноды, правила и хосты (ROUTE_*), общий список
# MAINDOM без их доменов.
gen_routes() {
    # До главного ключа: разбор ссылки пишет в общие N_*, и главный должен
    # разобраться последним, иначе сводка расскажет про чужую ноду. Пояснение
    # внутри ROUTE_RULES: без направлений оно не должно попасть в конфиг.
    ROUTE_OUT=""; ROUTE_HOSTS=""; ROUTE_N=0; ROUTE_OK=""
    ROUTE_RULES="
      // Направления идут ПЕРЕД общими правилами: Xray берёт первое
      // совпавшее, и домен, попавший и сюда, и в общий список, уходит
      // в свою ноду, а не в основную."
    for _rn in $(route_names); do
        [ "$(uci -q get "byway.$_rn.enabled")" = "0" ] && continue
        _rlb=$(uci -q get "byway.$_rn.label" || true)
        _rf=$ROUTES_DIR/$_rn.lst
        if [ ! -s "$_rf" ]; then
            warnf "направление «%s»: список %s пуст, пропущено" "$_rn" "$_rf"
            continue
        fi
        _rurl=$(route_key "$_rlb" || true)
        if [ -z "$_rurl" ]; then
            warnf "направление «%s»: ключа с меткой «%s» среди добавленных нет" "$_rn" "$_rlb"
            continue
        fi
        # Подоболочка: негодный ключ не должен ронять сборку остальных.
        if ! ( parse_node "$_rurl" && build_stream ) >/dev/null 2>&1; then
            warnf "направление «%s»: ключ не разбирается, пропущено" "$_rn"
            continue
        fi
        parse_node "$_rurl" >/dev/null 2>&1
        build_stream
        ROUTE_OUT="$ROUTE_OUT
$(proxy_block "route-$_rn"),"
        ROUTE_HOSTS="$ROUTE_HOSTS $N_HOST"

        # Через list_to_json, как главный список: route_list отсеивает только
        # «не IPv4», и кавычка внутри записи закрывала бы массив domain и
        # дописывала правила в конфиг движка (JSON верен, run -test принимает).
        # Файлы направлений пишет роль панели, а конфиг исполняет root.
        _rdt=/tmp/byway-route-dom.$$
        route_list "$_rf" dom > "$_rdt" 2>/dev/null || : > "$_rdt"
        _rd=$(list_to_json "$_rdt" "domain:")
        rm -f "$_rdt" 2>/dev/null || true
        [ -n "$_rd" ] && ROUTE_RULES="$ROUTE_RULES
      { \"type\": \"field\", \"domain\": [
$_rd
        ], \"outboundTag\": \"route-$_rn\" },"
        # Подсети тоже через list_to_json: прямая печать не проверяла октеты и
        # маску, а 10.0.0.0/33 останавливала gen -- и не применялась ни одна
        # настройка.
        _rst=/tmp/byway-route-net.$$
        route_list "$_rf" net > "$_rst" 2>/dev/null || : > "$_rst"
        _rs=$(list_to_json "$_rst" "")
        rm -f "$_rst" 2>/dev/null || true
        [ -n "$_rs" ] && ROUTE_RULES="$ROUTE_RULES
      { \"type\": \"field\", \"ip\": [
$_rs
        ], \"outboundTag\": \"route-$_rn\" },"
        ROUTE_N=$((ROUTE_N + 1))
        ROUTE_OK="$ROUTE_OK $_rn"
    done
    [ "$ROUTE_N" = 0 ] && ROUTE_RULES=""

    # Общее правило -- без доменов направлений (в fakedns они нужны, во втором
    # правиле лишние). grep -Fvxf, не comm: comm в busybox нет.
    MAINDOM=$MERGED
    if [ "$ROUTE_N" -gt 0 ]; then
        MAINDOM=/tmp/byway-domains-main.lst
        _rall=/tmp/byway-domains-routes.lst
        : > "$_rall"
        # Только направления, получившие правило: домены пропущенного
        # (нет ключа, негодный ключ) остаются в общем и идут в основной
        # туннель, а не повисают без правила.
        for _rn2 in $ROUTE_OK; do
            [ -f "$ROUTES_DIR/$_rn2.lst" ] && route_list "$ROUTES_DIR/$_rn2.lst" dom >> "$_rall"
        done
        grep -Fvxf "$_rall" "$MERGED" > "$MAINDOM" 2>/dev/null || cp "$MERGED" "$MAINDOM"
        : > "$_rall"
    fi
    [ "$ROUTE_N" -gt 0 ] && sayf "направлений со своим выходом: %s" "$ROUTE_N"
    return 0
}

# Резолверы: пул fakeip, основной и запасной upstream, bootstrap.
gen_dns() {
    # val_or: эти настройки уходили в конфиг движка сырыми (`"port": $TP_PORT`
    # даже без кавычек), входят в EXPORT_KEYS, и значением с `", ...` можно
    # было задать всю конфигурацию Xray, исполняемую от root; `run -test`
    # проверяет только синтаксис. Описка в порте расходила конфиг движка и nft.
    POOL=$(eff_pool loud)
    DNS_UP=$(val_or dns_upstream "$(u dns_upstream)" \
             '^(https|tcp|udp|tls|quic)://[A-Za-z0-9._:/?=&%+-]+$' \
             https://8.8.8.8/dns-query "$(_t 'конфига движка')")

    # Запасной резолвер: Xray идёт к следующему серверу по порядку, когда
    # предыдущий молчит или отказал. С одним молчащим запрос гибнет. Стоит выше
    # fakedns: пустой ответ DoH считается неудачей. Домен без A-записи (_dmarc)
    # всё равно получает fakeip -- пусты оба. Умолчание -- другой провайдер
    # (8.8.8.8 и 8.8.4.4 за одним AS), отключает none.
    _du2=$(u dns_upstream2)
    case "$_du2" in
      none|off|-)
        DNS_UP2="" ;;
      *)
        DNS_UP2=$(val_or dns_upstream2 "$_du2" \
                  '^(https|tcp|udp|tls|quic)://[A-Za-z0-9._:/?=&%+-]+$' \
                  https://1.1.1.1/dns-query "$(_t 'конфига движка')") ;;
    esac
    # Тот же адрес дважды -- не запас, а лишняя строка в конфиге.
    [ "$DNS_UP2" = "$DNS_UP" ] && DNS_UP2=""

    # bootstrap: кем разрешать имя самого резолвера. Имя DoH-сервера byway
    # умеет спросить только у него же: круг, дом без DNS молча. Bootstrap --
    # простой резолвер строго для этих имён (domains); skipFallback не пускает
    # спрашивать сам сервер. Имя нужно провайдерам с anycast (dns.nextdns.io).
    _bh=""
    for _u in "$DNS_UP" "$DNS_UP2"; do
        [ -n "$_u" ] || continue
        _h=$(dns_host "$_u")
        [ -n "$_h" ] && _bh="$_bh${_bh:+, }\"full:$_h\""
    done
    DNSBOOT=""
    if [ -n "$_bh" ]; then
        _bs=$(val_or dns_bootstrap "$(u dns_bootstrap)" \
              '^([0-9]{1,3}(\.[0-9]{1,3}){3}|(tcp|udp)://[0-9.]{7,15})(:[0-9]{1,5})?$' \
              "" "$(_t 'конфига движка')")
        if [ -n "$_bs" ]; then
            DNSBOOT='
      { "address": "'"$_bs"'", "domains": [ '"$_bh"' ], "skipFallback": true },'
        else
            # Громкий отказ с возвратом к рабочему: имя без bootstrap -- дом
            # без DNS при зелёном отчёте.
            warn "резолвер задан именем, а bootstrap не задан — разрешать имя нечем, взяты адреса по умолчанию"
            warn "  вписать: uci set byway.main.dns_bootstrap=77.88.8.8 && uci commit byway"
            DNS_UP=https://8.8.8.8/dns-query
            DNS_UP2=https://1.1.1.1/dns-query
        fi
    fi

    DNS_UP2LINE=""
    [ -n "$DNS_UP2" ] && DNS_UP2LINE='
      "'"$DNS_UP2"'",'
    return 0
}

# Адреса и порты входов, вход собственного трафика роутера (redir-in), развилка
# direct по версии Xray.
gen_inbounds() {
    DNS_LISTEN=$(val_or dns_listen "$(dns_addr)" \
                 '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' 127.0.0.42 "$(_t 'конфига движка')")
    TP_PORT=$(val_or tproxy_port "$(u tproxy_port)" '^[0-9]{1,5}$' 1602 "$(_t 'конфига движка')")
    port_ok "$TP_PORT" || TP_PORT=1602
    # Порт прокси для самого роутера. Слушает только петлю.
    LOCAL_PORT=$(val_or local_proxy_port "$(u local_proxy_port)" \
                 '^[0-9]{1,5}$' 1603 "$(_t 'конфига движка')")
    port_ok "$LOCAL_PORT" || LOCAL_PORT=1603
    # Вход для собственного трафика роутера: prerouting ловит только мосты, а
    # то, что роутер шлёт сам, идёт через output мимо, хотя резолвер уже отдал
    # fakeip («Operation not permitted»: byway update тянет файлы с github).
    # redirect, не tproxy: tproxy в output ядро не умеет; исходный адрес движок
    # берёт через SO_ORIGINAL_DST. Только TCP: у UDP исходный адрес после
    # подмены не узнать.
    # Петлю закрывает метка на исходящих сокетах движка (self_mark):
    # неопознанный пакет движок выпускает на тот же fakeip, и правило
    # заворачивало бы его обратно.
    REDIR_IN=""
    # Метка на исходящих direct и dns-out; пусто при выключенном заворачивании.
    SELFSO=""
    [ "$(u router_via_vpn)" = "1" ] && SELFSO=", \"streamSettings\": { \"sockopt\": { \"mark\": $(self_mark_dec) } }"
    # С 26.9.8 domainStrategy у direct живёт в sockopt (freedom.domainStrategy
    # движок переносит сам с «deprecated»). Удалят -- поле отбросится молча, и
    # direct отдаст домен системному резолверу, то есть обратно в dnsmasq.
    # Старым движкам sockopt-поле не заменяло своё, отсюда развилка.
    xray_ver_num >/dev/null
    DIRECT_SET=", \"settings\": { \"domainStrategy\": \"UseIP\" }"
    _dso=""
    if [ "$XRAYVER" -ge 260908 ]; then
        DIRECT_SET=""
        _dso="\"domainStrategy\": \"UseIP\""
    fi
    [ "$(u router_via_vpn)" = "1" ] && _dso="${_dso:+$_dso, }\"mark\": $(self_mark_dec)"
    DIRECTSO=""
    [ -n "$_dso" ] && DIRECTSO=", \"streamSettings\": { \"sockopt\": { $_dso } }"
    RD_PORT=$(redir_port "$(_t 'конфига движка')")
    # Вход двухсемейный, пока в output есть правило для fakeip6: ядро
    # подставляет ::1 для локального пакета, и на [::1]:1604 никто не слушал
    # (busybox wget падал, а на нём обновление списков).
    if v6on; then RD_LISTEN="::"; else RD_LISTEN=127.0.0.1; fi
    if [ -n "$RD_PORT" ]; then
        REDIR_IN=',
    {
      "tag": "redir-in",
      "listen": "'"$RD_LISTEN"'",
      "port": '"$RD_PORT"',
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "followRedirect": true },
      "sniffing": { "enabled": true, "destOverride": [ "fakedns", "http", "tls" ], "metadataOnly": false, "routeOnly": false }
    }'
    fi
    return 0
}

# Уровень журнала и журнал обращений Xray.
gen_log() {
    LOGLVL=$(u log_level)
    case "$LOGLVL" in
      debug|info|warning|error|none) ;;
      *) [ -n "$LOGLVL" ] && warnf "уровень журнала «%s» не годится, взят warning" "$LOGLVL"
         LOGLVL=warning ;;
    esac

    # Журнал обращений Xray отдельный от журнала ошибок и включён по умолчанию,
    # поэтому свой файл в памяти, а не syslog: буфер 256 КБ держал 20 минут,
    # cmd_stat раз в час недосчитывал две трети соединений. syslog -- для жалоб
    # движка, hostapd и netifd.
    case "$LOGLVL" in
      # Подробные уровни тоже в файл: отладку начинают, когда нужна история, а
      # syslog её вытесняет первой.
      info|debug) ACCESSLOG=', "access": "'"$ACCESS"'"' ;;
      # Для cmd_stat («чем пользуются»): при выключенном сборе журнал не нужен,
      # при включённом без него экран пуст. В режиме «всё через VPN» сбора нет:
      # журнал писал бы адрес каждого соединения дома.
      *)          if [ "$(u show_usage)" = "1" ] && [ "$(u list_mode)" != "all" ]; then
                      ACCESSLOG=', "access": "'"$ACCESS"'"'
                  else
                      ACCESSLOG=', "access": "none"'
                      # Усекаем, не удаляем: движок держит файл открытым и
                      # писал бы в удалённый невидимо. Через проверку, не
                      # `2>/dev/null || true`: у `:` (особая встроенная) ошибка
                      # перенаправления роняет весь скрипт, а каталога до
                      # первого старта после загрузки нет.
                      [ ! -f "$ACCESS" ] || : > "$ACCESS"
                  fi ;;
    esac
    return 0
}

# Размер пула fakedns, предупреждение о длинном списке, аутбаунды.
gen_outbounds() {
    # poolSize -- потолок пар «домен-адрес». Литерал 65535 при настраиваемом
    # пуле: у /15 (131 070 адресов) половина не использовалась, а список
    # длиннее 65 535 не помещался. Вытесненная из LRU пара отдаёт адрес другому
    # домену: соединение уходит к чужому хосту без ошибки.
    POOL_SIZE=$(pool_size "$POOL")
    _dcount=$(count_list "$MERGED"); _dcount=${_dcount:-0}
    if [ "$_dcount" -gt "$POOL_SIZE" ]; then
        warnf "доменов %s, а адресов в пуле %s — часть будет вытесняться и уводить соединения к чужому хосту. Расширить пул (byway.main.fakeip_pool) либо укоротить список" \
              "$_dcount" "$POOL_SIZE"
    fi

    build_proxies
    # Ноды направлений тоже в исключения: иначе петля.
    VPN_HOSTS="$VPN_HOSTS $ROUTE_HOSTS"
    return 0
}

# Пул fakeip для v6, стратегия запросов, DNS через туннель.
gen_dns_route() {
    # Домены списка на резолвер не попадают: их отдаёт fakedns локально,
    # настоящий адрес узнаёт нода. Настройка решает судьбу остальных запросов:
    # с домашнего адреса или через ноду.
    # Пул массивом: FakeDnsObject принимает и объект, и список
    # (infra/conf/fakedns.go). При v6 стратегия обязана быть UseIP: UseIPv4v6 у
    # Xray нет, UseIPv4 не отдаёт AAAA.
    FAKEDNS6=""; QSTRAT=UseIPv4; BLOCK6=""; TP_LISTEN=0.0.0.0
    if v6on; then
        _p6=$(val_or fakeip6_pool "$(u fakeip6_pool)" \
              '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$POOL6_DEF" "$(_t 'конфига движка')")
        FAKEDNS6=", { \"ipPool\": \"$_p6\", \"poolSize\": $POOL_SIZE }"
        QSTRAT=UseIP
        TP_LISTEN="::"
        # Тот же пул -- и в правило блокировки, по той же причине, что и у v4.
        BLOCK6=", \"$_p6\""
    fi
    # Частные v6 -- всегда, не только при ipv6=1: сниффер берёт имя из Host,
    # а там бывает и литерал [::1] (П1, 2026-10-04). fc00::/7 -- адреса
    # домашней сети (ULA), как 192.168/16 у v4. ::ffff:0:0/96 сюда не
    # кладём: матчер, приводящий v4 к этой форме, закрыл бы весь direct.
    BLOCK6=", \"::/128\", \"::1/128\", \"fc00::/7\", \"fe80::/10\"$BLOCK6"
    # Приватное, зарезервированное и пулы fakeip одним списком: правило
    # маршрута и итоговые правила direct обязаны совпадать.
    PRIVNETS="\"0.0.0.0/8\", \"10.0.0.0/8\", \"100.64.0.0/10\", \"127.0.0.0/8\", \"169.254.0.0/16\", \"172.16.0.0/12\", \"192.168.0.0/16\", \"$POOL\", \"224.0.0.0/4\", \"240.0.0.0/4\"$BLOCK6"
    # Правило маршрута сверяет адрес, а сниффер подставляет ИМЯ из Host или
    # SNI: имя правило пропускает, и direct разрешает его сам -- в том числе
    # в адрес роутера или домашней сети. Итоговые правила freedom (Xray
    # 26.5.9+) сверяют уже разрешённый адрес. blockDelay 0: по умолчанию движок
    # держит отказанное соединение 30-90 с, на роутере это дескрипторы.
    # Движку старше поле незнакомо и молча отбрасывается -- там имя разрешает
    # сам маршрут (IPOnDemand), а в режиме «всё через VPN» правило блокировки
    # встаёт до правил, отправляющих в direct.
    ROUTE_STRAT=IPIfNonMatch
    if [ "$XRAYVER" -ge 260509 ]; then
        _fr="\"finalRules\": [ { \"action\": \"block\", \"blockDelay\": 0, \"ip\": [ $PRIVNETS ] } ]"
        if [ -n "$DIRECT_SET" ]; then
            DIRECT_SET=", \"settings\": { \"domainStrategy\": \"UseIP\", $_fr }"
        else
            DIRECT_SET=", \"settings\": { $_fr }"
        fi
    else
        ROUTE_STRAT=IPOnDemand
    fi
    # Запросы встроенного DNS идут через маршрутизацию, как любой трафик.
    # Без своего правила при «Напрямую» их уносило последнее: в режиме «всё
    # через VPN» -- в туннель, и имя сервера из ключа разрешалось через сам
    # ещё не поднятый туннель. Тег и правило -- всегда, меняется цель.
    DNSTAG=', "tag": "dns-query"'; DNSHOSTS=""
    DNSRULE='
      { "type": "field", "inboundTag": [ "dns-query" ], "outboundTag": "direct" },'
    case "$(u dns_route)" in
      ''|direct|tunnel) ;;
      *) warnf "dns_route=%s не понят — DNS идёт напрямую; допустимо direct или tunnel" "$(u dns_route)" ;;
    esac
    if [ "$(u dns_route)" = "tunnel" ]; then
        # Круг: чтобы открыть соединение к ноде, Xray узнаёт её адрес, а запрос
        # ушёл бы в ещё не существующий туннель. Поэтому адрес ноды разрешается
        # при сборке и кладётся в конфиг статически (смена адреса --
        # пересборка, сказано в панели). Ключу с адресом вместо имени это не
        # нужно.
        _hh=""
        for _h in $VPN_HOSTS; do
            case "$_h" in *[a-zA-Z]*) ;; *) continue ;; esac
            # Три попытки: при рестарте системный резолвер указывает на наш
            # вход (BYWAY_KEEP_DNS), а движок уже остановлен. Один nslookup с
            # dief ронял gen, start_service поднимал прежний конфиг, а plumb on
            # клал правила по новым настройкам -- половины расходились молча
            # при зелёных проверках.
            _ip=$(server_addr "$_h")
            # Последняя опора -- адрес из прежнего конфига: устаревший лучше
            # несобравшегося.
            [ -n "$_ip" ] || _ip=$(sed -n 's/.*"'"$_h"'"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' \
                                   "$OUT" 2>/dev/null | head -1)
            if [ -z "$_ip" ]; then
                # Свой конфиг: в JSON бывают запасные и посторонние адреса
                # (Д-4), пропуск лучше отказа сборки. Ключ byway -- как было.
                if [ "$N_PROTO" = "raw" ]; then
                    warnf "адрес %s из своего конфига не разрешился — пропущен" "$_h"
                    continue
                fi
                dief "адрес сервера %s не разрешился — без него DNS через туннель не собрать (запросы к серверу ушли бы в сам туннель); проверить интернет и DNS роутера" "$_h"
            fi
            _hh="$_hh${_hh:+, }\"$_h\": \"$_ip\""
        done
        [ -n "$_hh" ] && DNSHOSTS="\"hosts\": { $_hh },"
        DNSRULE='
      { "type": "field", "inboundTag": [ "dns-query" ], '"$PROXY_TARGET"' },'
    fi
    return 0
}

# Шаблон конфига Xray целиком, запись в $TMP.
gen_json() {
    {
      cat <<HEAD
{
  "log": { "loglevel": "$LOGLVL"$ACCESSLOG },

  "fakedns": [ { "ipPool": "$POOL", "poolSize": $POOL_SIZE }$FAKEDNS6 ],

  "dns": {
    $DNSHOSTS
    "servers": [$DNSBOOT
      "$DNS_UP",$DNS_UP2LINE
      {
        "address": "fakedns",
        "skipFallback": true,
        "domains": [
HEAD
      # Через файл: список в переменной ash -- 9,5 МБ на потолке пресета (200
      # 000 доменов), при подстановке вдвое больше, а на 240 МБ рядом работает
      # движок, и OOM убил бы его.
      _fdf=$GEN_WORK/fakedns.json
      list_to_json "$MERGED" "domain:" > "$_fdf" 2>/dev/null || : > "$_fdf"
      # Запятая -- только если перед ней что-то есть: на пустом списке «[ ,
      # "full:…" ]» движок отвергал конфиг целиком.
      [ -s "$_fdf" ] && { cat "$_fdf"; printf ',\n'; } || true
      rm -f "$_fdf" 2>/dev/null || true
      # Проба -- и сюда: без fakeip клиент ушёл бы мимо перехвата, и проверка
      # судила бы не о туннеле.
      printf '          "full:%s"' "$PROBE_DOMAIN"
      cat <<MID

        ]
      }
    ],
    "queryStrategy": "$QSTRAT"$DNSTAG
  },

  "inbounds": [
    {
      "tag": "dns-in",
      "listen": "$DNS_LISTEN",
      "port": 53,
      "protocol": "dokodemo-door",
      "settings": { "address": "$DNS_LISTEN", "port": 53, "network": "tcp,udp" }
    },
    {
      "tag": "tproxy-in",
      // 0.0.0.0, а не петля: tproxy НЕ переписывает адрес назначения, пакет
      // доходит до сокета с исходным 198.18.x.x. Сокет, привязанный к
      // 127.0.0.1, такой пакет не поймает никогда — правила срабатывают,
      // счётчик растёт, наружу не идёт ничего. Стоило часа 2026-09-03.
      // При включённом IPv6 -- "::" вместо "0.0.0.0": отсутствие поля и
      // "0.0.0.0" у Xray значат СТРОГО IPv4 (infra/conf/xray.go, AnyIP), и
      // пакет v6 до сокета не дошёл бы вовсе. Сокет на "::" двухсемейный,
      // пока sockopt.V6Only не выставлен, -- перехват IPv4 не теряется.
      "listen": "$TP_LISTEN",
      "port": $TP_PORT,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": true, "destOverride": [ "fakedns", "http", "tls", "quic" ], "metadataOnly": false, "routeOnly": false }
    },
    {
      // Прокси для САМОГО РОУТЕРА. Правила nft стоят в prerouting и ловят
      // только трафик из мостов; собственный трафик роутера идёт через
      // output и до tproxy не доходит. Значит роутер не может достучаться
      // ни до одного домена из списка -- его резолвер честно отдаёт адрес
      // из пула, а маршрута туда нет.
      //
      // Ломало это не абстракцию, а дело: zms-pin.sh и штатные обновлялки
      // списков zapret тянут файлы с github, а github в списке.
      //
      // Вход остаётся и при включённом заворачивании (router_via_vpn): он
      // работает без единого правила в ядре и потому годится там, где
      // правил ещё нет или они запрещены -- в том числе самому обновлению
      // byway, которому надо скачать себя новым до того, как правила
      // переложат.
      //
      // ⚠️ Обратных кавычек в этом комментарии быть не может. Он идёт в
      // конфиг из heredoc БЕЗ кавычек у метки, то есть оболочка разбирает
      // его как обычную строку: команду в обратных кавычках она ВЫПОЛНИТ, и
      // вывод команды уедет в середину JSON. Так и вышло 2026-09-07 --
      // движок отверг конфиг с «invalid character », а byway при каждой
      // сборке лез в сеть за новой версией себя.
      //
      // Пользоваться так:
      //   https_proxy=http://127.0.0.1:$LOCAL_PORT curl ...
      //   busybox wget по https через прокси не ходит
      // Маршрутизация обычная: домен из списка уйдёт через ноду, прочее
      // напрямую.
      "tag": "local-in",
      "listen": "127.0.0.1",
      "port": $LOCAL_PORT,
      "protocol": "http",
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls" ], "metadataOnly": false, "routeOnly": false }
    }$REDIR_IN
  ],

  "outbounds": [
$PROXIES,$ROUTE_OUT
    { "tag": "direct", "protocol": "freedom"$DIRECT_SET$DIRECTSO },
    { "tag": "dns-out", "protocol": "dns"$SELFSO },
    { "tag": "block", "protocol": "blackhole" }
  ],

  $OBSERVATORY

  "routing": {
    $BALANCERS
    "domainStrategy": "$ROUTE_STRAT",
    "rules": [
      { "type": "field", "inboundTag": [ "dns-in" ], "outboundTag": "dns-out" },$DNSRULE$ROUTE_RULES
MID
      if [ "$(u list_mode)" = "all" ]; then
        # Режим «всё через VPN»: списки не участвуют, направление задаёт
        # последнее правило, исключение одно -- сам сервер VPN: иначе его адрес
        # ушёл бы в тот же ещё не поднятый VPN, и соединение не встаёт без
        # ошибки в журнале.
        # Русские зоны мимо туннеля: банки, госуслуги и маркетплейсы через VPN
        # ломаются. .рф -- пуникодом (xn--p1ai): в DNS и SNI идёт он.
        if [ "$ROUTE_STRAT" = "IPOnDemand" ]; then
          printf '      { "type": "field", "ip": [ %s ], "outboundTag": "block" },\n' "$PRIVNETS"
        fi
        if [ "$(u ru_direct)" = "1" ]; then
          printf '      { "type": "field", "domain": [ "domain:ru", "domain:su", "domain:xn--p1ai" ], "outboundTag": "direct" },\n'
        fi

        for _h in $VPN_HOSTS; do
          # Не похожее на имя или адрес движок отвергнет вместе со всем
          # конфигом.
          case "$_h" in
            ''|-|*[!A-Za-z0-9.:_-]*) continue ;;
          esac
          case "$_h" in
            *[a-zA-Z]*) printf '      { "type": "field", "domain": [ "full:%s" ], "outboundTag": "direct" },\n' "$_h" ;;
            *)          printf '      { "type": "field", "ip": [ "%s/32" ], "outboundTag": "direct" },\n' "$_h" ;;
          esac
        done
      else
        # Пустой список -- не повод писать правило с пустым массивом: Xray
        # такой конфиг отвергает.
        # Через файл: список печатается дважды (fakedns и здесь), а в
        # переменной ash на потолке пресета это 9,5 МБ, при подстановке вдвое
        # больше -- на 240 МБ, где рядом работает движок.
        _djf=$GEN_WORK/dom.json
        list_to_json "$MAINDOM" "domain:" > "$_djf" 2>/dev/null || : > "$_djf"
        # Домен-проба -- всегда, даже при пустом списке: через него проверка
        # «трафик проходит» смотрит всю цепочку и не зависит от меняющегося
        # списка. example.com закреплён IANA под примеры, заворот его ничего не
        # стоит.
        printf '      { "type": "field", "domain": [\n'
        [ -s "$_djf" ] && { cat "$_djf"; printf ',\n'; }
        printf '          "full:%s"\n' "$PROBE_DOMAIN"
        printf '        ], %s },\n' "$PROXY_TARGET"
        rm -f "$_djf" 2>/dev/null || true
        # Через файл, как домены: список из одних негодных строк давал бы
        # «"ip": [ ]», и движок отвергал весь конфиг без имени виновной строки.
        _sjf=$GEN_WORK/sub.json
        if [ -f "$S" ]; then list_to_json "$S" "" > "$_sjf" 2>/dev/null || : > "$_sjf"; else : > "$_sjf"; fi
        if [ -s "$_sjf" ]; then
          printf '      { "type": "field", "ip": [\n'
          cat "$_sjf"
          printf '\n        ], %s },\n' "$PROXY_TARGET"
        fi
        rm -f "$_sjf" 2>/dev/null || true
      fi
      cat <<MID2
MID2
      cat <<END
      // Приватное и зарезервированное -- в блок, и ОБЯЗАТЕЛЬНО до direct.
      // Без этого вход tproxy работал открытым форвардером: клиент из
      // гостевой сети открывал соединение на любой адрес пула и первым же
      // пакетом слал «Host: 192.168.1.1». Сниффер подменял назначение на
      // то, что написал клиент, а наружу шёл САМ РОУТЕР -- то есть мимо
      // forward-цепочки, где гостей режет reject. Изоляция гостевой сети
      // обходилась целиком.
      //
      // Сюда же входит сам пул fakeip: соединение на порт входа замыкалось
      // на этот же вход и порождало витки без ограничителя, пока не кончатся
      // дескрипторы.
      // Пул подставляется переменной, а не литералом: он настраивается в
      // панели, и со своим значением защита от петли перечисляла бы чужой
      // диапазон, а нужный оставляла открытым.
      // Имя вместо адреса это правило не ловит -- см. PRIVNETS выше.
      { "type": "field", "ip": [ $PRIVNETS ], "outboundTag": "block" },
      { "type": "field", "network": "tcp,udp", $LAST_TARGET }
    ]
  }
}
END
    } > "$TMP"
    return 0
}

# Настоящий адрес сервера для DNS через туннель. Местный резолвер в этом
# режиме отдаёт адрес из прежнего конфига (hosts), смена адреса не увиделась
# бы: сперва пин /etc/hosts, потом внешние резолверы, потом местный.
server_addr() {   # $1 -- имя
    _sa=$(awk -v n="$1" '$1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == n) { print $1; exit } }' \
          /etc/hosts 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)
    [ -n "$_sa" ] || _sa=$(a_of "$1" 8.8.8.8)
    [ -n "$_sa" ] || _sa=$(a_of "$1" 1.1.1.1)
    [ -n "$_sa" ] || _sa=$(a_of "$1")
    printf '%s' "$_sa"
}
