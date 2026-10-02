# Перехват: таблица nft, ip rule и маршрут, dnsmasq на DNS-вход Xray, запрет
# «Не пускать мимо VPN» (block_on/off). Служба и сторож входят через
# cmd_plumb on|off|close под общим замком.

CANARY=/use-application-dns.net/
# -- обвязка nft ------------------------------------------------------------
# Трафик доверенных мостов к пулу fakeip и подсетям списка уходит в tproxy-вход
# Xray, остальное не трогается. Своя таблица, а не правила в fw4: откат --
# `nft delete table inet byway`, fw4 чужие таблицы при перезагрузке не сносит.
# `tproxy ip to :порт` без адреса: форма с 127.0.0.1 требует route_localnet=1,
# то есть снятия защиты от подделки адресов. Метка ставится через `or`:
# троттлинг метит трафик 0x2 (/etc/conncheck.nft), присваивание затёрло бы её и
# сломало шейпер; ip rule поэтому сверяет по маске.

TABLE=byway
# Хостлист zapret: путь в одном месте, сверяют с ним из двух мест.
ZAPHOSTS=/opt/zapret/ipset/zapret-hosts-user.txt
# Номер таблицы не больше 255: busybox ip на 1602 отвечает 'invalid argument to
# table ID' (проверено 2026-09-03).
RT_TABLE=100
# Отметка «маршрут завёл byway», в памяти: маршрут перезагрузку не переживает.
RT_MINE=/tmp/byway-route-mine
RT_MINE6=/tmp/byway-route-mine6
# Приватное и зарезервированное. 198.18.0.0/15 (пул fakeip) сюда не входит:
# общий return съел бы пул, и этот набор можно проверять первым.
RESERVED="0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 224.0.0.0/4, 240.0.0.0/4"
# fc00::/7 входит, хотя пул v6 внутри него: правило пула стоит в цепочке выше.
# Без него в режиме «всё через VPN» домашний NAS на fd00:: ушёл бы в туннель.
RESERVED6="::1/128, ::/128, ::ffff:0:0/96, fe80::/10, ff00::/8, fc00::/7"
# Умолчание -- константа Xray (fakedns.go, FakeIPv6Pool): ULA в интернете не
# маршрутизируется, с настоящим адресом пул не столкнётся.
POOL6_DEF="fc00::/18"
# -- dnsmasq ----------------------------------------------------------------
# Резолвер уводится на DNS-вход Xray. noresolv обязателен: без него dnsmasq
# шлёт запрос и провайдеру, берёт первый ответ, и часть доменов получает
# настоящий адрес вместо fakeip -- маршрут работает через раз, и не видно.
# Прежние значения -- в /etc/byway/dns-saved, откат их возвращает. Кэш dnsmasq
# не обнуляется: пул fakedns на 131 тыс. адресов не вытесняется, но таблица не
# переживает рестарт Xray -- старт службы сбрасывает кэш по HUP.
DNSSEC="dhcp.@dnsmasq[0]"
# Снимок dnsmasq -- в файл, не в UCI: `uci commit byway` дёргает procd-триггер
# перезагрузки службы и пишет во флеш на каждый цикл plumb off/on (ubi
# 43.7 МБ). Файл в /etc/byway переживает перезагрузку и внесён в keep-список
# прошивки.
DNSSAVE=$LISTS/dns-saved
# ── kill switch ────────────────────────────────────────────────────────────
# Закрытая модель (on_failure): без туннеля нет и доступа к списку. Домены --
# через dnsmasq (address=/домен/ в его каталоге добавок, тот в памяти): без
# движка резолвер отдаёт настоящие адреса, по адресу домен не узнать.
# Подсети -- правилами nft. Каталог добавок берётся из конфига dnsmasq: в имени
# хеш секции UCI (/tmp/dnsmasq.cfg01411c.d), после сброса он другой.
BLOCK_MARK=/tmp/byway-blocked

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
    _smk=$(nft_val mark "$(u mark)" '^0x[0-9a-fA-F]{1,8}$' 0x100000)
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
    _rm=$(u mark); _rm=${_rm:-0x100000}
    printf 'fwmark %s(/%s)?[[:space:]]+lookup %s([[:space:]]|$)' "$_rm" "$_rm" "$RT_TABLE"
}

# Заворот IPv6 выключен по умолчанию (как у passwall, OpenClash). Выключен --
# клиент получает AAAA и идёт мимо туннеля напрямую; об этом говорит doctor.
v6on() { [ "$(u ipv6)" = "1" ]; }

# Элементы набора IPv6 из файла списка (отдельно от set_elements: у семейств
# разные наборы). Проверяется форма, а не весь разбор -- судит ядро; задача --
# не дать мусору обрушить всю таблицу (inet одна на оба семейства). Отвергнутое
# уходит в $BADLIST, byway называет его при сборке.
set_elements6() {
    [ -f "$1" ] || return 0
    awk -v bad="$BADLIST" '
      { gsub(/[[:space:]\r]/, "") }
      $0 == ""                  { next }
      /^(\/\/|#)/               { next }
      /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ { next }   # это IPv4, не наше
      {
        e = $0; pfx = ""
        i = index(e, "/")
        if (i) { pfx = substr(e, i + 1); e = substr(e, 1, i - 1) }
        # ⚠️ Форма разбирается ЦЕЛИКОМ, а не «не больше восьми групп». Прежняя
        # редакция проверяла только верхнюю границу числа групп и длину
        # каждой, и признавала годными «2001:db8:», «1:::2» и пустую группу
        # посреди адреса. Строка уходила в elements, а ядро отвергало ВЕСЬ
        # документ одной транзакцией -- вместе с ветками по доменам и по
        # IPv4, потому что таблица inet одна на оба семейства. На сторожевом
        # пути вывод cmd_plumb on глушится, и наружу уходил только флаг
        # «(failed)» без текста ошибки nft. Найдено четвёртым аудитом, заход 3.
        ok = 1
        if (e !~ /^[0-9a-fA-F:]+$/) ok = 0
        if (index(e, ":") == 0) ok = 0
        # Двойное двоеточие допустимо ровно одно.
        t = e; c = 0
        while ((j = index(t, "::")) > 0) { c++; t = substr(t, j + 2) }
        if (c > 1) ok = 0
        if (ok && c == 1) {
            # Режем по «::» и считаем половины. Пустая ПОЛОВИНА законна
            # («::1», «fe80::»), пустая ГРУППА внутри половины -- нет: это
            # и есть «1:::2» и адрес с одиночным двоеточием по краю.
            p = index(e, "::")
            lft = substr(e, 1, p - 1); rgt = substr(e, p + 2); ng = 0
            if (lft != "") { nl = split(lft, gl, ":")
                             for (k = 1; k <= nl; k++)
                                 if (gl[k] == "" || length(gl[k]) > 4) ok = 0
                             ng += nl }
            if (rgt != "") { nr = split(rgt, gr, ":")
                             for (k = 1; k <= nr; k++)
                                 if (gr[k] == "" || length(gr[k]) > 4) ok = 0
                             ng += nr }
            # «::» обязано сжимать хотя бы одну группу.
            if (ng > 7) ok = 0
        } else if (ok) {
            n = split(e, g, ":")
            if (n != 8) ok = 0
            for (k = 1; k <= n; k++)
                if (g[k] == "" || length(g[k]) > 4) ok = 0
        }
        if (pfx != "") { if (pfx !~ /^[0-9]+$/ || pfx + 0 > 128) ok = 0 }
        if (!ok) { print $0 >> bad; next }
        if (m++) printf ", "
        printf "%s", $0
      }' "$1"
}

# Элементы набора IPv4 из файла списка через запятую; пустой список -- пустая
# строка (набор создаётся всё равно, иначе правило сошлётся на несуществующий).
# Пропускается только адрес или сеть IPv4: одна чужая строка отвергалась ядром
# вместе со всем набором. Отброшенное уходит в $BADLIST и называется вслух.
set_elements() {
    [ -f "$1" ] || return 0
    awk -v bad="$BADLIST" '
      { gsub(/[[:space:]\r]/, "") }
      $0 == ""                  { next }
      /^(\/\/|#)/               { next }
      # Это IPv6, им занят set_elements6. Зеркальная строка-пропуск: без неё
      # годная подсеть IPv6 уходила в общий список отброшенных, и `byway
      # report` печатал «отброшено строк: N» по числу заведённых записей v6 --
      # отчёт для обращения врал про данные пользователя. Найдено четвёртым
      # аудитом, заход 3.
      /:/                       { next }
      {
        ok = 1
        if ($0 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) ok = 0
        else {
          n = split($0, a, /[.\/]/)
          for (i = 1; i <= 4; i++) if (a[i] + 0 > 255) ok = 0
          if (n == 5 && a[5] + 0 > 32) ok = 0
        }
        if (!ok) { print $0 >> bad; next }
        if (m++) printf ", "
        printf "%s", $0
      }' "$1"
}

nft_ruleset() {
    _pool=$(nft_val fakeip_pool "$(u fakeip_pool)" \
            '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' 198.18.0.0/15)
    _mark=$(nft_val mark "$(u mark)" '^0x[0-9a-fA-F]{1,8}$' 0x100000)
    _port=$(nft_val tproxy_port "$(u tproxy_port)" '^[0-9]{1,5}$' 1602)
    _ifs=$(nft_val interface "$(u interface)" \
           '^[A-Za-z0-9._-]+( [A-Za-z0-9._-]+)*$' br-lan)
    _iflist=$(echo "$_ifs" | awk '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1?", ":""), $i}')
    _nets=$(set_elements "$(merged_subnets)")

    _pool6=$(nft_val fakeip6_pool "$(u fakeip6_pool)" \
             '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$POOL6_DEF")
    _nets6=$(set_elements6 "$(merged_subnets)")
    _rport=$(redir_port "$(_t 'правил nft')")
    # IPv6 -- в той же таблице inet. _v6self считается до сборки цепочки
    # заворота: иначе правило v6 в неё не попадало, а nft -c этого не видел.
    # Порядок у v6 иной, чем у v4: пул fc00::/18 лежит внутри fc00::/7 (он в
    # privnets6), поэтому правило пула выше отсечки приватного. Две отсечки по
    # fib нужны, потому что глобального префикса роутера в privnets6 нет
    # (выдаёт провайдер): иначе в режиме «всё через VPN» трафик к самому
    # роутеру и к соседям по дому уходил бы в catch-all.
    _v6sets=""; _v6pre=""; _v6catch=""; _v6self=""
    if v6on; then
        if [ -n "$_nets6" ]; then _n6line="elements = { $_nets6 }"; else _n6line=""; fi
        _v6sets="
	set fakeip6 {
		type ipv6_addr
		flags interval
		elements = { $_pool6 }
	}
	set privnets6 {
		type ipv6_addr
		flags interval
		elements = { $RESERVED6 }
	}
	set subnets6 {
		type ipv6_addr
		flags interval
		auto-merge
		$_n6line
	}"
        _v6pre="
		ip6 daddr @fakeip6 meta l4proto { tcp, udp } counter tproxy ip6 to :$_port meta mark set meta mark or $_mark accept
		ip6 daddr @privnets6 return
		meta nfproto ipv6 fib daddr . iif type { local, broadcast, multicast } return
		meta nfproto ipv6 fib daddr oifname { $_iflist } return"
        _v6self="
		ip6 daddr @fakeip6 meta l4proto tcp counter redirect to :$_rport"
    fi

    # Цепочка output (заворот трафика самого роутера) -- только при включённом
    # redir. Заворачивается один пул fakeip, не подсети списка: в подсети можно
    # вписать диапазон хостера, и движок завернул бы в себя своё же соединение
    # к серверу. Приоритет -100 числом: имя dstnat nftables 1.0.2 здесь не
    # понимает и отвергает всю таблицу (стенд 22.03.7, 2026-09-07).
    if [ -n "$_rport" ]; then
        # Пропуск своего трафика движка -- первым правилом (см. self_mark).
        _selfchain="
	chain output {
		type nat hook output priority -100; policy accept;
		meta mark $(self_mark) return
		ip daddr @fakeip meta l4proto tcp counter redirect to :$_rport$_v6self
	}"
    else
        _selfchain=""
    fi

    # Режим списков: пул fakeip и подсети. Режим «всё через VPN»: всё, что
    # дошло сюда, -- приватное и адреса роутера отсечены выше набором privnets.
    if [ "$(u list_mode)" = "all" ]; then
        # Семейство у tproxy явное: `ip to` для пакета IPv6 не сработает, и
        # наоборот.
        _catch="meta nfproto ipv4 meta l4proto { tcp, udp } counter tproxy ip to :$_port meta mark set meta mark or $_mark accept"
        if v6on; then _v6catch="
		meta nfproto ipv6 meta l4proto { tcp, udp } counter tproxy ip6 to :$_port meta mark set meta mark or $_mark accept"; fi
    else
        _catch="ip daddr @fakeip meta l4proto { tcp, udp } counter tproxy ip to :$_port meta mark set meta mark or $_mark accept
		ip daddr @subnets meta l4proto { tcp, udp } counter tproxy ip to :$_port meta mark set meta mark or $_mark accept"
        if v6on; then _v6catch="
		ip6 daddr @subnets6 meta l4proto { tcp, udp } counter tproxy ip6 to :$_port meta mark set meta mark or $_mark accept"; fi
    fi
    # `elements = {  }` -- синтаксическая ошибка nft: пустой subnets.lst
    # обрушил бы всю таблицу. Набор без элементов nft принимает.
    if [ -n "$_nets" ]; then _netsline="elements = { $_nets }"; else _netsline=""; fi

    # Redir-in при включённом IPv6 слушает «::», то есть все интерфейсы.
    # Заворот приходит на него через lo (iif lo return выше), так что порт для
    # остальных закрывается безусловно.
    _rdrop=""
    if [ -n "$_rport" ]; then
        _rdrop="
		meta l4proto tcp th dport $_rport counter drop"
    fi
    # block_quic (пусто = включено): ключи поверх TCP везут UDP внутри TCP, и
    # QUIC там висит молча (Discord 2026-10-01, сообщения по 15--38 с); reject
    # переводит клиента на HTTP/2. Правило в input по метке перехвата (в
    # prerouting reject нельзя), только на Initial QUIC v1/v2: OpenVPN, DTLS и
    # WireGuard на udp/443 не задеваются. Синтаксис принят nftables 1.0.2.
    _quic=""
    if [ "$(u block_quic)" != "0" ]; then
        _quic="
		meta mark & $_mark == $_mark udp dport 443 @th,64,8 & 0xc0 == 0xc0 @th,72,32 { 0x00000001, 0x6b3343cf } counter reject"
    fi

    # Прелюдия table/delete: `nft -f` доливает в существующую таблицу, и
    # `nft -c` при старой таблице в ядре давал «interval overlaps» на
    # безупречном наборе (сужение пула /15 -> /24). Заодно снятие и укладка
    # идут одной транзакцией, без окна без правил.
    cat <<NFT
table inet $TABLE
delete table inet $TABLE
table inet $TABLE {
	set fakeip {
		type ipv4_addr
		flags interval
		elements = { $_pool }
	}
	# ⚠️ Имя набора -- НЕ «reserved», и это не вкусовщина. У nftables 1.0.2
	# (OpenWrt 22.03, наша нижняя граница) слово reserved -- ключевое, и
	# набор с таким именем отвергается вместе со ВСЕЙ таблицей: обвязка не
	# встаёт вовсе. Установка при этом проходит, движок стартует, порт
	# слушает -- снаружи всё выглядит исправным. Проверено на стенде
	# 2026-09-07: набор с этим именем ядро 22.03 не принимает, privnets
	# принимает; на 25.12.5 проходят оба.
	#
	# Отсюда урок дороже самой правки: проверка разбором доказывает
	# согласие ТОГО ядра, на котором запущена, а не самого старого из
	# поддерживаемых. Стенд nft-check.sh гонял правила против ядра нашего
	# роутера и потому молчал всё это время.
	#
	# И ни одной обратной кавычки в этом комментарии: он идёт в набор
	# через heredoc без кавычек у метки, то есть оболочка ВЫПОЛНИТ всё,
	# что в них стоит. Именно так первая редакция этого текста запустила
	# reserved и nft -c на роутере. Третий раз за день.
	set privnets {
		type ipv4_addr
		flags interval
		elements = { $RESERVED }
	}
	set subnets {
		type ipv4_addr
		flags interval
		auto-merge
		$_netsline
	}$_v6sets
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;

		# Только доверенные мосты. br-iot сюда не входит намеренно.
		iifname != { $_iflist } return

		# Приватное и адреса самого роутера -- вон, и ПЕРВЫМ делом.
		# Пул 198.18.0.0/15 в этот набор не входит, поэтому он ничего из
		# нужного не съедает.
		#
		# Раньше этот return стоял третьим, а короткое замыкание по сокету --
		# первым, и получалось, что пакет, адресованный САМОМУ РОУТЕРУ на порт
		# tproxy, успевал получить метку. Правило firewall принимает по метке,
		# и гостевая зона с политикой input REJECT переставала держать гостя:
		# вход Xray превращался в форвардер, доступный из гостевой сети.
		ip daddr @privnets return$_v6pre

		# Короткое замыкание для пакетов уже установленной сессии: сокет
		# найден и он прозрачный. Экономит разбор на каждом пакете. Стоит
		# после return выше, поэтому до адресов роутера не дотягивается.
		meta l4proto { tcp, udp } socket transparent 1 meta mark set meta mark or $_mark accept

		$_catch$_v6catch
	}

	# Вход tproxy слушает 0.0.0.0 -- иначе он не работает вовсе: tproxy НЕ
	# переписывает адрес назначения, и на петле пакет с исходным 198.18.x.x
	# просто не появится. Плата за это -- открытый порт, до которого дотянется
	# любое устройство доверенной сети: подключившись к нему напрямую, оно
	# получает вход Xray в своё распоряжение.
	#
	# Закрываем здесь, а не политикой зоны: настоящий перехваченный трафик
	# приходит в input с ИСХОДНЫМ портом назначения (443 и прочие), а не с
	# нашим. Значит правило по dport бьёт ровно по прямым обращениям и
	# работающего туннеля не касается вовсе.
	#
	# Семейство inet -- значит и IPv4, и IPv6 одним правилом: слушающий
	# сокет отвечает на обоих, и закрывать надо оба.
	chain input {
		type filter hook input priority filter - 10; policy accept;
		iif lo return$_quic
		meta l4proto { tcp, udp } th dport $_port counter drop$_rdrop
	}
$_selfchain
}
NFT
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
    _mark=$(u mark); _mark=${_mark:-0x100000}
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
    _mark=$(u mark); _mark=${_mark:-0x100000}
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

dns_save_read() {   # $1 -- noresolv | server
    if [ ! -f "$DNSSAVE" ]; then
        # Подъём прежней редакцией (снимок в UCI), снятие этой: без чтения UCI
        # возврат отдал бы пустоту.
        case "$1" in
          noresolv) uci -q get byway.main.saved_noresolv || true ;;
          server)   uci -q get byway.main.saved_server   || true ;;
        esac
        return 0
    fi
    case "$1" in
      noresolv) sed -n '1s/^noresolv=//p' "$DNSSAVE" ;;
      server)   sed -n 's/^server=//p' "$DNSSAVE" ;;
      listen)   sed -n 's/^listen=//p' "$DNSSAVE" ;;
    esac
}

# На кого нацелен РАБОТАЮЩИЙ dnsmasq: 0 -- какой-то процесс поднят с нашим
# адресом, 1 -- конфиги прочитаны, адреса нет, 2 -- не знаю (процессов нет или
# конфиг не прочитался). Читается файл из `-C` командной строки процесса (у
# ujail он после `--`), не UCI: наша правка UCI -- некоммиченная дельта и на
# запущенный процесс не влияет. Процессов может быть несколько (гостевой
# экземпляр), HUP конфиг не перечитывает. Лишний рестарт -- 9 с без DNS,
# пропущенный -- дом без DNS, поэтому на «не знаю» вызывающие рестартуют.
dns_live_ok() {   # $1 -- наш адрес
    # Процессов нет -- «не знаю»: dnsmasq остановлен чужой рукой (LuCI держит
    # его выключенным 9 с), а ответ «не наш» оставил бы в его конфиге наш адрес
    # без движка.
    _dpids=$(pgrep -x dnsmasq 2>/dev/null || true)
    [ -n "$_dpids" ] || return 2
    _dseen=0
    for _dpid in $_dpids; do
        _dcf=$(tr '\0' '\n' < "/proc/$_dpid/cmdline" 2>/dev/null |
               awk 'p { print; exit } /^-C$/ { p = 1 }')
        [ -n "$_dcf" ] && [ -r "$_dcf" ] || continue
        _dseen=1
        # if, а не `&& return`: несовпадение при set -e выходит из скрипта.
        if grep -qx "server=$1" "$_dcf" && grep -qx "no-resolv" "$_dcf"; then
            return 0
        fi
    done
    [ "$_dseen" = "1" ] || return 2
    return 1
}

# HUP чистит кэш и перечитывает hosts, не роняя сокеты; рестарт -- 9 с без DNS
# (замер 2026-09-07). Сброс после рестарта движка обязателен: таблица fakedns в
# памяти Xray (claude.ai был 198.18.68.107, стал 198.19.231.105).
dns_flush() {
    killall -HUP dnsmasq 2>/dev/null || true
}

dns_up() {
    _l=$(dns_addr)
    # Перенос снимка из UCI старой редакции: иначе файл собрался бы из нашего
    # же адреса, и plumb off вернул бы нерабочий резолвер.
    if [ ! -f "$DNSSAVE" ] && [ "$(uci -q get byway.main.dns_saved)" = "1" ]; then
        {
            printf 'noresolv=%s\n' "$(uci -q get byway.main.saved_noresolv 2>/dev/null || echo 0)"
            for s in $(uci -q get byway.main.saved_server 2>/dev/null); do
                printf 'server=%s\n' "$s"
            done
        } > "$DNSSAVE"
    fi
    if [ ! -f "$DNSSAVE" ]; then
        {
            printf 'noresolv=%s\n' "$(uci -q get "$DNSSEC.noresolv" 2>/dev/null || echo 0)"
            for s in $(uci -q get "$DNSSEC.server" 2>/dev/null); do
                # Свой адрес в снимок не пишем, но только его, а не всю петлю:
                # чужой резолвер на 127.* (https-dns-proxy, stubby) терялся бы
                # навсегда. Если dns_listen сменили без снимка, прежний наш
                # адрес попадёт как чужой.
                [ "$s" = "$_l" ] && continue
                printf 'server=%s\n' "$s"
            done
            # Свой адрес отдельной строкой: по нему, а не по текущей настройке,
            # dns_down решает, наша ли правка в dnsmasq (после смены dns_listen
            # они расходятся).
            printf 'listen=%s\n' "$_l"
        } > "$DNSSAVE"
    fi
    # Доменные записи server=/дом/адрес остаются: это раздельный резолв своей
    # сети.
    for s in $(uci -q get "$DNSSEC.server" 2>/dev/null); do
        case "$s" in
          /*) ;;
          *) uci -q del_list "$DNSSEC.server=$s" 2>/dev/null || true ;;
        esac
    done
    uci add_list "$DNSSEC.server=$_l"
    # Канарейка: NXDOMAIN на use-application-dns.net выключает DoH у Firefox
    # (иначе он идёт мимо byway); `server=/имя/` без адреса даёт NXDOMAIN.
    _dnew=0
    case " $(uci -q get "$DNSSEC.server" 2>/dev/null) " in
      *" $CANARY "*) ;;
      *) uci add_list "$DNSSEC.server=$CANARY"; _dnew=1 ;;
    esac
    uci set "$DNSSEC.noresolv=1"
    # Не коммитим: дельта в /tmp/.uci умирает с tmpfs. Закоммиченная правка
    # переживала потерю питания и sysupgrade при мёртвом Xray, и дом оставался
    # с резолвером в пустоту. Плата: «Сохранить» на странице DHCP в LuCI
    # закоммитит и нашу дельту -- тогда `byway plumb off`. Рестарт -- только
    # если есть что менять (9 с без DNS у дома), кэш сбросит HUP. Новую строку
    # server dnsmasq читает лишь при рестарте: после HUP канарейка не вставала
    # (боевой, 2026-10-02).
    if dns_live_ok "$_l" && [ "$_dnew" = 0 ]; then
        dns_flush
    else
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
    fi
}

dns_down() {
    # revert снимает некоммиченную дельту без записи во флеш.
    uci -q revert dhcp 2>/dev/null || true

    # Дельту могли закоммитить со стороны («Сохранить» в LuCI) -- тогда
    # возвращаем явно. Свой адрес ищем среди значений списка (uci get отдаёт их
    # через пробел) и берём из снимка, не из текущей настройки: после смены
    # dns_listen они расходятся.
    _ours=$(dns_save_read listen)
    [ -n "$_ours" ] || _ours=$(dns_addr)
    case " $(uci -q get "$DNSSEC.server" 2>/dev/null) " in
      *" $_ours "*)
        # Снимок один, при первом подъёме: заведённые позже доменные записи
        # delete снёс бы.
        _dcur=$(uci -q get "$DNSSEC.server" 2>/dev/null || true)
        uci -q delete "$DNSSEC.server" 2>/dev/null || true
        _dseen=" "
        for s in $(dns_save_read server); do
            case "$_dseen" in *" $s "*) continue ;; esac
            _dseen="$_dseen$s "
            uci add_list "$DNSSEC.server=$s"
        done
        # Доменные записи, появившиеся после снимка, возвращаем; остальное
        # решает снимок.
        for s in $_dcur; do
            case "$s" in "$CANARY") continue ;; /*) ;; *) continue ;; esac
            case "$_dseen" in *" $s "*) continue ;; esac
            _dseen="$_dseen$s "
            uci add_list "$DNSSEC.server=$s"
        done
        if [ "$(dns_save_read noresolv)" = "1" ]; then
            uci set "$DNSSEC.noresolv=1"
        else
            uci -q delete "$DNSSEC.noresolv" 2>/dev/null || true
        fi
        uci commit dhcp
        ;;
    esac

    rm -f "$DNSSAVE" 2>/dev/null || true

    # Остатки прежней редакции (снимок в UCI): пустой commit тоже дёргает
    # триггер.
    if [ -n "$(uci -q get byway.main.dns_saved)" ]; then
        uci -q delete byway.main.dns_saved 2>/dev/null || true
        uci -q delete byway.main.saved_server 2>/dev/null || true
        uci -q delete byway.main.saved_noresolv 2>/dev/null || true
        uci commit byway
    fi
    # Зеркально dns_up: резолвер не наш -- рестарт чистая потеря (plumb off на
    # роутере без обвязки дёргал DNS дома), кэш сбрасываем всё равно. «Не знаю»
    # (2) считаем нашим: пропущенный рестарт хуже лишнего.
    _dlo=0; dns_live_ok "$_ours" || _dlo=$?
    if [ "$_dlo" != "1" ]; then
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
    else
        dns_flush
    fi
}

dnsmasq_confdir() {
    _cdir=$(grep -h '^conf-dir=' /var/etc/dnsmasq.conf.* 2>/dev/null |
            head -1 | cut -d= -f2- | cut -d, -f1)
    # `if` и return 0, а не `[ ] && printf`: код 1 при ненайденном каталоге
    # через присваивание у вызывающего убивает byway под set -e.
    if [ -n "$_cdir" ] && [ -d "$_cdir" ]; then printf '%s' "$_cdir"; fi
    return 0
}

block_on() {
    [ "$(u on_failure)" != "open" ] || return 0
    _ifs=$(u interface); _ifs=${_ifs:-br-lan}
    _ifl=$(echo "$_ifs" | awk '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1?", ":""), $i}')
    # Стоящий запрет пересобирается на месте, если сменились режим, сети, IPv6
    # или списки.
    _bsig=$( { u list_mode; echo "$_ifs"; v6on && echo v6; cat "$(merged_domains)" "$(merged_subnets)" 2>/dev/null; } | md5sum | cut -c1-32)
    if [ -f "$BLOCK_MARK" ] && [ "$(cat "$BLOCK_MARK.sig" 2>/dev/null)" = "$_bsig" ]; then
        return 0
    fi
    printf '%s\n' "$_bsig" > "$BLOCK_MARK.sig"

    # Режим «всё через VPN» закрывается отдельным правилом, не выжимкой из
    # списков: в этом режиме поставочные списки пусты, запрет не закрыл бы
    # ничего, а статус сообщил бы «доступ закрыт». Цепляется к forward, не к
    # output: движок должен достучаться до ноды, LuCI и ssh идут через input.
    # oifname пропускает свои мосты. Цепочка `forward`, не `fwd`: fwd
    # зарезервировано в nft, и ядро отвергает всю таблицу.
    if [ "$(u list_mode)" = "all" ]; then
        # Остаток режима списков (имена) здесь не нужен.
        _cdir=$(dnsmasq_confdir)
        if [ -n "$_cdir" ] && [ -f "$_cdir/byway-block.conf" ]; then
            rm -f "$_cdir/byway-block.conf"
            /etc/init.d/dnsmasq restart >/dev/null 2>&1
        fi
        # Прелюдия table/delete -- замена одной транзакцией (см. nft_ruleset).
        _nfterr=$(nft -f - 2>&1 <<NFTA || true
table inet ${TABLE}_block
delete table inet ${TABLE}_block
table inet ${TABLE}_block {
	set privnets {
		type ipv4_addr
		flags interval
		elements = { $RESERVED }
	}
	chain forward {
		type filter hook forward priority filter - 5; policy accept;
		iifname != { $_ifl } return
		oifname { $_ifl } return
		ip daddr @privnets return
		counter reject
	}
}
NFTA
)
        [ -n "$_nfterr" ] && warnf "«не пускать мимо VPN»: ядро не приняло правило — %s" \
            "$(printf '%s' "$_nfterr" | head -2 | tr '\n' ' ')"
        if nft list table inet "${TABLE}_block" >/dev/null 2>&1; then
            printf 'all\n' > "$BLOCK_MARK"
            # Не «весь трафик»: цепочка отсекает сети вне byway.main.interface.
            warn "туннеля нет, и трафик перечисленных сетей мимо VPN закрыт: так велит настройка «не пускать мимо VPN». Сети вне byway.main.interface запрет не закрывает"
        else
            # Молчать здесь нельзя: человек включил запрет и вправе знать, что
            # его нет.
            printf 'none\n' > "$BLOCK_MARK"
            warn "«не пускать мимо VPN»: ядро не приняло правило запрета — трафик идёт НАПРЯМУЮ"
        fi
        return 0
    fi
    block_dns
    block_nets
    if [ -n "$_nets" ] || [ -n "$_nets6" ]; then
        _nfterr=$(nft -f - 2>&1 <<NFTB || true
table inet ${TABLE}_block
delete table inet ${TABLE}_block
table inet ${TABLE}_block {$_b4set$_b6set
	chain forward {
		type filter hook forward priority filter - 5; policy accept;
		iifname != { $_ifl } return$_b4rule$_b6rule
	}
}
NFTB
)
        [ -n "$_nfterr" ] && warnf "«не пускать мимо VPN»: подсети закрыть не вышло — %s" \
            "$(printf '%s' "$_nfterr" | head -2 | tr '\n' ' ')"
        nft list table inet "${TABLE}_block" >/dev/null 2>&1 && _bl_net=1
    else
        nft delete table inet "${TABLE}_block" 2>/dev/null || true
    fi
    # Строка про закрытый доступ -- только когда есть что закрывать.
    if [ "${_bl_dom:-0}" -gt 0 ] || [ "${_bl_net:-0}" = 1 ]; then
        printf 'lists\n' > "$BLOCK_MARK"
        warnf "туннеля нет, и доступ к списку закрыт: доменов %s, подсети %s" \
              "$_bl_dom" "$([ "${_bl_net:-0}" = 1 ] && _t да || _t нет)"
    else
        printf 'none\n' > "$BLOCK_MARK"
        warn "«не пускать мимо VPN» включено, но закрывать нечего: списки пусты — трафик идёт НАПРЯМУЮ"
    fi
}

# Шаг block_on: домены списка закрываются через dnsmasq (address=/имя/).
block_dns() {
    _bl_dom=0
    _bl_net=0
    _cdir=$(dnsmasq_confdir)
    if [ -z "$_cdir" ]; then
        warn "«не пускать мимо VPN»: не найден каталог конфигов dnsmasq — домены закрыть нечем"
    else
        _bf=$_cdir/byway-block.conf
        # Через plain_domains, не сырым awk: формы Xray (`full:`, `domain:`)
        # писались в dnsmasq буквально -- файл проходит `--test`, но
        # закрывается несуществующий домен. keyword: и regexp: именем закрыть
        # нельзя (dnsmasq сопоставляет суффиксом) -- об этом говорим вслух.
        _bl_src=$(merged_domains)
        _bl_all=$(grep -cvE '^[[:space:]]*(//|#|$)' "$_bl_src" 2>/dev/null || true)
        _bl_all=${_bl_all:-0}
        # `address=/имя/` без адреса -- NXDOMAIN на любой тип; с 0.0.0.0
        # закрывалась лишь A, а AAAA и HTTPS dnsmasq 2.86+ уходили провайдеру
        # (2026-10-02).
        plain_domains "$_bl_src" |
          awk '{ printf "address=/%s/\n", $0 }' > "$_bf.new"
        # Синтаксис проверяем до подмены: битый файл не даст dnsmasq подняться.
        _bl_dom=$(grep -c . "$_bf.new" 2>/dev/null || true); _bl_dom=${_bl_dom:-0}
        if [ "$_bl_all" -gt "$_bl_dom" ]; then
            warnf "«не пускать мимо VPN»: %s записей списка нельзя закрыть по имени (keyword:, regexp: и подобные) — они останутся ОТКРЫТЫМИ" \
                  "$((_bl_all - _bl_dom))"
        fi
        if cmp -s "$_bf.new" "$_bf"; then
            rm -f "$_bf.new"
        elif dnsmasq --test -C "$_bf.new" >/dev/null 2>&1; then
            mv "$_bf.new" "$_bf"
            /etc/init.d/dnsmasq restart >/dev/null 2>&1
        else
            _bl_dom=0
            rm -f "$_bf.new"
            warn "«не пускать мимо VPN»: dnsmasq не принял список — домены остались ОТКРЫТЫМИ"
        fi
    fi
    return 0
}

# Шаг block_on: наборы подсетей v4 и v6 для таблицы запрета.
block_nets() {
    _nets=$(set_elements "$(merged_subnets)")
    # Подсети v6 закрываются тоже: при включённом заворачивании они
    # перехватываются, а закрывались только v4 -- запрет обещал больше, чем
    # делал.
    _nets6=""
    if v6on; then _nets6=$(set_elements6 "$(merged_subnets)"); fi
    _b4set=""; _b4rule=""
    if [ -n "$_nets" ]; then
        _b4set="
	set blocked {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $_nets }
	}"
        _b4rule="
		ip daddr @blocked counter reject"
    fi
    _b6set=""; _b6rule=""
    if [ -n "$_nets6" ]; then
        _b6set="
	set blocked6 {
		type ipv6_addr
		flags interval
		auto-merge
		elements = { $_nets6 }
	}"
        _b6rule="
		ip6 daddr @blocked6 counter reject"
    fi
    return 0
}

block_off() {
    _cdir=$(dnsmasq_confdir)
    if [ -n "$_cdir" ] && [ -f "$_cdir/byway-block.conf" ]; then
        rm -f "$_cdir/byway-block.conf"
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
    fi
    nft delete table inet "${TABLE}_block" 2>/dev/null || true
    rm -f "$BLOCK_MARK" "$BLOCK_MARK.sig" 2>/dev/null || true
}

cmd_nft() { nft_ruleset; }

# Дешёвый слепок обвязки для init-скрипта: те же входные данные, что у
# nft_ruleset, но без сборки (суммы файлов подсетей). Слепок берётся несколько
# раз на один `uci commit`, полная сборка списков не укладывалась в 20 с
# панели.
nft_sig() {
    # block_quic обязателен: он живёт только в правилах nft, без него reload не
    # видел смены.
    printf '%s|%s|%s|%s|%s|%s|' \
        "$(u fakeip_pool)" "$(u mark)" "$(u tproxy_port)" \
        "$(u interface)" "$(u list_mode)" "$(u block_quic)"
    {
        md5sum "$LISTS/subnets.lst" 2>/dev/null | cut -d' ' -f1
        for _ns in $(u preset); do
            md5sum "$PRESETS_DIR/$_ns.sub" 2>/dev/null | cut -d' ' -f1
        done
    } | md5sum | cut -d' ' -f1
}

cmd_nftsig() { nft_sig; }

cmd_plumb() {
    # Замок: у обвязки пять хозяев (старт службы, её фоновый цикл до 65 с,
    # reload, сторож из cron, консоль) и общая дельта UCI dhcp с правилами
    # ядра. return, а не die: cmd_watch зовёт через `if`, exit оборвал бы весь
    # прогон сторожа.
    _plock=/var/run/byway-plumb.lock
    take_lock "$_plock" "$(_t 'настройка перехвата')" || {
        warn "перехват уже настраивается другим запуском -- пропущено"
        return 1
    }
    trap 'rm -rf "$_plock" 2>/dev/null; true' EXIT INT TERM
    case "${1:-}" in
      on)
        plumb_fwrule
        # Метку «сняли намеренно» снимаем сразу: иначе неудачный подъём
        # оставлял сторожа запертым.
        rm -f "$PLUMB_DOWN" 2>/dev/null || true
        plumb_wait
        if [ $_i -ge 15 ]; then
            # Возвращаем dnsmasq провайдеру: иначе он остался бы с
            # закоммиченной правкой.
            dns_down
            # Закрыть до сообщения: между ними страница ушла бы мимо туннеля.
            block_on
            # return, а не dief: сюда сторож заходит чаще всего (движок жив, но
            # не отвечает), а exit обрывал бы весь его прогон -- журнал,
            # списки, автообновление.
            warnf "Xray-core не отвечает на %s:53 — перехват не включён, dnsmasq возвращён провайдеру" "$_l"
            rm -rf "$_plock" 2>/dev/null || true
            return 1
        fi

        # Сначала -c, и только потом снос старой таблицы: опечатка в подсетях
        # не должна оставить роутер без обвязки. Правила -- в переменной, не в
        # файле: фиксированное имя в общем /tmp открывается дважды (проверка и
        # применение видят разное) и пишет по симлинку, а занять его может
        # не-root (dnsmasq).
        _rules=$(nft_ruleset)
        # return 1, а не die: сторож зовёт через `if`, exit убил бы весь его
        # прогон.
        printf '%s\n' "$_rules" | nft -c -f - || {
            # Резолвер -- провайдеру, запрет -- по настройке, как в соседних
            # ветках отказа. На пути stop --keep-dns dnsmasq остаётся на нас, и
            # без правил дом получал бы подставные адреса без перехвата.
            warn "правила не приняты ядром, перехват не включён"
            dns_down
            block_on
            rm -rf "$_plock" 2>/dev/null || true
            return 1
        }
        # Маршрут до правил: его отказ не должен оставлять таблицу nft
        # (2026-09-03: правила легли, маршрута нет, подсети ушли в tproxy в
        # никуда).
        route_up

        # Таблицу сносит и кладёт сам набор, одной транзакцией. Итог укладки
        # читается: `nft -c` доказывает разбор, а не применение, и между
        # проверкой и укладкой идёт route_up -- чужой процесс (fw4, hotplug)
        # мог изменить таблицы. Без проверки дом получал подставные адреса без
        # правил перехвата.
        _nfte=""
        _nfte=$(printf '%s\n' "$_rules" | nft -f - 2>&1) || _nfte=${_nfte:-отказ без сообщения}
        if [ -n "$_nfte" ]; then
            warnf "правила не легли в ядро — %s" \
                  "$(printf '%s' "$_nfte" | head -2 | tr '\n' ' ')"
            # Маршрут снимаем: без правил он остался бы висеть в таблице 100.
            route_down
            # nft -f -- одна транзакция: при отказе прежняя таблица остаётся и
            # метит пакеты, а route_down снял правило и маршрут -- помеченным
            # ехать некуда (домены глохнут, подсети идут мимо туннеля).
            # Осиротевшую таблицу сносим.
            if nft list table inet "$TABLE" >/dev/null 2>&1; then
                _delerr=$(nft delete table inet "$TABLE" 2>&1 || true)
                [ -n "$_delerr" ] &&
                    warnf "прежняя таблица не снялась — %s" "$_delerr"
            fi
            # Резолвер -- провайдеру, запрет -- по настройке (как выше).
            dns_down
            block_on
            rm -rf "$_plock" 2>/dev/null || true
            return 1
        fi
        dns_up
        block_off
        rm -rf "$_plock" 2>/dev/null || true
        sayf "перехват включён: таблица inet %s, правило fwmark, dnsmasq -> %s" "$TABLE" "$(dns_addr)"
        ;;
      off)
        # Метка PLUMB_DOWN -- первым действием: dns_down рестартует dnsmasq
        # (секунды), и сторож в это окно видел «обвязки нет при живом движке» и
        # поднимал её поверх незаконченного снятия. --service метку не ставит:
        # если следующий старт провалится, сторож остался бы заперт до
        # перезагрузки. Флаги ищем во всей строке аргументов, не в $2 и $3.
        _pf=" $* "
        case "$_pf" in
          *" --service "*) ;;
          *) : > "$PLUMB_DOWN" 2>/dev/null || true ;;
        esac
        nft delete table inet $TABLE 2>/dev/null || true
        route_down
        # --keep-dns ставит рестарт службы, где следом идёт подъём: dnsmasq
        # вниз и обратно -- два окна по 9 с без DNS. Если движок не встанет,
        # plumb on сам зовёт dns_down. Отключить руками: byway plumb off
        case "$_pf" in
          *" --keep-dns "*) dns_flush ;;
          *) dns_down ;;
        esac
        # Запрет снимается вместе с обвязкой (иначе `plumb off` выглядел бы
        # поломкой интернета), кроме --keep-block: при мёртвом движке сторож
        # снимает обвязку, а запрет снимет ветка «движок вернулся». Флаг, а не
        # --service: после остановки службы запертый дом оставлять нельзя.
        case "$_pf" in
          *" --keep-block "*) ;;
          *) block_off ;;
        esac
        rm -rf "$_plock" 2>/dev/null || true
        case "$_pf" in
          *" --keep-dns "*) say "перехват снят, резолвер оставлен на месте" ;;
          *)                say "перехват снят, dnsmasq возвращён" ;;
        esac
        ;;
      close)
        # Закрыть, не поднимая обвязку (start_service при on_failure=closed).
        # Иначе после перезагрузки запрет встаёт лишь после ожидания движка (до
        # 15 с трижды), а dnsmasq уже отдаёт настоящие адреса: утечка ровно в
        # момент, ради которого запрет и включают.
        block_on
        ;;
      *) die "byway plumb on|off|close" ;;
    esac
}

# Шаг plumb on: правило firewall byway-tproxy сверяется с меткой (нет --
# заводится).
plumb_fwrule() {
        # Правило с меткой пишет установщик один раз, а метка настраивается:
        # после смены зона с input REJECT (гостевая) перестаёт пропускать
        # помеченный трафик, а doctor считает правила, не значение. Сверка --
        # до укладки своей таблицы: перезагрузка firewall сносит ruleset
        # целиком.
        _fwm=$(nft_val mark "$(u mark)" '^0x[0-9a-fA-F]{1,8}$' 0x100000)
        _fwr=$(uci -q get firewall.bywaytproxy.mark 2>/dev/null || true)
        # Правила нет (удалили, сброс firewall) -- заводим как установщик: без
        # него гостевая зона теряет туннель.
        if [ -z "$(uci -q get firewall.bywaytproxy 2>/dev/null)" ]; then
            uci -q set firewall.bywaytproxy=rule
            uci -q set firewall.bywaytproxy.name='byway-tproxy'
            uci -q set firewall.bywaytproxy.src='*'
            uci -q set firewall.bywaytproxy.proto='all'
            uci -q set firewall.bywaytproxy.mark="$_fwm/$_fwm"
            uci -q set firewall.bywaytproxy.target='ACCEPT'
            uci commit firewall
            /etc/init.d/firewall reload >/dev/null 2>&1 || true
            say "правила firewall для помеченного трафика не было — заведено заново"
            _fwr="$_fwm/$_fwm"
        fi
        if [ -n "$_fwr" ] && [ "$_fwr" != "$_fwm/$_fwm" ]; then
            sayf "метка сменилась (%s -> %s) — правило firewall переписывается" \
                 "$_fwr" "$_fwm/$_fwm"
            uci -q set firewall.bywaytproxy.mark="$_fwm/$_fwm"
            uci commit firewall
            /etc/init.d/firewall reload >/dev/null 2>&1 || true
        fi
    return 0
}

# Шаг plumb on: ждёт, пока Xray ответит на DNS-входе (до 15 с); _i=15 -- отказ.
plumb_wait() {
        # Xray должен отвечать до любой правки: dns_up уводит весь резолв на
        # его вход с noresolv, и при мёртвом Xray дом остался бы без DNS.
        _l=$(dns_addr)
        # Проба -- домен из объединённого списка: FakeDNS отвечает локально,
        # без WAN, так что меряется Xray, а не канал. Посторонний домен не
        # годился: его нет в fakedns ни в одном режиме.
        _probe=$(plain_domains "$(merged_domains)" | head -1)
        _i=0
        _gone=0
        while [ $_i -lt 15 ]; do
            if [ -n "$_probe" ]; then
                nslookup "$_probe" "$_l" 2>/dev/null | grep -qE "$(fakeip_re)" && break
            else
                # Списка нет -- достаточно, что резолвер отвечает.
                nslookup example.com "$_l" >/dev/null 2>&1 && break
            fi
            # Процесса движка нет пять проб подряд -- он падает при старте,
            # досиживать срок незачем: на рестарте дом без DNS, пока движок не
            # ответит. Пять, а не один: на холодной загрузке procd поднимает
            # движок не сразу.
            if [ -z "$(xray_pid)" ]; then
                _gone=$((_gone + 1))
                if [ "$_gone" -ge 5 ]; then
                    warn "движок не запущен — перехват не включён, ожидание прервано"
                    _i=15
                    break
                fi
            else
                _gone=0
            fi
            _i=$((_i + 1)); sleep 1
        done
    return 0
}
