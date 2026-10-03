# Таблица nft перехвата: наборы адресов и правила tproxy.

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

# Приватное и зарезервированное. 198.18.0.0/15 (пул fakeip) сюда не входит:
# общий return съел бы пул, и этот набор можно проверять первым.
RESERVED="0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 224.0.0.0/4, 240.0.0.0/4"

# fc00::/7 входит, хотя пул v6 внутри него: правило пула стоит в цепочке выше.
# Без него в режиме «всё через VPN» домашний NAS на fd00:: ушёл бы в туннель.
RESERVED6="::1/128, ::/128, ::ffff:0:0/96, fe80::/10, ff00::/8, fc00::/7"

# Умолчание -- константа Xray (fakedns.go, FakeIPv6Pool): ULA в интернете не
# маршрутизируется, с настоящим адресом пул не столкнётся.
POOL6_DEF="fc00::/18"

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
		ip6 daddr @fakeip6 counter drop
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
    # Не завернулось -- брось. tproxy без слушающего сокета (движок упал, procd
    # ждёт respawn) пакет не роняет, а пропускает дальше по цепочке, и тот
    # уходил в WAN напрямую. Пул fakeip наружу не нужен никогда; подсети списка
    # и «всё через VPN» -- только при «Не пускать». С живым движком сюда не
    # доходит: tproxy кончается accept.
    _miss="
		ip daddr @fakeip counter drop"
    if [ "$(u on_failure)" != "open" ]; then
        if [ "$(u list_mode)" = "all" ]; then
            _miss="$_miss
		meta nfproto ipv4 meta l4proto { tcp, udp } counter drop"
            if v6on; then _miss="$_miss
		meta nfproto ipv6 meta l4proto { tcp, udp } counter drop"; fi
        else
            _miss="$_miss
		ip daddr @subnets meta l4proto { tcp, udp } counter drop"
            if v6on; then _miss="$_miss
		ip6 daddr @subnets6 meta l4proto { tcp, udp } counter drop"; fi
        fi
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

		$_catch$_v6catch$_miss
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

cmd_nft() { nft_ruleset; }

# Дешёвый слепок обвязки для init-скрипта: те же входные данные, что у
# nft_ruleset, но без сборки (суммы файлов подсетей). Слепок берётся несколько
# раз на один `uci commit`, полная сборка списков не укладывалась в 20 с
# панели.
nft_sig() {
    # block_quic и on_failure обязательны: они живут только в правилах nft,
    # без них reload не видел смены.
    printf '%s|%s|%s|%s|%s|%s|%s|' \
        "$(u fakeip_pool)" "$(u mark)" "$(u tproxy_port)" \
        "$(u interface)" "$(u list_mode)" "$(u block_quic)" "$(u on_failure)"
    {
        md5sum "$LISTS/subnets.lst" 2>/dev/null | cut -d' ' -f1
        for _ns in $(u preset); do
            md5sum "$PRESETS_DIR/$_ns.sub" 2>/dev/null | cut -d' ' -f1
        done
    } | md5sum | cut -d' ' -f1
}

cmd_nftsig() { nft_sig; }
