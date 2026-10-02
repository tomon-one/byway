# Готовые наборы (presets): загрузка, проверка, пересечения с /etc/hosts.

# ── пресеты ────────────────────────────────────────────────────────────────
# Готовые списки доменов вместо своего или вместе с ним. Каталог здесь, а
# не в панели: панель может не стоять. Пресеты никто не проверяет, кроме их
# авторов (itdoginfo 2026-09-04: из 37 новых записей 4 уже в хостлисте zapret,
# 2 -- убранный сервис, 2 -- мусор), поэтому после загрузки byway говорит о
# пересечениях.
PRESETS_DIR=$LISTS/presets

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
