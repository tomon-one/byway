# Списки доменов и подсетей: готовые наборы (presets), направления (routes),
# подписка, склейка в общий список для конфига и перехвата.

# Записи, не прошедшие проверку формы при сборке, откладываются сюда и
# называются вслух: молча выкинуть часть чужого списка -- оставить гадать,
# почему домен не работает.
BADLIST=/tmp/byway-bad-entries
# ── пресеты ────────────────────────────────────────────────────────────────
# Готовые списки доменов вместо своего или вместе с ним. Каталог здесь, а
# не в панели: панель может не стоять. Пресеты никто не проверяет, кроме их
# авторов (itdoginfo 2026-09-04: из 37 новых записей 4 уже в хостлисте zapret,
# 2 -- убранный сервис, 2 -- мусор), поэтому после загрузки byway говорит о
# пересечениях.
PRESETS_DIR=$LISTS/presets
# ── несколько выходов ──────────────────────────────────────────────────────
# Направление: домены и подсети из /etc/byway/routes/<имя>.lst уходят в ноду
# с этой меткой ключа. Ключ не дублируется (в секции UCI -- метка, ссылка из
# node_urls): иначе uuid разошёлся бы при смене ключа. Домены и подсети --
# в одном файле, различаются по форме строки.
ROUTES_DIR=$LISTS/routes

# Пин в /etc/hosts перебивает резолвер: dnsmasq отвечает по пину, подставного
# адреса нет, клиент идёт напрямую, хотя домен в списке. Сверка по суффиксу:
# пин на cdn.example.com перебивает запись example.com (у dnsmasq имя точное,
# у byway -- с поддоменами).
hosts_vs_domains() {   # $1 -- файл доменов
    [ -f /etc/hosts ] && [ -s "$1" ] || { echo 0; return 0; }
    _hp=/tmp/byway-hosts.$$
    awk '$1 !~ /^#/ && NF >= 2 { for (i = 2; i <= NF; i++) if ($i !~ /^#/) print $i }' \
        /etc/hosts 2>/dev/null | tr -d '\r' | sort -u > "$_hp"
    if [ -s "$_hp" ]; then
        # Для каждого пина откусываются метки слева, и каждый хвост ищется
        # в списке: запись discord.media перебивается пином
        # finland12345.discord.media (byway приписывает domain:, запись
        # накрывает поддомены). Обратная сверка молчала всегда.
        awk -v LF="$1" '
          BEGIN {
            while ((getline l < LF) > 0) {
              gsub(/[[:space:]\r]/, "", l)
              if (l == "" || substr(l, 1, 1) == "#" || substr(l, 1, 2) == "//") continue
              d[tolower(l)] = 1
            }
          }
          {
            h = tolower($0)
            if (h in d) { c++; next }
            s = h
            while ((p = index(s, ".")) > 0) {
              s = substr(s, p + 1)
              if (s in d) { c++; next }
            }
          }
          END { print c + 0 }
        ' "$_hp"
    else
        echo 0
    fi
    rm -f "$_hp" 2>/dev/null || true
}

# Подсети против пинов: у подсетей нет имён, сверка по адресам. Пин вида
# finlandNNNNN.discord.media ставят, чтобы адрес шёл мимо туннеля; широкий
# диапазон из набора делает обратное.
hosts_in_subnets() {   # $1 -- файл подсетей
    [ -f /etc/hosts ] || { echo 0; return 0; }
    [ -s "$1" ] || { echo 0; return 0; }
    awk -v SF="$1" '
      function a2n(a,  p) { split(a, p, "."); return ((p[1]*256+p[2])*256+p[3])*256+p[4] }
      BEGIN {
        while ((getline l < SF) > 0) {
          gsub(/[[:space:]\r]/, "", l)
          if (l == "" || substr(l,1,1) == "#" || substr(l,1,2) == "//") continue
          pfx = 32; ip = l
          if (index(l, "/")) { ip = substr(l, 1, index(l,"/")-1); pfx = substr(l, index(l,"/")+1) + 0 }
          if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) continue
          n++; base[n] = a2n(ip); size[n] = 2 ^ (32 - pfx)
        }
      }
      /^[[:space:]]*#/ { next }
      $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        v = a2n($1)
        for (i = 1; i <= n; i++)
          if (int(v / size[i]) == int(base[i] / size[i])) { c++; break }
      }
      END { print c + 0 }' /etc/hosts
}

# Имена пресетов -- для каталога в консоли.
preset_names() { printf '%s' "byway itdoginfo-geoblock itdoginfo-block itdoginfo-subnets"; }

preset_url() {
    case "$1" in
      byway)              echo "https://raw.githubusercontent.com/tomon-one/byway-lists/main/domains.lst" ;;
      itdoginfo-geoblock) echo "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Categories/geoblock.lst" ;;
      itdoginfo-block)    echo "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Categories/block.lst" ;;
      *) return 1 ;;
    esac
}

# Подсети пресета -- отдельным файлом: другой фильтр и потолок, другие
# потребители (набор nft и ip-правило, а не fakedns). Есть не у каждого
# пресета; нет адреса -- шаг пропускается.
preset_suburl() {
    case "$1" in
      byway) echo "https://raw.githubusercontent.com/tomon-one/byway-lists/main/subnets.lst" ;;
      # Несколько адресов через пробел: у itdoginfo подсети по сервисам.
      # Берётся весь набор, включая широкие: решает человек, byway измеряет
      # (net_warn). Замер 2026-09-05: ~21 млн адресов (ovh 4.6 млн,
      # cloudfront 4.2, discord 4.1 блоками до /12, hetzner 3.2,
      # digitalocean 3.1, cloudflare 1.5, meta 474 тыс., telegram 97 тыс.),
      # полпроцента IPv4.
      itdoginfo-subnets)
        echo "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/telegram.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/meta.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/twitter.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/roblox.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/discord.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/google_meet.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/cloudflare.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/cloudfront.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/digitalocean.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/hetzner.lst https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/ovh.lst" ;;
      *) return 1 ;;
    esac
}

preset_about() {
    case "$1" in
      byway)              echo "$(_t 'курируемый список byway: сервисы, недоступные из РФ и блокирующие её')" ;;
      itdoginfo-geoblock) echo "$(_t 'itdoginfo: сервисы, которые сами закрываются от российских адресов')" ;;
      itdoginfo-block)    echo "$(_t 'itdoginfo: заблокированное в РФ. Внимание: встречается мусор')" ;;
      itdoginfo-subnets)  echo "$(_t 'itdoginfo: подсети для сервисов, которые работают не по именам. Весь их набор: Telegram, Meta, Twitter, Roblox, Discord, Google Meet и диапазоны хостеров Cloudflare, CloudFront, DigitalOcean, Hetzner, OVH. Вместе около 21 миллиона адресов -- byway скажет точную цифру при загрузке')" ;;
      *) echo "$(_t 'свой адрес')" ;;
    esac
}

# Скачивает список пресета и подменяет им прежний; общая для доменов и
# подсетей (фильтр и потолок разные, осторожность одна). Идёт через прокси
# byway: домен источника может лежать в списке. --max-filesize: флеш 43.7 МБ,
# чужой список в сотни МБ забил бы его. Пишет в сторону и подменяет
# проверенным: запись прямо в боевой файл оставляла его пустым на время sort,
# а ответ 200 с заглушкой провайдера стирал прежнюю копию.
# Возврат: 0 подменили, 1 скачанное не похоже на список (прежнее на месте),
# 2 не скачалось.
fetch_list() {   # адреса через пробел, целевой файл, dom|net, имя пресета
    _fu=$1; _ft=$2; _fk=$3; _fn=$4
    _ftmp=/tmp/byway-preset.$$.$(basename "$_ft")
    _fpart=$_ftmp.part
    _fcnt=$_ftmp.cnt
    : > "$_ftmp"
    # Не скачался хоть один адрес -- отказ целиком: половина набора молча
    # теряет сервис.
    for _f1 in $_fu; do
        net_get --max-time 40 --max-filesize 8000000 -o "$_fpart" "$_f1" ||
        { rm -f "$_ftmp" "$_fpart"; return 2; }
        cat "$_fpart" >> "$_ftmp"
        # Перевод строки между файлами: последняя строка списка бывает без
        # него и слипается со следующей (5.28.192.0 + 21... = 215.28.192.0).
        printf '\n' >> "$_ftmp"
        # --max-filesize стоит на каждый адрес, а их до 11: сумму ограничивает
        # это условие (склейка доходила до 88 МБ в tmpfs при 240 МБ памяти).
        if [ "$(wc -c < "$_ftmp" 2>/dev/null || echo 0)" -gt 33554432 ]; then
            warnf "%s: источники дали больше 32 МБ — загрузка отменена, прежний список на месте" "$_fn"
            rm -f "$_ftmp" "$_fpart" 2>/dev/null || true
            return 1
        fi
    done
    rm -f "$_fpart"

    # Пробелы снимаются только по краям: вырезание внутри склеивало
    # hosts-формат (`0.0.0.0 example.com`) в домен `0.0.0.0example.com`,
    # проходящий проверку формы.
    if [ "$_fk" = net ]; then
        # Форма та же, что у set_elements и list_to_json: подсеть, которую
        # принимает одна проверка и не другая, снимает обвязку целиком.
        _cap=20000
        grep -vE '^[[:space:]]*(//|#|$)' "$_ftmp" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
          grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' |
          sort -u | awk -v cap="$_cap" -v cf="$_fcnt" \
            '{ n++; if (n <= cap) print } END { print n+0 > cf }' > "$_ft.new" ||
          { rm -f "$_ftmp" "$_ft.new" "$_fcnt" 2>/dev/null || true; return 2; }
    else
        # Отсев типичного мусора: ведущая точка (вся зона), пробелы внутри,
        # пустые строки, комментарии.
        _cap=200000
        grep -vE '^[[:space:]]*(//|#|$)' "$_ftmp" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
          grep -E '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$' |
          grep -E '\.[a-zA-Z]{2,}$' |
          sort -u | awk -v cap="$_cap" -v cf="$_fcnt" \
            '{ n++; if (n <= cap) print } END { print n+0 > cf }' > "$_ft.new" ||
          { rm -f "$_ftmp" "$_ft.new" "$_fcnt" 2>/dev/null || true; return 2; }
    fi
    rm -f "$_ftmp"

    # Срез -- вслух. Число берётся у самого конвейера (в файле уже
    # срезанное): иначе порог ниже сравнивал бы усечённое, и срез на
    # следующем прогоне был бы неотличим от нормы. Отфильтрованное целиком
    # не кладётся во флеш: файл мог занять весь /overlay (43.7 МБ) и
    # заблокировать запись всем остальным.
    _pre=$(cat "$_fcnt" 2>/dev/null || echo 0)
    case "$_pre" in ''|*[!0-9]*) _pre=0 ;; esac
    rm -f "$_fcnt" 2>/dev/null || true
    if [ "$_pre" -gt "$_cap" ]; then
        warnf "%s: записей %s, взяты первые %s — остальное отброшено" "$_fn" "$_pre" "$_cap"
        logf 'пресет %s: %s записей, срез до %s' "$_fn" "$_pre" "$_cap"
    fi

    # Порог -- четверть прежнего размера, не «не ноль»: усохший с полутора
    # тысяч записей до трёх список тоже заглушка. Нет прежней копии --
    # любой непустой.
    _new=$(count_list "$_ft.new")
    _old=$(count_list "$_ft")
    if [ "${_new:-0}" -eq 0 ] ||
       { [ "${_old:-0}" -gt 0 ] && [ "$((_new * 4))" -lt "$_old" ]; }; then
        rm -f "$_ft.new"
        warnf "%s: скачанное не похоже на список (%s записей, было %s) — прежняя копия оставлена" \
              "$_fn" "${_new:-0}" "${_old:-0}"
        logf 'пресет %s: отказ, записей %s, было %s' "$_fn" "$_new" "$_old"
        return 1
    fi
    mv "$_ft.new" "$_ft"
    return 0
}

# Мерка ширины списка подсетей (суммарно адресов, самый широкий блок): не
# запрет, но молчать нельзя. Порог -- миллион адресов суммарно или блок
# шире /12 (свой список: 633 тыс. и /14 -- молчит; набор itdoginfo: 21 млн
# и /12 -- говорит).
net_width() {
    # big стартует с 33: с нуля запись 0.0.0.0/0 (p=0) его не меняла, и
    # показывался префикс последней строки, а не самой широкой.
    awk 'BEGIN { big = 33 }
         { gsub(/[[:space:]\r]/, "")
           if ($0 == "" || substr($0,1,1) == "#" || substr($0,1,2) == "//") next
           p = 32
           if (index($0, "/")) p = substr($0, index($0, "/") + 1) + 0
           n = 1; for (i = 0; i < 32 - p; i++) n *= 2
           tot += n
           if (p < big) big = p }
         END { printf "%d %d", tot + 0, (big == 33 ? 32 : big) }' "$1"
}

net_warn() {
    _nw=$(net_width "$1")
    _nwt=${_nw%% *}
    _nwb=${_nw##* }
    if [ "${_nwt:-0}" -gt 1000000 ] || [ "${_nwb:-32}" -le 12 ]; then
        warnf "  ВНИМАНИЕ: %s адресов, крупнейший блок /%s — в туннель уйдёт и чужой трафик, и скорость упадёт" \
              "$_nwt" "$_nwb"
    fi
}

# Пересечение файла с хостлистом zapret, общая для своего списка и пресетов.
# По суффиксу: оба движка матчат домен с поддоменами, «cdn.example.com против
# example.com» -- тот же конфликт. Печатает число, найденные строки оставляет
# в /tmp/byway-zap.$$.hit; выжимка хостлиста собирается на каждый вызов.
zap_overlap() {   # 1 -- файл со списком доменов
    [ -f "$ZAPHOSTS" ] && [ -s "$1" ] || { printf '0'; return 0; }
    _zo=/tmp/byway-zap.$$
    grep -vE '^[[:space:]]*(#|$)' "$ZAPHOSTS" | tr -d ' \t\r' | sort -u > "$_zo"
    sed 's/^/./' "$_zo" > "$_zo.suf"
    { grep -Fxf "$_zo" "$1" 2>/dev/null
      grep -Ff  "$_zo.suf" "$1" 2>/dev/null; } | sort -u > "$_zo.hit"
    rm -f "$_zo" "$_zo.suf" 2>/dev/null || true
    grep -c . "$_zo.hit" 2>/dev/null || printf '0'
}

cmd_presets() {
    mkdir -p "$PRESETS_DIR"
    _px=$(u local_proxy_port); _px=${_px:-1603}
    _any=0

    for _name in $(u preset); do
        # Пресет может быть чисто подсетевым: ругаться, только если нет ни
        # доменной, ни подсетевой половины.
        _url=$(preset_url "$_name" 2>/dev/null || true)
        _su=$(preset_suburl "$_name" 2>/dev/null || true)
        if [ -z "$_url" ] && [ -z "$_su" ]; then
            warnf "неизвестный пресет: %s" "$_name"; continue
        fi
        _pf=$PRESETS_DIR/$_name.lst

        # Код -- сразу в переменную: после `if ! cmd; then` в $? результат
        # отрицания, и «не скачалось» от «не то скачалось» не отличить.
        if [ -n "$_url" ]; then
            fetch_list "$_url" "$_pf" dom "$_name" && _fr=0 || _fr=$?
            if [ "$_fr" = 2 ]; then
                if [ -s "$_pf" ]; then
                    warnf "%s: не скачался, остаётся прежняя копия" "$_name"
                else
                    warnf "%s: не скачался, и прежней копии нет — список пуст" "$_name"
                fi
            fi
            [ "$_fr" = 0 ] || continue
        fi

        # Подсети -- вторым файлом; отказ не отменяет принятые домены.
        if [ -n "$_su" ] && fetch_list "$_su" "$PRESETS_DIR/$_name.sub" net "$_name"; then
            sayf "%s: подсетей %s" "$_name" "$(count_list "$PRESETS_DIR/$_name.sub")"
            net_warn "$PRESETS_DIR/$_name.sub"
            # Чисто подсетевой пресет тоже удачный: иначе после загрузки
            # подсетей итог гласил бы «ни один из списков не обновился».
            _any=1
        fi

        # Чисто подсетевому пресету «0 записей» не печатается: как отказ.
        [ -n "$_url" ] || continue
        _n=$(count_list "$_pf")
        sayf "%s: %s записей" "$_name" "$_n"
        say "  $(preset_about "$_name")"

        # Пересечение с хостлистом zapret нарушает «домен ровно в одном
        # месте»; снаружи это сбои при входе в аккаунт. В zap_overlap
        # grep -Fxf, не comm: в busybox comm нет, проверка молча давала 0
        # вместо 4.
        _ov=$(zap_overlap "$_pf")
        if [ "${_ov:-0}" -gt 0 ]; then
            warnf "  %s записей ЛЕЖАТ И В ХОСТЛИСТЕ ZAPRET — домен должен быть в одном месте:" "$_ov"
            head -8 /tmp/byway-zap.$$.hit 2>/dev/null | sed 's/^/      /'
            warn "  иначе одна сессия разъедется на два выхода: это видно не отказом, а сбоями при входе в аккаунт"
        fi
        rm -f /tmp/byway-zap.$$.hit 2>/dev/null || true
        _any=1
    done

    # Свой список сверяется тоже: домены добавляют руками именно в него.
    _ov2=$(zap_overlap "$LISTS/domains.lst")
    if [ "${_ov2:-0}" -gt 0 ]; then
        warnf "  свой список: %s записей пересекаются с хостлистом zapret" "$_ov2"
        head -8 /tmp/byway-zap.$$.hit 2>/dev/null | sed 's/^/      /'
        warn "  домен должен быть в одном месте: иначе одна сессия разъедется на два выхода"
    fi
    rm -f /tmp/byway-zap.$$.hit 2>/dev/null || true

    _pinf=$(hosts_in_subnets "$(merged_subnets)")
    if [ "${_pinf:-0}" -gt 0 ]; then
        warnf "  пинов из /etc/hosts внутри подсетей byway: %s" "$_pinf"
        warn "  их адреса уйдут в туннель, хотя пин ставят затем, чтобы шли мимо"
    fi

    # По объединённому списку: в пресетах тысячи записей, перекрытие вероятнее.
    _pind=$(hosts_vs_domains "$(merged_domains)")
    if [ "${_pind:-0}" -gt 0 ]; then
        warnf "  пинов в /etc/hosts перебивают записи списка: %s" "$_pind"
        warn "  dnsmasq ответит по пину, подставного адреса не будет — в туннель они НЕ пойдут"
        warn "  и запрет «не пускать мимо VPN» их не закроет: пин старше address=/домен/"
    fi

    # Три исхода: обновилось (молчим), ничего не подключено, подключено, но
    # не скачалось -- сообщения разные, чтобы не искать подключение зря.
    if [ "$_any" = "1" ]; then
        :
    elif [ -z "$(u preset)" ]; then
        say "ни одного готового списка не подключено"
        say "  что бывает:"
        for _pk in $(preset_names); do
            printf '    %-20s %s\n' "$_pk" "$(preset_about "$_pk")"
        done
        say "  подключить: uci add_list byway.main.preset=ИМЯ && uci commit byway && byway presets"
    else
        warn "ни один из подключённых списков не обновился — прежние копии остались на месте"
    fi
}

route_names() {
    uci show byway 2>/dev/null | sed -n 's/^byway\.\([^.]*\)=route$/\1/p'
}

# Ссылка ключа по метке (метка видна в списке ключей).
route_key() {
    for _rk in $(uci -q get byway.main.node_urls 2>/dev/null || true); do
        case "$_rk" in *#*) _rl=$(pctd "${_rk#*#}") ;; *) _rl="" ;; esac
        [ "$_rl" = "$1" ] && { printf '%s' "$_rk"; return 0; }
    done
    return 1
}

# Не звать и не заводить это имя заново: настоящая классификация «сеть или
# домен» -- в route_list, правило там строже; две функции на один вопрос
# разойдутся.
is_net_unused() {
    case "$1" in
        *[!0-9./]*) return 1 ;;
        *.*.*.*) ;;
        *) return 1 ;;
    esac
    return 0
}

# Список направления, разложенный надвое. $2 -- dom или net.
route_list() {
    [ -f "$1" ] || return 0
    awk -v want="$2" -v bad="$BADLIST" '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]\r]+$/, "")
        if ($0 == "" || substr($0,1,1) == "#" || substr($0,1,2) == "//") next
        # Пробел ВНУТРИ строки -- это не запись, а строка формата hosts
        # («0.0.0.0 example.com») либо запись с пометкой. Прежде пробелы
        # вырезались отовсюду, и такая строка СКЛЕИВАЛАСЬ в
        # «0.0.0.0example.com»: обе проверки формы она проходила, не совпадала
        # ни с чем никогда, в список отброшенных не попадала, и итог сборки
        # честно печатал «отброшено: 0». Ровно эту ловушку уже чинили в
        # fetch_list -- до списков направлений правка не доехала.
        if ($0 ~ /[[:space:]]/) { print $0 >> bad; next }
        isnet = ($0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/)
        if ((want == "net") == isnet) print }' "$1"
}

# Записи списка, которые можно спросить у резолвера: без regexp:/keyword:
# (по ним nslookup не отвечает, и проба на одной такой строке объявила бы отказ
# исправному туннелю) и без префиксов domain:/full:. return 0 нужен: grep без
# совпадений даёт 1, а `_d=$(plain_domains …)` под set -e на нём молча умирает.
plain_domains() {
    grep -vE '^[[:space:]]*(//|#|$)' "$1" 2>/dev/null | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
      sed -e 's/^domain://' -e 's/^full://' |
      grep -E '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' |
      grep -E '\.[A-Za-z][A-Za-z]+$' || true
    return 0
}

# Свой список подсетей плюс подключённых пресетов и включённых направлений,
# одним файлом (отдаётся путь). Читают сборка конфига, набор nft и kill
# switch -- все обязаны видеть одно и то же, иначе подсеть из конфига, но не
# из правил ядра, снимает обвязку целиком.
# Кэш нужен, потому что потребителей семеро (сторож раз в 5 мин, health, top)
# и без него каждый гнал бы полную склейку и сортировку: на 200 000 записей
# 12 МБ в tmpfs, 288 раз в сутки. Годен, если слепок источников совпал,
# источники не новее файла и файл не новее слепка: /tmp общий, подложенный
# список решал бы, что идёт в туннель. Слепок нужен, потому что снятая в
# панели галочка пресета файлов не трогает.
merged_subnets() {
    _s=/tmp/byway-subnets-all.lst
    _st=$_s.$$
    # Слепок источников; свой файл не входит -- ловится временем правки.
    _ssig="$(u preset)|"
    for _rs2 in $(route_names); do
        [ "$(uci -q get "byway.$_rs2.enabled")" = "0" ] && continue
        _ssig="$_ssig$_rs2 "
    done
    if [ -f "$_s" ] && [ "$(cat "$_s.sig" 2>/dev/null || true)" = "$_ssig" ]; then
        _sold=0
        # Файл новее своего слепка -- трогали не мы (слепок пишется сразу после
        # файла): пересобрать.
        [ -n "$(find "$_s" -newer "$_s.sig" 2>/dev/null)" ] && _sold=1
        for _mf in "$LISTS/subnets.lst" \
                   $(for _p in $(u preset); do echo "$PRESETS_DIR/$_p.sub"; done) \
                   $(for _r in $(route_names); do echo "$ROUTES_DIR/$_r.lst"; done); do
            [ -f "$_mf" ] || continue
            if [ -n "$(find "$_mf" -newer "$_s" 2>/dev/null)" ]; then _sold=1; break; fi
        done
        if [ "$_sold" = 0 ]; then printf '%s' "$_s"; return 0; fi
    fi
    cat "$LISTS/subnets.lst" 2>/dev/null > "$_st"
    # Подсети включённых направлений тоже: иначе адресная половина не попадала
    # в набор nft, трафик шёл напрямую, а доменная работала («направление
    # работает через раз»).
    for _rn3 in $(route_names); do
        [ "$(uci -q get "byway.$_rn3.enabled")" = "0" ] && continue
        [ -f "$ROUTES_DIR/$_rn3.lst" ] && route_list "$ROUTES_DIR/$_rn3.lst" net >> "$_st"
    done
    for _pn3 in $(u preset); do
        _pfs=$PRESETS_DIR/$_pn3.sub
        [ -f "$_pfs" ] && cat "$_pfs" >> "$_st"
    done
    # Пробел внутри строки не вырезается (см. fetch_list): проверки формы
    # дальше нет, склеенная запись ушла бы прямо в маршрутизацию.
    grep -vE '^[[:space:]]*(//|#|$)' "$_st" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
      sort -u > "$_st.s"
    mv "$_st.s" "$_s"
    printf '%s' "$_ssig" > "$_s.sig" 2>/dev/null || true
    rm -f "$_st" 2>/dev/null || true
    printf '%s' "$_s"
}

# Свой список доменов плюс включённые направления и подключённые пресеты,
# без повторов; отдаётся путь. Кэш и слепок -- как у merged_subnets.
merged_domains() {
    # Собирается сбоку и встаёт на место одним mv: читателей семеро, а усечение
    # рабочего файла держало его неполным до конца (gen читает путь секундами
    # позже). Замок в gen защищает только сборку от сборки.
    _m=/tmp/byway-domains-all.lst
    _mt=$_m.$$
    # Слепок: подключённые пресеты и включённые направления; снятая в UCI
    # галочка файлов не трогает.
    _msig="$(u preset)|"
    for _rs in $(route_names); do
        [ "$(uci -q get "byway.$_rs.enabled")" = "0" ] && continue
        _msig="$_msig$_rs "
    done
    if [ -f "$_m" ] && [ "$(cat "$_m.sig" 2>/dev/null || true)" = "$_msig" ]; then
        _mold=0
        # Файл новее слепка -- трогали не мы.
        [ -n "$(find "$_m" -newer "$_m.sig" 2>/dev/null)" ] && _mold=1
        for _mf in "$LISTS/domains.lst" \
                   $(for _p in $(u preset); do echo "$PRESETS_DIR/$_p.lst"; done) \
                   $(for _r in $(route_names); do echo "$ROUTES_DIR/$_r.lst"; done); do
            [ -f "$_mf" ] || continue
            if [ -n "$(find "$_mf" -newer "$_m" 2>/dev/null)" ]; then _mold=1; break; fi
        done
        if [ "$_mold" = 0 ]; then printf '%s' "$_m"; return 0; fi
    fi
    cat "$LISTS/domains.lst" 2>/dev/null > "$_mt"
    # Домены включённых направлений тоже: без подставного адреса их трафик не
    # попадёт в перехват. Только заведённые, не весь каталог: файл удалённого
    # направления продолжал бы уводить домены.
    for _rn2 in $(route_names); do
        [ "$(uci -q get "byway.$_rn2.enabled")" = "0" ] && continue
        [ -f "$ROUTES_DIR/$_rn2.lst" ] && route_list "$ROUTES_DIR/$_rn2.lst" dom >> "$_mt"
    done
    # Только подключённые пресеты, не весь каталог: иначе снятая в панели
    # галочка не отключала скачанную копию.
    for _pn in $(u preset); do
        _pf=$PRESETS_DIR/$_pn.lst
        [ -f "$_pf" ] && cat "$_pf" >> "$_mt"
    done
    grep -vE '^[[:space:]]*(//|#|$)' "$_mt" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
      sort -u > "$_mt.s"
    # Черновик с $$ в имени: общий делили бы два сборщика.
    mv "$_mt.s" "$_m"
    printf '%s' "$_msig" > "$_m.sig" 2>/dev/null || true
    rm -f "$_mt" 2>/dev/null || true
    printf '%s' "$_m"
}

# ── подписка ───────────────────────────────────────────────────────────────
# Подписка -- обычный https-адрес со списком ключей, не ключ. Тело отдаётся
# как есть, без раскодирования: подписки обычно base64, а на роутере нет ни
# base64, ни openssl (busybox, проверено 2026-09-03); разбирает панель (atob).
# Сначала через прокси byway: домен подписки может лежать в списке, и
# напрямую роутер до него не достанет.
cmd_sub() {
    _u=$1
    [ -n "$_u" ] || die "byway sub <адрес подписки>"
    case "$_u" in
      https://*) ;;
      # Открытый HTTP читается и правится на лету: подложенный ключ выиграл бы
      # по задержке, и туннель пошёл бы через чужой сервер.
      http://*) die "подписка по http:// не принимается: ключи в ней может подменить кто угодно на пути — нужен https://" ;;
      *) die "это не адрес подписки: ожидается https://" ;;
    esac

    # Подкоманда доступна держателю роли панели (ACL: exec byway с любыми
    # аргументами), а curl идёт от root: петля и приватные диапазоны отсекаются
    # до запроса. Имя разрешается здесь и проверяется результат (имя на
    # 127.0.0.1 прошло бы по букве). Редирект во внутренний диапазон не закрыт:
    # число редиректов ограничено, граница -- exec в acl.json.
    _sh=${_u#*://}; _sh=${_sh%%/*}; _sh=${_sh%%\?*}
    _sh=${_sh##*@}; _sh=${_sh%%:*}
    case "$_sh" in
      localhost|localhost.*|*.localhost) die "адрес подписки указывает на сам роутер" ;;
    esac
    _sip=$_sh
    case "$_sh" in
      *[a-zA-Z]*) _sip=$(a_of "$_sh") ;;
    esac
    case "${_sip:-0.0.0.0}" in
      127.*|0.*|10.*|192.168.*|169.254.*|198.18.*|198.19.*|\
      172.1[6-9].*|172.2[0-9].*|172.3[01].*)
        dief "адрес подписки ведёт внутрь сети (%s) — byway туда не ходит" "${_sip:-?}" ;;
    esac

    _px=$(u local_proxy_port); _px=${_px:-1603}
    _raw=$(curl -fsSL --max-time 25 --max-redirs 3 -A "Mozilla/5.0" \
           --proxy "http://127.0.0.1:$_px" "$_u" 2>/dev/null || true)
    if [ -z "$_raw" ]; then
        _raw=$(curl -fsSL --max-time 25 --max-redirs 3 -A "Mozilla/5.0" "$_u" 2>/dev/null || true)
    fi
    [ -n "$_raw" ] || die "подписка не скачалась: стоит проверить адрес и связь"
    printf '%s\n' "$_raw"
}
