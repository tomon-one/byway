// Перехват (бывшие plumb/*.sh): таблица nft, маршрут и ip rule, dnsmasq на
// DNS-вход Xray, запрет «не пускать мимо VPN». Замок и снятие по сигналу --
// у shell (plumb/plumb.sh): ucode сигналов не ловит.
//
// Внешние программы (nft, ip, uci, dnsmasq) -- командами: правка UCI dhcp и
// firewall -- через uci, не курсором (курсор 22.03 с save() по имени пакета
// молча не пишет, см. uc/transfer.uc). UCI dhcp byway с 0.4.0 не меняет:
// ветки с PL_DHCP0 -- уборка наследия 0.3.0 (снимок dnssave, свой адрес в
// server); firewall -- свой блок текстом (pl_fw_set) и reload.

const PL_TABLE = 'byway';
const PL_BTABLE = 'byway_block';
// Номер таблицы не больше 255: busybox ip на 1602 отвечает 'invalid argument
// to table ID' (2026-09-03).
const PL_RT = '100';
// Отметка «маршрут завёл byway», в памяти: маршрут перезагрузку не переживает.
const PL_RT_MINE = '/var/run/byway-route-mine';
const PL_RT_MINE6 = '/var/run/byway-route-mine6';
// Метка, с которой заведено правило ip rule: после смены mark правило со
// старой меткой оставалось навсегда (Ф9, п1-2). /var/run -- каталог root.
const PL_MARK_SET = '/var/run/byway-mark';
const PL_BLOCK = '/var/run/byway-blocked';
const PL_DOWN = '/var/run/byway-plumb-down';
const PL_DHCP0 = 'dhcp.@dnsmasq[0]';
// NXDOMAIN на use-application-dns.net выключает DoH у Firefox (иначе он идёт
// мимо byway); `server=/имя/` без адреса даёт NXDOMAIN.
const PL_CANARY = '/use-application-dns.net/';
// Набор правил -- файлом в /var/run (root 755), не в общем /tmp: проверка и
// укладка читают один и тот же файл, занять имя чужой не может.
const PL_NFT = '/var/run/byway.nft';
const PL_BNFT = '/var/run/byway-block.nft';

// Приватное и зарезервированное. 198.18.0.0/15 (пул fakeip) сюда не входит:
// общий return съел бы пул. Список тот же, что в g_pool_sane и в правиле
// блокировки движка: править вместе.
const PL_RESERVED = '0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 224.0.0.0/4, 240.0.0.0/4';
// fc00::/7 входит, хотя пул v6 внутри него: правило пула стоит в цепочке
// выше. Без него в режиме «всё через VPN» домашний NAS на fd00:: ушёл бы в
// туннель.
const PL_RESERVED6 = '::1/128, ::/128, ::ffff:0:0/96, fe80::/10, ff00::/8, fc00::/7';
// Умолчание -- константа Xray (fakedns.go, FakeIPv6Pool).


// ── общее ─────────────────────────────────────────────────────────────────
function pl_where() { return _t('правил nft'); }

// Заворот IPv6 выключен по умолчанию (как у passwall, OpenClash).
function pl_v6on() { return u('ipv6') == '1'; }

// Адрес DNS-входа с умолчанием: поле в панели можно очистить.
function pl_dns_addr() { return g_dns_listen(false); }

// Строки вывода без последнего перевода строки; пустой вывод -- пусто.
function pl_lines(s) {
	s = rtrim(s ?? '', '\n');
	return s === '' ? [] : split(s, '\n');
}

// Сообщение программы для строки предупреждения: две первые строки через
// пробел (как `head -2 | tr '\n' ' '`).
function pl_head2(s) {
	let l = pl_lines(s);
	return length(l) > 1 ? l[0] + ' ' + l[1] + ' ' : (l[0] ?? '');
}

// Слова строки без пустых.
function pl_words(s) { return filter(split(s, /[ \t\n]+/), (w) => w !== ''); }
function pl_uci_get(p) { return rtrim(run([ 'uci', '-q', 'get', p ]).out, '\n'); }
function pl_quiet(argv) { return run(argv).code; }
// Перезапуск dnsmasq -- без HUP и INT: оборванный между stop и start (закрыли
// ssh, Ctrl+C) он оставлял dnsmasq лежать, а с ним DNS и DHCP всего дома
// (2026-10-18). Игнор сигнала наследуется через exec; вывод -- в никуда: труба
// к умершему родителю убила бы перезапуск через SIGPIPE.
function pl_dns_restart() { run([ 'sh', '-c', 'trap "" HUP INT PIPE; exec /etc/init.d/dnsmasq restart >/dev/null 2>&1' ]); }
function pl_has_table(t) { return run([ 'nft', 'list', 'table', 'inet', t ]).code == 0; }

// dnsmasq при старте пишет свой конфиг в /tmp: без места он не встаёт, и дом
// остаётся без DNS вовсе. При нехватке dnsmasq не перезапускаем и его файлы
// не трогаем -- работающий отвечает по-прежнему, сторож повторит позже
// (Ф9, прогон 5; решение Tomon 2026-10-24). Не узнали места -- не мешаем.
const PL_TMP_MIN = 256;
function pl_tmp_short(what) {
	let df = split(split(run([ 'df', '-k', '/tmp' ]).out, '\n')[1] ?? '', /[ \t]+/);
	let free = df[3] ?? '';
	if (free === '' || ltrim(free, '0123456789') !== '' || int(free) >= PL_TMP_MIN) return false;
	warnf('в /tmp свободно %s КБ — dnsmasq не перезапущен: без места он не встаёт, и дом остался бы без DNS. %s Освободить место: df -h /tmp', free, what);
	return true;
}

// Действующая метка (pl_mark): как печатает ip rule show -- строчными, без
// ведущих нулей. loud -- жаловаться на негодную настройку.
function pl_mark(loud) {
	if (!loud) return st_mark();
	let m = g_val_or('mark', u('mark'), /^0x[0-9a-fA-F]{1,8}$/, '0x100000', pl_where());
	if (hex(substr(m, 2)) == 0) {
		warnf('настройка %s = «%s» не годится для %s, взято %s', 'mark', m, pl_where(), '0x100000');
		m = '0x100000';
	}
	return sprintf('0x%x', hex(substr(m, 2)));
}

// Мосты (pl_ifs): имена через пробел.
function pl_ifs(loud) {
	let re = /^[A-Za-z0-9._-]+( [A-Za-z0-9._-]+)*$/, v = u('interface');
	if (loud) return g_val_or('interface', v, re, 'br-lan', pl_where());
	return (v === '' || match(v, /[\x01-\x1f\x7f]/) || !match(v, re)) ? 'br-lan' : v;
}

// "a", "b" для набора nft.
function pl_iflist(ifs) { return join(', ', map(split(ifs, ' '), (i) => '"' + i + '"')); }

// Метка на исходящих сокетах движка (sockopt.mark), не та же, что у обвязки.
// Цепочка output ловит по адресу назначения, а движок на том же хосте: пакет,
// не восстановленный в домен, заворачивался бы обратно. Бит другой, чем у
// mark: ip rule ловит по маске любую метку с ним. Итог -- { s: как в
// настройке, n: числом }; quiet -- без жалоб (сборка конфига).
// Прежде жалобы шли в тот же вывод, что и число, и попадали в набор nft:
// ядро отвергало всю таблицу (стенд глушил warnf и этого не видел).
function pl_self_mark(quiet) {
	let s = u('self_mark'), re = /^(0[xX][0-9a-fA-F]{1,8}|[0-9]{1,10})$/;
	if (quiet) {
		if (s === '' || match(s, /[\x01-\x1f\x7f]/) || !match(s, re)) s = '0x400000';
	} else {
		s = g_val_or('self_mark', s, re, '0x400000', pl_where());
	}
	let n = pl_num(s);
	if (n == null || n > 4294967295 || n <= 0) {
		// Причина -- своя: 0 и «09» (ведущий ноль -- восьмеричное) в 32 бита
		// влезают, они просто не годятся (Ф9, п4-12).
		if (!quiet) {
			if (n == null) warnf('self_mark %s -- не число (ведущий ноль читается восьмеричным) -- взято умолчание 0x400000', s);
			else if (n <= 0) warnf('self_mark 0 не годится: метки у сокетов движка не будет -- взято умолчание 0x400000');
			else warnf('self_mark %s не влезает в 32 бита -- взято умолчание 0x400000', s);
		}
		s = '0x400000';
		n = 0x400000;
	}
	// Бит пересекается с mark: пакеты движка ушли бы в таблицу 100 на петлю,
	// а все проверки зелёные (проба отвечает от локального fakedns).
	let mk = pl_mark(false);
	if (n & hex(substr(mk, 2))) {
		s = '0x400000';
		n = 0x400000;
		if (n & hex(substr(mk, 2))) { s = '0x800000'; n = 0x800000; }
		if (!quiet) warnf('self_mark пересекается битами с mark %s -- взято %s', mk, s);
	}
	return { s: s, n: n };
}

// bw_uc selfmark: метка числом для конфига движка (sockopt.mark).
function cmd_selfmark() { print(pl_self_mark(true).n); }

// pid движка (st_xray_pid); BW_EPID -- подставной для стенда правил.
function pl_xray_pid() { return getenv('BW_EPID') ?? st_xray_pid(); }

// Склейки списков (uc/merge.uc); BW_SUBNETS и BW_MERGED -- подставные для
// стенда правил.
function pl_subs() { return getenv('BW_SUBNETS') ?? mg_path('subnets'); }
function pl_doms() { return getenv('BW_MERGED') ?? mg_path('domains'); }

// ── наборы адресов ────────────────────────────────────────────────────────
// Мерка адресов -- lj_v4_ok и lj_v6_ok (uc/lists.uc), одна со сборкой.
// Пробелы внутри строки прежде вырезались («1.2.3.4 /24» -- 1.2.3.4/24), а
// сборка такую строку отбрасывала: подсеть была в перехвате и не была в
// конфиге (Ф9, п4-11). Теперь снимаются только по краям, как у сборки.

// Элементы наборов из файла списка: v4 и v6 через запятую; отвергнутое -- в
// bad4/bad6 (это IPv6 -- не порча для v4, и наоборот). Пропускается только
// адрес или сеть своего семейства: одна чужая строка отвергалась ядром
// вместе со всем набором.
function pl_elements(file) {
	let r = { v4: [], v6: [], bad4: [], bad6: [] };
	let f = fs.open(file, 'r'), l;
	if (!f) return r;
	while ((l = f.read('line')) != null && l !== '') {
		l = trim(l, WS);
		if (l === '' || substr(l, 0, 1) == '#' || substr(l, 0, 2) == '//') continue;
		if (index(l, ':') < 0) push(lj_v4_ok(l, true) ? r.v4 : r.bad4, l);
		else push(lj_v6_ok(l) ? r.v6 : r.bad6, l);
	}
	f.close();
	return r;
}

// Отвергнутые строки -- в список отброшенных, byway называет их при сборке.
function pl_bad(lines) {
	let b = getenv('BW_BADLIST');
	if (!b || !length(lines)) return;
	let f = fs.open(b, 'a');
	if (f) { f.write(join('\n', lines) + '\n'); f.close(); }
}

// Адреса серверов VPN из собранного конфига (IPv4): литералы, dns.hosts
// (DNS туннелем) и закрепления /etc/hosts -- без запросов в сеть. Программам
// роутера они идут мимо метки: адрес сервера в подсетях списка увёл бы в
// туннель пробы связи с ним самим (health, probe).
function pl_v4_ok(a) { return lj_v4_ok(a, false); }
function pl_vpn_ips() {
	let c = null;
	try { c = json(fs.readfile(getenv('BW_OUT') ?? '') ?? 'null'); } catch (e) { c = null; }
	if (type(c) != 'object') return [];
	let names = [], ips = [];
	for (let o in c.outbounds ?? []) {
		let st = o.settings ?? {};
		for (let v in [ ...(st.vnext ?? []), ...(st.servers ?? []), st ])
			if (type(v?.address) == 'string') push(names, v.address);
		for (let pe in st.peers ?? [])
			if (type(pe?.endpoint) == 'string') push(names, substr(pe.endpoint, 0, rpos(pe.endpoint, ':')));
	}
	let hosts = c.dns?.hosts ?? {}, pins = {};
	for (let l in pl_lines(fs.readfile('/etc/hosts'))) {
		let w = pl_words(l);
		if (length(w) < 2 || substr(w[0], 0, 1) == '#' || !pl_v4_ok(w[0])) continue;
		for (let i = 1; i < length(w); i++) pins[w[i]] ??= w[0];
	}
	for (let n in names) {
		let a = pl_v4_ok(n) ? n : (type(hosts[n]) == 'string' ? hosts[n] : (type(hosts[n]) == 'array' ? hosts[n][0] : pins[n]));
		if (a && pl_v4_ok(a) && index(ips, a) < 0) push(ips, a);
	}
	return ips;
}

// ── набор правил перехвата ────────────────────────────────────────────────
// Трафик доверенных мостов к пулу fakeip и подсетям списка уходит в
// tproxy-вход Xray, остальное не трогается. Своя таблица, а не правила в fw4:
// откат -- `nft delete table inet byway`; перезагрузка firewall её не трогает,
// а `firewall stop` сносит все таблицы (её поднимает сторож).
// `tproxy ip to :порт` без адреса: форма с 127.0.0.1 требует route_localnet=1.
// Метка ставится через `or`: троттлинг метит трафик 0x2, присваивание затёрло
// бы её; ip rule поэтому сверяет по маске.
function pl_ruleset() {
	let pool = st_pool(), mark = pl_mark(true);
	let port = g_val_or('tproxy_port', u('tproxy_port'), /^[0-9]{1,5}$/, '1602', pl_where());
	// Та же мерка, что у сборки: порт 0 давал «tproxy to :0» (Ф9, п3-17).
	if (!g_port_ok(port)) port = '1602';
	let ifl = pl_iflist(pl_ifs(true));
	let el = pl_elements(pl_subs());
	pl_bad(el.bad4);
	pl_bad(el.bad6);
	let nets = join(', ', el.v4), nets6 = join(', ', el.v6);
	let pool6 = g_pool6(G_POOL6_DEF, pl_where());
	let v6 = pl_v6on(), all = u('list_mode') == 'all';
	let lport = g_val_or('local_proxy_port', u('local_proxy_port'), /^[0-9]{1,5}$/, '1603', pl_where());
	if (!g_port_ok(lport)) lport = '1603';
	let dport = g_direct_port(port, lport);
	let tp4 = 'counter tproxy ip to :' + port + ' meta mark set meta mark or ' + mark + ' accept';
	let tp6 = 'counter tproxy ip6 to :' + port + ' meta mark set meta mark or ' + mark + ' accept';
	let sm = null;

	// IPv6 -- в той же таблице inet. Пул fc00::/18 лежит внутри fc00::/7 (он в
	// privnets6), поэтому правило пула выше отсечки приватного. Две отсечки по
	// fib: глобального префикса роутера в privnets6 нет (выдаёт провайдер).
	let v6sets = '', v6pre = '', v6catch = '';
	if (v6) {
		v6sets = '\n\tset fakeip6 {\n\t\ttype ipv6_addr\n\t\tflags interval\n\t\telements = { ' + pool6 + ' }\n\t}' +
			'\n\tset privnets6 {\n\t\ttype ipv6_addr\n\t\tflags interval\n\t\telements = { ' + PL_RESERVED6 + ' }\n\t}' +
			'\n\tset subnets6 {\n\t\ttype ipv6_addr\n\t\tflags interval\n\t\tauto-merge\n\t\t' +
			(nets6 !== '' ? 'elements = { ' + nets6 + ' }' : '') + '\n\t}';
		v6pre = '\n\t\tip6 daddr @fakeip6 meta l4proto { tcp, udp } ' + tp6 +
			'\n\t\tip6 daddr @fakeip6 counter drop' +
			'\n\t\tip6 daddr @privnets6 return' +
			'\n\t\tmeta nfproto ipv6 fib daddr . iif type { local, broadcast, multicast } return' +
			'\n\t\tmeta nfproto ipv6 fib daddr oifname { ' + ifl + ' } return';
	}

	// Свои адреса роутера движку закрыты (Д-3, 2026-10-04): гость через имя,
	// разрешённое в публичный адрес WAN или глобальный v6, доходил до служб
	// роутера на 0.0.0.0. Движок узнаём по uid процесса (не от root), иначе по
	// self_mark (её ставит direct при router_via_vpn=1 и у движка от root:
	// прежде от root без router_via_vpn запрета не было, Ф9, п1-17). Петля и порт 53 вне
	// правила: Go-резолвер движка ходит на 127.0.0.1 за адресом сервера.
	let eng = '', pid = pl_xray_pid();
	let euid = pid !== '' ? match(fs.readfile('/proc/' + pid + '/status') ?? '', /\nUid:[ \t]+([0-9]+)/) : null;
	if (euid && euid[1] != '0') eng = 'meta skuid ' + euid[1];
	else if (u('router_via_vpn') == '1' || euid) { sm ??= pl_self_mark(false); eng = 'meta mark ' + sm.s; }
	let localchain = '';
	if (eng !== '')
		localchain = '\n\tchain engine_local {\n\t\ttype filter hook output priority filter; policy accept;' +
			'\n\t\t' + eng + ' ct state new meta nfproto ipv4 ip daddr != 127.0.0.0/8 meta l4proto { tcp, udp } th dport != 53 fib daddr type local counter reject' +
			'\n\t\t' + eng + ' ct state new meta nfproto ipv6 ip6 daddr != ::1 meta l4proto { tcp, udp } th dport != 53 fib daddr type local counter reject\n\t}';

	// Программы самого роутера (router_via_vpn): в tproxy вход есть только из
	// prerouting, поэтому пакет к пулу и подсетям метится в output, правило
	// fwmark уводит его на петлю, и с lo он приходит в prerouting к тому же
	// tproxy -- TCP и UDP. Свой трафик движка -- мимо, первым: иначе петля
	// (2026-09-07: 1444 витка, лимит файлов, лёг весь перехват). Движок -- по
	// uid и по метке сокетов; подсети -- только когда движок узнаётся по uid:
	// у движка от root со своим конфигом метки может не быть, а адрес его
	// сервера -- оказаться в подсетях списка. Приоритет числом (-150 = mangle).
	let rchain = '', rlo = false;
	if (u('router_via_vpn') == '1') {
		sm ??= pl_self_mark(false);
		let byuid = euid && euid[1] != '0', mk = 'counter meta mark set meta mark or ' + mark, vips = pl_vpn_ips();
		rchain = '\n\tchain output {\n\t\ttype route hook output priority -150; policy accept;' +
			(byuid ? '\n\t\tmeta skuid ' + euid[1] + ' return' : '') +
			'\n\t\tmeta mark & ' + sm.s + ' == ' + sm.s + ' return' +
			'\n\t\tip daddr @privnets return' +
			(length(vips) ? '\n\t\tip daddr { ' + join(', ', vips) + ' } return' : '') +
			'\n\t\tip daddr @fakeip meta l4proto { tcp, udp } ' + mk +
			(byuid ? '\n\t\tip daddr @subnets meta l4proto { tcp, udp } ' + mk : '') +
			(v6 ? '\n\t\tip6 daddr @fakeip6 meta l4proto { tcp, udp } ' + mk : '') +
			(v6 && byuid ? '\n\t\tip6 daddr @subnets6 meta l4proto { tcp, udp } ' + mk : '') + '\n\t}';
		rlo = true;
	}

	// Режим списков: пул и подсети. «Всё через VPN»: всё, что дошло сюда,
	// -- приватное и адреса роутера отсечены выше. Семейство у tproxy явное.
	let lcatch;
	if (all) {
		lcatch = 'meta nfproto ipv4 meta l4proto { tcp, udp } ' + tp4;
		if (v6) v6catch = '\n\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } ' + tp6;
	} else {
		lcatch = 'ip daddr @fakeip meta l4proto { tcp, udp } ' + tp4 +
			'\n\t\tip daddr @subnets meta l4proto { tcp, udp } ' + tp4;
		if (v6) v6catch = '\n\t\tip6 daddr @subnets6 meta l4proto { tcp, udp } ' + tp6;
	}
	// Не завернулось -- брось: tproxy без слушающего сокета (движок упал)
	// пакет пропускает дальше, и тот уходил в WAN напрямую. Пул наружу не
	// нужен никогда; подсети и «всё через VPN» -- только при «Не пускать».
	let miss = '\n\t\tip daddr @fakeip counter drop';
	if (u('on_failure') != 'open') {
		if (all) {
			miss += '\n\t\tmeta nfproto ipv4 meta l4proto { tcp, udp } counter drop';
			if (v6) miss += '\n\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } counter drop';
		} else {
			miss += '\n\t\tip daddr @subnets meta l4proto { tcp, udp } counter drop';
			if (v6) miss += '\n\t\tip6 daddr @subnets6 meta l4proto { tcp, udp } counter drop';
		}
	}
	// block_quic (пусто = включено): ключи поверх TCP везут UDP внутри TCP, и
	// QUIC там висит молча (Discord 2026-10-01); reject переводит клиента на
	// HTTP/2. В input по метке (в prerouting reject нельзя), только Initial
	// QUIC v1/v2. Синтаксис принят nftables 1.0.2.
	let quic = u('block_quic') != '0' ?
		'\n\t\tmeta mark & ' + mark + ' == ' + mark + ' udp dport 443 @th,64,8 & 0xc0 == 0xc0 @th,72,32 { 0x00000001, 0x6b3343cf } counter reject' : '';

	// Сети вне interface (Ф9, п1-18): dnsmasq один на все мосты и отдаёт им
	// подставные адреса списка, а перехвата у них нет -- сайты списка у них
	// не открывались вовсе. Теперь -- на вход «напрямую»: движок возвращает
	// имя и идёт без туннеля. Только с частных адресов: из WAN пул не нужен
	// (у v6 -- ULA и link-local, н1-25; клиент с глобальным адресом получит
	// отказ по v6 и уйдёт на v4 -- тот же вход).
	// Не завернулось (движок упал) -- брось: пул наружу не нужен никогда.
	let others = 'iifname != { "lo", ' + ifl + ' }';
	let direct = '\t\t' + others + ' ip saddr @privnets ip daddr @fakeip meta l4proto { tcp, udp } counter tproxy ip to :' + dport +
		' meta mark set meta mark or ' + mark + ' accept\n' +
		(v6 ? '\t\t' + others + ' ip6 saddr { fc00::/7, fe80::/10 } ip6 daddr @fakeip6 meta l4proto { tcp, udp } counter tproxy ip6 to :' + dport +
		       ' meta mark set meta mark or ' + mark + ' accept\n' : '') +
		'\t\t' + others + ' ip daddr @fakeip counter drop\n' +
		(v6 ? '\t\t' + others + ' ip6 daddr @fakeip6 counter drop\n' : '');

	// Прелюдия table/delete: `nft -f` доливает в существующую таблицу (и
	// `nft -c` давал «interval overlaps» на сужении пула); снятие и укладка --
	// одна транзакция. `elements = {  }` -- синтаксическая ошибка, набор без
	// элементов nft принимает. Имя набора -- privnets, НЕ reserved: у nftables
	// 1.0.2 это ключевое слово, и таблица отвергается целиком (2026-09-07).
	// Порядок prerouting: приватное и адреса роутера -- первым return (иначе
	// пакет самому роутеру на порт tproxy получал метку, и гостевая зона с
	// input REJECT переставала держать гостя), потом короткое замыкание по
	// прозрачному сокету.
	// Вход tproxy слушает 0.0.0.0 (tproxy не переписывает адрес назначения),
	// и порт закрыт в input по dport: перехваченный трафик приходит туда с
	// исходным портом назначения, правило бьёт только по прямым обращениям.
	return 'table inet ' + PL_TABLE + '\ndelete table inet ' + PL_TABLE + '\ntable inet ' + PL_TABLE + ' {\n' +
		'\tset fakeip {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\telements = { ' + pool + ' }\n\t}\n' +
		'\tset privnets {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\telements = { ' + PL_RESERVED + ' }\n\t}\n' +
		'\tset subnets {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t\t' +
		(nets !== '' ? 'elements = { ' + nets + ' }' : '') + '\n\t}' + v6sets + '\n' +
		'\tchain prerouting {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n' +
		(rlo ? '\t\tiif lo meta mark & ' + mark + ' != ' + mark + ' return\n' : '') + direct +
		(rlo ? '\t\tiifname != { "lo", ' + ifl + ' } return\n' :
		       '\t\tiifname != { ' + ifl + ' } return\n') +
		'\t\tip daddr @privnets return' + v6pre + '\n' +
		'\t\tmeta l4proto { tcp, udp } socket transparent 1 meta mark set meta mark or ' + mark + ' accept\n' +
		'\t\t' + lcatch + v6catch + miss + '\n\t}\n' +
		'\tchain input {\n\t\ttype filter hook input priority filter - 10; policy accept;\n' +
		'\t\tiif lo return' + quic + '\n' +
		'\t\tmeta l4proto { tcp, udp } th dport { ' + port + ', ' + dport + ' } counter drop\n\t}\n' +
		rchain + localchain + '\n}\n';
}

// bw_uc nft: набор правил, не применяя (byway nft; стенд nft-check.sh).
// Жалобы -- в stderr: вывод отдают прямо в `nft -f`.
function cmd_nft() {
	WARN_ERR = fs.stderr;
	print(pl_ruleset());
}

// bw_uc nftsig: дешёвый слепок обвязки для init-скрипта -- входные данные
// правил без сборки (суммы файлов подсетей). block_quic и on_failure живут
// только в правилах nft: без них reload не видел смены.
function cmd_nftsig() {
	let f = [ getenv('BW_LISTS') + '/subnets.lst' ];
	for (let p in split(trim(u('preset')), /[ \t\n]+/))
		if (p !== '') push(f, getenv('BW_PRESETS') + '/' + p + '.sub');
	print(join('|', map([ 'fakeip_pool', 'mark', 'tproxy_port', 'interface', 'list_mode', 'block_quic', 'on_failure' ], u)), '|');
	print(run([ 'sh', '-c', 'md5sum "$@" 2>/dev/null | cut -d" " -f1 | md5sum | cut -d" " -f1', 'sh', ...f ]).out);
}

// ── маршрут ───────────────────────────────────────────────────────────────
// Образец по fwmark и таблице, а не по «lookup 100»: чужой tproxy (openclash,
// passwall, nikki) занимает ту же таблицу. Конец закреплён: «lookup 100»
// совпадает и с «lookup 1000».
function pl_rule_re(m) {
	return regexp('fwmark ' + m + '(/' + m + ')?[[:space:]]+lookup ' + PL_RT + '([[:space:]]|$)');
}
function pl_has_rule(fam, re) {
	for (let l in pl_lines(run([ 'ip', ...fam, 'rule', 'show' ]).out)) if (match(l, re)) return true;
	return false;
}

// Отказ команды -- её сообщение вслух и ложь (прежде так обрывал set -e).
function pl_try(argv) {
	let r = run(argv, true);
	if (r.code != 0 && r.out !== '') print(r.out);
	return r.code == 0;
}

// ip rule: помеченное -- в локальную таблицу, иначе tproxy-сокет пакета не
// увидит. Ложь -- маршрут не заведён.
// Снять правила ip rule (v4 и v6) с этой меткой.
function pl_rules_del(m) {
	let re = pl_rule_re(m);
	while (pl_has_rule([], re))
		if (pl_quiet([ 'ip', 'rule', 'del', 'fwmark', m + '/' + m, 'lookup', PL_RT ]) != 0) break;
	// Без проверки ipv6: настройку могли выключить после подъёма.
	while (pl_has_rule([ '-6' ], re))
		if (pl_quiet([ 'ip', '-6', 'rule', 'del', 'fwmark', m + '/' + m, 'lookup', PL_RT ]) != 0) break;
}

function pl_route_up() {
	let rt = pl_lines(run([ 'ip', 'route', 'show', 'table', PL_RT ]).out);
	// Чужие маршруты не трогаем, но говорим: наложение непредсказуемо.
	if (length(filter(rt, (l) => substr(l, 0, 20) != 'local default dev lo')))
		warnf('в таблице маршрутизации %s есть чужие маршруты -- byway их не трогает', PL_RT);
	let m = pl_mark(false), re = pl_rule_re(m), old = trim(fs.readfile(PL_MARK_SET) ?? '');
	if (old !== '' && old != m) pl_rules_del(old);
	if (!pl_has_rule([], re) && !pl_try([ 'ip', 'rule', 'add', 'fwmark', m + '/' + m, 'lookup', PL_RT ])) return false;
	fs.writefile(PL_MARK_SET, m + '\n');
	// Отметка «маршрут наш»: формой от чужого не отличить.
	if (!length(filter(rt, (l) => substr(l, 0, 13) == 'local default'))) {
		if (!pl_try([ 'ip', 'route', 'add', 'local', 'default', 'dev', 'lo', 'table', PL_RT ])) return false;
		fs.writefile(PL_RT_MINE, '');
	}
	if (pl_v6on()) {
		if (!pl_has_rule([ '-6' ], re) && !pl_try([ 'ip', '-6', 'rule', 'add', 'fwmark', m + '/' + m, 'lookup', PL_RT ]))
			return false;
		// `list table all`, а не `show table N`: у busybox
		// `ip -6 route show table 100` при существующем маршруте молчит (22.03.7,
		// 2026-09-08).
		let six = pl_lines(run([ 'ip', '-6', 'route', 'list', 'table', 'all' ]).out);
		// С пробелом после номера: иначе «table 100» совпадало и с «table
		// 1000» чужого маршрута, и свой не заводился (Ф9, п4-43).
		if (!length(filter(six, (l) => substr(l + ' ', 0, 28 + length(PL_RT)) == 'local default dev lo table ' + PL_RT + ' '))) {
			if (!pl_try([ 'ip', '-6', 'route', 'add', 'local', '::/0', 'dev', 'lo', 'table', PL_RT ])) return false;
			fs.writefile(PL_RT_MINE6, '');
		}
	}
	return true;
}

function pl_route_down() {
	let m = pl_mark(false), old = trim(fs.readfile(PL_MARK_SET) ?? '');
	pl_rules_del(m);
	if (old !== '' && old != m) pl_rules_del(old);
	fs.unlink(PL_MARK_SET);
	// Убирается только свой маршрут (по отметке, не по форме): таблицу мог
	// занять другой tproxy, и flush сломал бы соседа.
	if (fs.stat(PL_RT_MINE)) {
		pl_quiet([ 'ip', 'route', 'del', 'local', 'default', 'dev', 'lo', 'table', PL_RT ]);
		fs.unlink(PL_RT_MINE);
	} else if (length(filter(pl_lines(run([ 'ip', 'route', 'show', 'table', PL_RT ]).out),
	                         (l) => substr(l, 0, 20) != 'local default dev lo'))) {
		// Осиротевший `local default dev lo` без отметки безобиден (у установок
		// до 0.1.4 отметки нет): говорим, только когда в таблице есть чужое.
		warnf('маршрут в таблице %s оставлен: его завёл не byway', PL_RT);
	}
	if (fs.stat(PL_RT_MINE6)) {
		pl_quiet([ 'ip', '-6', 'route', 'del', 'local', '::/0', 'dev', 'lo', 'table', PL_RT ]);
		fs.unlink(PL_RT_MINE6);
	}
}

// ── dnsmasq ───────────────────────────────────────────────────────────────
// Резолвер уводится на DNS-вход Xray файлом в каталоге добавок (uc/dnsmasq.uc):
// server на вход, no-resolv (без него dnsmasq шлёт запрос и провайдеру, и
// часть доменов получает настоящий адрес) и канарейка. Файл в памяти и уходит
// с перезагрузкой; UCI dnsmasq не трогается.
function pl_servers() { return pl_words(pl_uci_get(PL_DHCP0 + '.server')); }

// HUP чистит кэш и перечитывает hosts, не роняя сокеты; файлы каталога
// добавок dnsmasq читает только при старте. Сброс после рестарта движка
// обязателен: таблица fakedns живёт в памяти Xray.
function pl_dns_flush() { pl_quiet([ 'killall', '-HUP', 'dnsmasq' ]); }

// Прочитал ли файл работающий dnsmasq: запущен не раньше правки файла.
function pl_dns_loaded(f) {
	let st = fs.stat(f), bt = match(fs.readfile('/proc/stat') ?? '', /\nbtime ([0-9]+)/);
	if (!st || !bt) return false;
	for (let p in pl_words(run([ 'pgrep', '-x', 'dnsmasq' ]).out)) {
		let s = fs.readfile('/proc/' + p + '/stat') ?? '', i = rpos(s, ') ');
		if (i < 0) continue;
		// btime и старт процесса -- целые секунды, сумма отстаёт от настоящего
		// старта до двух секунд: файл, записанный ДО перезапуска dnsmasq,
		// выглядел новее процесса, и второй подъём перезапускал dnsmasq вместо
		// сигнала -- секунды без DNS (стенд uci-cron-check, 22.03.7, 2026-10-24).
		if (int(bt[1]) + int(int(split(substr(s, i + 2), ' ')[19]) / 100) + 2 >= st.mtime) return true;
	}
	return false;
}

// Правка UCI прежних версий (до 0.4.0): дельта без commit и снимок
// /etc/byway/dns-saved, а после «Сохранить» в LuCI -- закреплённая. Снимается
// один раз; итог -- было ли что снимать (тогда нужен рестарт).
function pl_dnssave() { return getenv('BW_LISTS') + '/dns-saved'; }
function pl_save_read(k) {
	let t = fs.readfile(pl_dnssave());
	if (t == null) return '';
	let l = pl_lines(t);
	if (k == 'noresolv') return substr(l[0] ?? '', 0, 9) == 'noresolv=' ? substr(l[0], 9) : '';
	let p = k + '=', r = [];
	for (let x in l) if (substr(x, 0, length(p)) == p) push(r, substr(x, length(p)));
	return join('\n', r);
}
function pl_dns_legacy() {
	let sv = pl_dnssave(), ours = pl_save_read('listen');
	if (ours === '') ours = pl_dns_addr();
	if (!fs.stat(sv) && index(pl_servers(), ours) < 0) return false;
	// revert снимает некоммиченную дельту без записи во флеш.
	pl_quiet([ 'uci', '-q', 'revert', 'dhcp' ]);
	let cur = pl_servers();
	if (index(cur, ours) >= 0) {
		pl_quiet([ 'uci', '-q', 'delete', PL_DHCP0 + '.server' ]);
		let seen = [];
		for (let s in pl_words(pl_save_read('server'))) {
			if (index(seen, s) >= 0) continue;
			push(seen, s);
			pl_try([ 'uci', 'add_list', PL_DHCP0 + '.server=' + s ]);
		}
		// Доменные записи, появившиеся после снимка, возвращаем; без снимка --
		// всё, кроме своего адреса и канарейки.
		let snap = fs.stat(sv) != null;
		for (let s in cur) {
			if (s == PL_CANARY || s == ours || index(seen, s) >= 0 || (snap && substr(s, 0, 1) != '/')) continue;
			push(seen, s);
			pl_try([ 'uci', 'add_list', PL_DHCP0 + '.server=' + s ]);
		}
		// Без снимка noresolv снимается, только если резолвить стало нечем: он
		// мог стоять у человека и до byway, вместе с его апстримами.
		if (pl_save_read('noresolv') == '1') pl_try([ 'uci', 'set', PL_DHCP0 + '.noresolv=1' ]);
		else if (snap || !length(filter(seen, (x) => substr(x, 0, 1) != '/')))
			pl_quiet([ 'uci', '-q', 'delete', PL_DHCP0 + '.noresolv' ]);
		if (!uci_commit('dhcp')) warn('на флеше нет места: настройки dnsmasq не записаны, прежние на месте');
	}
	fs.unlink(sv);
	return true;
}

// defer -- рестарт сделает следующий шаг (block_off снимает файл запрета).
// Ложь -- некуда положить файл.
function pl_dns_up(defer) {
	let l = pl_dns_addr(), f = dm_file(DM_DNS);
	if (f === '') {
		warn('не найден каталог добавок dnsmasq — DNS дома не переведён на byway, работают только подсети');
		return false;
	}
	let leg = pl_dns_legacy();
	let fo = dm_foreign(l);
	if (length(fo))
		warnf('у dnsmasq в настройках свои серверы (%s): часть запросов уйдёт мимо byway, и сайты из списка будут открываться через раз — убрать: Сеть → DHCP и DNS → Перенаправления', join(' ', fo));
	let t = 'server=' + l + '\nno-resolv\nserver=' + PL_CANARY + '\n';
	let same = fs.readfile(f) == t;
	if (same && !leg && pl_dns_loaded(f)) {
		pl_dns_flush();
		return true;
	}
	if (pl_tmp_short(_t('DNS дома пока не переведён на byway.'))) return false;
	if (!same) {
		fs.writefile(f + '.new', t);
		fs.rename(f + '.new', f);
	}
	if (!defer) pl_dns_restart();
	return true;
}

// Порога места здесь нет (узкий аудит, н1-18): снятие файла места не просит,
// а dnsmasq, оставленный на мёртвом движке, -- дом без DNS.
function pl_dns_down() {
	let leg = pl_dns_legacy(), f = dm_file(DM_DNS), had = f !== '' && fs.stat(f) != null;
	if (had) fs.unlink(f);
	// Файла не было -- резолвер не наш: рестарт (9 с без DNS) -- чистая
	// потеря, кэш сбрасываем всё равно.
	if (had || leg) pl_dns_restart();
	else pl_dns_flush();
}

// ── запрет «не пускать мимо VPN» ──────────────────────────────────────────
// Закрытая модель (on_failure): без туннеля нет и доступа к списку. Домены --
// через dnsmasq (address=/домен/ в его каталоге добавок): без движка резолвер
// отдаёт настоящие адреса, по адресу домен не узнать. Подсети -- правилами nft.

// Режим «всё через VPN» -- отдельным правилом, не выжимкой из списков (они в
// нём пусты). К forward, не к output: движок должен достучаться до ноды, LuCI
// и ssh идут через input. Цепочка `forward`, не `fwd`: fwd зарезервировано.
function pl_block_all(ifl) {
	return 'table inet ' + PL_BTABLE + '\ndelete table inet ' + PL_BTABLE + '\ntable inet ' + PL_BTABLE + ' {\n' +
		'\tset privnets {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\telements = { ' + PL_RESERVED + ' }\n\t}\n' +
		'\tchain forward {\n\t\ttype filter hook forward priority filter - 5; policy accept;\n' +
		'\t\tiifname != { ' + ifl + ' } return\n\t\toifname { ' + ifl + ' } return\n' +
		'\t\tip daddr @privnets return\n\t\tcounter reject\n\t}\n}\n';
}

// Подсети v4 и v6 (v6 -- только при заворачивании IPv6: иначе их трафик и не
// перехватывается). Пусто -- закрывать подсети нечем.
function pl_block_lists(ifl, nets, nets6) {
	let sets = '', rules = '';
	if (nets !== '') {
		sets += '\n\tset blocked {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { ' + nets + ' }\n\t}';
		rules += '\n\t\tip daddr @blocked counter reject';
	}
	if (nets6 !== '') {
		sets += '\n\tset blocked6 {\n\t\ttype ipv6_addr\n\t\tflags interval\n\t\tauto-merge\n\t\telements = { ' + nets6 + ' }\n\t}';
		rules += '\n\t\tip6 daddr @blocked6 counter reject';
	}
	if (sets === '') return null;
	return 'table inet ' + PL_BTABLE + '\ndelete table inet ' + PL_BTABLE + '\ntable inet ' + PL_BTABLE + ' {' + sets + '\n' +
		'\tchain forward {\n\t\ttype filter hook forward priority filter - 5; policy accept;\n' +
		'\t\tiifname != { ' + ifl + ' } return' + rules + '\n\t}\n}\n';
}

// Набор -- в файл и в ядро; итог -- сообщение ядра (пусто -- принято).
function pl_nft_load(file, text) {
	fs.unlink(file);
	let f = fs.open(file, 'w', 0600);
	if (!f) return _f('не записан %s', file);
	f.write(text);
	f.close();
	let r = run([ 'nft', '-f', file ], true);
	fs.unlink(file);
	return r.code == 0 ? r.out : (r.out !== '' ? r.out : 'отказ без сообщения');
}

// Стоит ли запрет в ядре и в dnsmasq -- по списку частей, записанному при
// укладке. Списка нет (запрет от прежней версии) -- верим файлу.
function pl_block_intact() {
	let p = fs.readfile(PL_BLOCK + '.parts');
	if (p == null) return true;
	for (let w in pl_words(p)) {
		if (w == 'table' && !pl_has_table(PL_BTABLE)) return false;
		if (w == 'conf') {
			let d = dm_confdir();
			if (d === '' || !fs.stat(d + '/' + DM_BLOCK)) return false;
		}
	}
	return true;
}

function pl_block_off() {
	let d = dm_confdir();
	if (d !== '' && fs.stat(d + '/' + DM_BLOCK)) {
		// Запрет -- целиком до освобождения места: снятый наполовину
		// (подсети открыты, имена закрыты) хуже стоящего.
		if (pl_tmp_short(_t('Запрет «не пускать мимо VPN» остаётся, пока место не освободится.'))) return;
		fs.unlink(d + '/' + DM_BLOCK);
		pl_dns_restart();
	}
	pl_quiet([ 'nft', 'delete', 'table', 'inet', PL_BTABLE ]);
	for (let f in [ PL_BLOCK, PL_BLOCK + '.sig', PL_BLOCK + '.parts' ]) fs.unlink(f);
}

// Домены списка -- файлом для dnsmasq (address=/имя/ без адреса: NXDOMAIN на
// любой тип; с 0.0.0.0 закрывалась лишь A). Формы Xray (`full:`, `domain:`)
// -- снятыми: файл прошёл бы `--test`, но закрывал несуществующий домен.
// Итог -- закрыто и всего записей; не записан -- null.
function pl_block_conf(src, file) {
	let n = 0, i = fs.open(src, 'r'), o = fs.open(file, 'w'), l;
	if (!o) { if (i) i.close(); return null; }
	if (i) {
		while ((l = i.read('line')) != null && l !== '') {
			l = lj_plain(l);
			if (l != null) { o.write('address=/' + l + '/\n'); n++; }
		}
		i.close();
	}
	o.close();
	return { n: n, all: lj_count(src) };
}

// Итог -- число закрытых доменов; -1 -- не закрыты: в /tmp нет места.
function pl_block_dns() {
	let d = dm_confdir();
	if (d === '') {
		warn('«не пускать мимо VPN»: не найден каталог конфигов dnsmasq — домены закрыть нечем');
		return 0;
	}
	let bf = d + '/' + DM_BLOCK, c = pl_block_conf(pl_doms(), bf + '.new');
	if (c == null) return 0;
	let n = c.n, all = c.all;
	// keyword: и regexp: именем закрыть нельзя (dnsmasq сопоставляет
	// суффиксом) -- говорим вслух.
	if (all > n)
		warnf('«не пускать мимо VPN»: %s записей списка нельзя закрыть по имени (keyword:, regexp: и подобные) — они останутся ОТКРЫТЫМИ', all - n);
	// Синтаксис -- до подмены: битый файл не даст dnsmasq подняться.
	if (pl_quiet([ 'cmp', '-s', bf + '.new', bf ]) == 0) {
		fs.unlink(bf + '.new');
	} else if (pl_tmp_short(_t('Домены списка не закрыты по имени.'))) {
		// Файл мог лечь не целиком: место кончилось при записи.
		n = -1;
		fs.unlink(bf + '.new');
	} else if (pl_quiet([ 'dnsmasq', '--test', '-C', bf + '.new' ]) == 0) {
		fs.rename(bf + '.new', bf);
		pl_dns_restart();
	} else {
		n = 0;
		fs.unlink(bf + '.new');
		warn('«не пускать мимо VPN»: dnsmasq не принял список — домены остались ОТКРЫТЫМИ');
	}
	return n;
}

function pl_block_on() {
	// Открытая модель: запрет, оставшийся от закрытой, снимается здесь (Д-2,
	// 2026-10-04).
	if (u('on_failure') == 'open') {
		if (fs.stat(PL_BLOCK)) pl_block_off();
		return;
	}
	let ifs = pl_ifs(false), ifl = pl_iflist(ifs), all = u('list_mode') == 'all', v6 = pl_v6on();
	let doms = pl_doms(), subs = pl_subs();
	// Стоящий запрет пересобирается на месте, если сменились режим, сети, IPv6
	// или списки. И стоит ли он в ядре: чужой `nft flush ruleset` снимал
	// таблицу, а запрет по файлам в /tmp числился стоящим.
	let mode = u('list_mode');
	if (mode !== '') mode += '\n';
	let sig = trim(run([ 'sh', '-c', '{ printf "%s" "$1"; cat "$2" "$3"; } 2>/dev/null | md5sum | cut -c1-32',
	                     'sh', mode + ifs + '\n' + (v6 ? 'v6\n' : ''), doms, subs ]).out);
	if (fs.stat(PL_BLOCK) && rtrim(fs.readfile(PL_BLOCK + '.sig') ?? '', '\n') == sig && pl_block_intact())
		return;
	fs.writefile(PL_BLOCK + '.sig', sig + '\n');

	if (all) {
		// Остаток режима списков (имена) здесь не нужен.
		let d = dm_confdir();
		if (d !== '' && fs.stat(d + '/' + DM_BLOCK) &&
		    !pl_tmp_short(_t('Прежний запрет по именам остаётся, пока место не освободится.'))) {
			fs.unlink(d + '/' + DM_BLOCK);
			pl_dns_restart();
		}
		let e = pl_nft_load(PL_BNFT, pl_block_all(ifl));
		if (e !== '') warnf('«не пускать мимо VPN»: ядро не приняло правило — %s', pl_head2(e));
		if (pl_has_table(PL_BTABLE)) {
			fs.writefile(PL_BLOCK, 'all\n');
			fs.writefile(PL_BLOCK + '.parts', 'table\n');
			// Не «весь трафик»: цепочка отсекает сети вне byway.main.interface.
			warn('туннеля нет, и трафик перечисленных сетей мимо VPN закрыт: так велит настройка «не пускать мимо VPN». Сети вне byway.main.interface запрет не закрывает');
		} else {
			// Молчать нельзя: человек включил запрет и вправе знать, что его нет.
			fs.writefile(PL_BLOCK, 'none\n');
			fs.unlink(PL_BLOCK + '.parts');
			warn('«не пускать мимо VPN»: ядро не приняло правило запрета — трафик идёт НАПРЯМУЮ');
		}
		return;
	}
	let ndom = pl_block_dns(), nnet = false, short = ndom < 0;
	// Не закрыли из-за места -- без отметки «сделано»: следующий вызов
	// (сторож, plumb off --keep-block) повторит.
	if (short) { ndom = 0; fs.unlink(PL_BLOCK + '.sig'); }
	let el = pl_elements(subs);
	pl_bad(el.bad4);
	if (v6) pl_bad(el.bad6);
	let text = pl_block_lists(ifl, join(', ', el.v4), v6 ? join(', ', el.v6) : '');
	if (text != null) {
		let e = pl_nft_load(PL_BNFT, text);
		if (e !== '') warnf('«не пускать мимо VPN»: подсети закрыть не вышло — %s', pl_head2(e));
		nnet = pl_has_table(PL_BTABLE);
	} else {
		pl_quiet([ 'nft', 'delete', 'table', 'inet', PL_BTABLE ]);
	}
	// Строка про закрытый доступ -- только когда есть что закрывать.
	if (ndom > 0 || nnet) {
		fs.writefile(PL_BLOCK, 'lists\n');
		fs.writefile(PL_BLOCK + '.parts', (ndom > 0 ? 'conf\n' : '') + (nnet ? 'table\n' : ''));
		warnf('туннеля нет, и доступ к списку закрыт: доменов %s, подсети %s', ndom, nnet ? _t('да') : _t('нет'));
	} else if (!short) {
		fs.writefile(PL_BLOCK, 'none\n');
		fs.unlink(PL_BLOCK + '.parts');
		warn('«не пускать мимо VPN» включено, но закрывать нечего: списки пусты — трафик идёт НАПРЯМУЮ');
	}
}

// bw_uc nftblock [conf ФАЙЛ]: набор запрета, не применяя; conf -- файл
// доменов для dnsmasq и число закрытых (стенд nft-check.sh).
function cmd_nftblock(what, file) {
	WARN_ERR = fs.stderr;
	if (what == 'conf') { print(pl_block_conf(pl_doms(), file)?.n ?? 'null', '\n'); return; }
	let ifl = pl_iflist(pl_ifs(false));
	if (u('list_mode') == 'all') { print(pl_block_all(ifl)); return; }
	let el = pl_elements(pl_subs());
	print(pl_block_lists(ifl, join(', ', el.v4), pl_v6on() ? join(', ', el.v6) : '') ?? '');
}

// ── подъём ────────────────────────────────────────────────────────────────
// После обновления прошивки модулей tproxy нет (прошивка с сохранением
// настроек пакеты не переносит): ядро отвечает общим «не принято».
function pl_mod_hint() {
	let mods = fs.readfile('/proc/modules') ?? '';
	for (let m in [ 'nft_tproxy', 'nft_socket' ]) {
		if (substr(mods, 0, length(m) + 1) == m + ' ' || index(mods, '\n' + m + ' ') >= 0) continue;
		// Встроенный в ядро модуль в /proc/modules не виден (П4).
		if (fs.stat('/sys/module/' + m)?.type == 'directory') continue;
		if (pl_quiet([ 'modprobe', m ]) == 0) continue;
		warnf('нет модуля ядра %s — поставить: %s kmod-nft-tproxy kmod-nft-socket', m, getenv('BW_PKGFIX'));
		return;
	}
}

// Правило firewall byway-tproxy сверяется с меткой (нет -- заводится): после
// смены метки зона с input REJECT (гостевая) перестаёт пропускать помеченный
// трафик. Сверка -- до укладки своей таблицы: перезагрузка firewall (start
// делает flush только таблицы fw4), а его остановка (`firewall stop`) сносит
// все таблицы.
// Свой блок в /etc/config/firewall -- текстом, а не uci commit: тот
// переписывает файл целиком, и комментарии человека пропадали (Ф9, п3-41).
// Прежний блок вырезается, новый -- в конец; запись -- put_file.
function pl_fw_set(mm) {
	let f = '/etc/config/firewall', t = fs.readfile(f);
	if (t == null) return false;
	// Конец блока -- первая строка не option/list с начала строки: комментарии
	// человека после блока прежде пропадали вместе с ним (Ф9, п3-41, прогон 5).
	let out = [], skip = false;
	for (let l in split(t, '\n')) {
		if (match(l, /^config[ \t]/)) {
			skip = match(l, /^config[ \t]+rule[ \t]+'?bywaytproxy'?[ \t]*$/) != null;
			if (skip) while (length(out) && out[length(out) - 1] === '') pop(out);
		} else if (skip && l !== '' && !match(l, /^[ \t]/)) skip = false;
		if (!skip) push(out, l);
	}
	return put_file(f, rtrim(join('\n', out), '\n') + '\n\nconfig rule \'bywaytproxy\'\n\toption name \'byway-tproxy\'\n' +
		'\toption src \'*\'\n\toption proto \'all\'\n\toption mark \'' + mm + '\'\n\toption target \'ACCEPT\'\n');
}

function pl_fwrule() {
	let m = pl_mark(false), mm = m + '/' + m, r = pl_uci_get('firewall.bywaytproxy.mark');
	if (pl_uci_get('firewall.bywaytproxy') === '') {
		if (pl_fw_set(mm)) {
			pl_quiet([ '/etc/init.d/firewall', 'reload' ]);
			say('правила firewall для помеченного трафика не было — заведено заново');
		} else warn('на флеше нет места: правило firewall не записано, прежнее на месте');
		r = mm;
	}
	if (r !== '' && r != mm) {
		sayf('метка сменилась (%s -> %s) — правило firewall переписывается', r, mm);
		if (pl_fw_set(mm)) pl_quiet([ '/etc/init.d/firewall', 'reload' ]);
		else warn('на флеше нет места: правило firewall не записано, прежнее на месте');
	}
}

// Ждёт, пока Xray ответит на DNS-входе (до 15 с). Xray должен отвечать до
// любой правки: dns_up уводит весь резолв на его вход с noresolv. Проба --
// домен из склейки: FakeDNS отвечает локально, без WAN.
function pl_wait(l) {
	// Списка нет -- спрашиваем пробный домен: сборка кладёт его в fakedns
	// всегда. Ответ из пула доказывает, что отвечает движок, а не кто-то на
	// том же адресе: при dns_listen=127.0.0.1 «ответ» давал сам dnsmasq, и
	// резолвер дома уводился в петлю на себя (Ф9, п1-3).
	let probe = st_plain_first(pl_doms()), pool = st_pool(), gone = 0;
	if (probe === '') probe = getenv('BW_PROBE') ?? 'example.com';
	for (let i = 0; i < 15; i++) {
		for (let x in pl_lines(run([ 'nslookup', probe, l ]).out)) {
			if (substr(x, 0, 7) != 'Address') continue;
			let w = pl_words(x);
			if (st_in_pool(w[length(w) - 1], pool)) return true;
		}
		// Процесса движка нет пять проб подряд -- он падает при старте. Пять, а
		// не один: на холодной загрузке procd поднимает движок не сразу.
		if (st_xray_pid() === '') {
			if (++gone >= 5) {
				warn('движок не запущен — перехват не включён, ожидание прервано');
				return false;
			}
		} else {
			gone = 0;
		}
		system([ 'sleep', '1' ]);
	}
	return false;
}

// Отказ подъёма: резолвер -- провайдеру, запрет -- по настройке. На пути stop
// --keep-dns dnsmasq остаётся на нас, и без правил дом получал бы подставные
// адреса без перехвата. Запрет -- раньше резолвера, как в pl_off: иначе в
// окно между ними сайты списка открывались мимо VPN (узкий аудит, н1-24).
function pl_fail() {
	pl_block_on();
	pl_dns_down();
	return 1;
}

function pl_on() {
	pl_fwrule();
	// Метку «сняли намеренно» -- сразу: иначе неудачный подъём оставлял
	// сторожа запертым.
	fs.unlink(PL_DOWN);
	let l = pl_dns_addr();
	// Склейка не собралась (нет места в /tmp) -- отказ подъёма, а не выход
	// посередине мимо уборки (Ф9, п2-6, п2-19). dnsmasq не трогаем: при
	// полном /tmp он не пишет свой конфиг и после перезапуска не встаёт.
	if ((getenv('BW_SUBNETS') == null && mg_path('subnets', true) == null) ||
	    (getenv('BW_MERGED') == null && mg_path('domains', true) == null)) {
		warn('склейка списков не собралась: в /tmp нет места? Перехват не включён');
		return 1;
	}
	if (!pl_wait(l)) {
		// Закрыть до сообщения: между ними страница ушла бы мимо туннеля.
		pl_block_on();
		pl_dns_down();
		warnf('Xray-core не отвечает на %s:53 — перехват не включён, dnsmasq возвращён провайдеру', l);
		return 1;
	}
	// Сначала -c, и только потом снос старой таблицы: опечатка в подсетях не
	// должна оставить роутер без обвязки.
	let rules = pl_ruleset();
	fs.unlink(PL_NFT);
	let f = fs.open(PL_NFT, 'w', 0600);
	if (!f) { warnf('не записан %s', PL_NFT); return pl_fail(); }
	// Обрезанный нехваткой места в /tmp файл nft принимал как пустой набор,
	// и выходило «перехват включён» без таблицы (Ф9, п2-19).
	let w = f.write(rules);
	f.close();
	if (w !== length(rules)) { fs.unlink(PL_NFT); warnf('не записан %s', PL_NFT); return pl_fail(); }
	let c = run([ 'nft', '-c', '-f', PL_NFT ], true);
	if (c.code != 0) {
		print(c.out);
		warn('правила не приняты ядром, перехват не включён');
		pl_mod_hint();
		fs.unlink(PL_NFT);
		return pl_fail();
	}
	// Маршрут до правил: его отказ не должен оставлять таблицу nft (2026-09-03:
	// правила легли, маршрута нет, подсети ушли в tproxy в никуда). Прежде
	// отказ обрывал byway через set -e -- с резолвером на нас при живом
	// сторожевом вызове; теперь как остальные отказы.
	if (!pl_route_up()) {
		warn('маршрут для помеченного трафика не заведён — перехват не включён');
		pl_route_down();
		fs.unlink(PL_NFT);
		return pl_fail();
	}
	// Итог укладки читается: между проверкой и укладкой чужой процесс (fw4,
	// hotplug) мог изменить таблицы.
	let a = run([ 'nft', '-f', PL_NFT ], true);
	fs.unlink(PL_NFT);
	let e = a.code == 0 ? a.out : (a.out !== '' ? a.out : 'отказ без сообщения');
	if (e !== '') {
		warnf('правила не легли в ядро — %s', pl_head2(e));
		pl_mod_hint();
		// Маршрут снимаем: без правил он висел бы в таблице 100. Прежняя
		// таблица (nft -f -- одна транзакция) осталась бы метить пакеты, а
		// ехать им некуда -- сносим.
		pl_route_down();
		if (pl_has_table(PL_TABLE)) {
			let d = run([ 'nft', 'delete', 'table', 'inet', PL_TABLE ], true);
			if (d.out !== '') warnf('прежняя таблица не снялась — %s', rtrim(d.out, '\n'));
		}
		return pl_fail();
	}
	// Стоит запрет (файл в каталоге dnsmasq) -- его снимет block_off следующей
	// строкой вместе с рестартом dnsmasq: один рестарт вместо двух.
	let d = dm_confdir();
	let dok = pl_dns_up(d !== '' && fs.stat(d + '/' + DM_BLOCK) != null);
	pl_block_off();
	if (dok) sayf('перехват включён: таблица inet %s, правило fwmark, dnsmasq -> %s', PL_TABLE, l);
	else sayf('перехват включён без DNS: таблица inet %s, правило fwmark', PL_TABLE);
	return 0;
}

// Флаги -- во всей строке доводов: --service (метку «сняли руками» не
// ставить: следующий старт мог провалиться, и сторож остался бы заперт),
// --keep-dns (следом старт: dnsmasq вниз и обратно -- два окна по 9 с без
// DNS), --keep-block (при мёртвом движке запрет снимет ветка «движок
// вернулся»).
function pl_off(flags) {
	// Метка -- первым действием: dns_down рестартует dnsmasq (секунды), и
	// сторож в это окно поднимал обвязку поверх незаконченного снятия.
	if (index(flags, '--service') < 0) fs.writefile(PL_DOWN, '');
	pl_quiet([ 'nft', 'delete', 'table', 'inet', PL_TABLE ]);
	pl_route_down();
	let kd = index(flags, '--keep-dns') >= 0;
	// Запрет, который не встал раньше (не было места в /tmp), -- до возврата
	// резолвера провайдеру: иначе сайты списка открылись бы мимо VPN.
	// Стоящий pl_block_on не трогает.
	if (index(flags, '--keep-block') >= 0) pl_block_on();
	if (kd) pl_dns_flush();
	else pl_dns_down();
	// Запрет снимается вместе с обвязкой (иначе `plumb off` выглядел бы
	// поломкой интернета): после остановки службы запертый дом оставлять нельзя.
	if (index(flags, '--keep-block') < 0) pl_block_off();
	if (kd) say('перехват снят, резолвер оставлен на месте');
	else say('перехват снят, dnsmasq возвращён');
	return 0;
}

// bw_uc plumb on|off|close|unblock [флаги]. close -- закрыть, не поднимая
// обвязку (старт службы при on_failure=closed: иначе после перезагрузки запрет
// встаёт лишь после ожидания движка, а dnsmasq уже отдаёт настоящие адреса).
// unblock -- снять запрет (сторож: служба выключена).
function cmd_plumb(what, ...flags) {
	if (what == 'on') exit(pl_on());
	if (what == 'off') {
		// Неизвестный флаг -- отказ: «--keep-dsn» молча снимал и резолвер (Ф9, п3-23).
		for (let f in flags)
			if (index([ '--service', '--keep-dns', '--keep-block' ], f) < 0)
				dief('byway plumb off [--keep-dns] [--keep-block] — неизвестно: %s', f);
		exit(pl_off(flags));
	}
	if (what == 'close') { pl_block_on(); return; }
	if (what == 'unblock') { pl_block_off(); return; }
	// Служебные подкоманды -- все, что принимаются (Ф9, п3-27).
	die('byway plumb on|off|close|unblock');
}
