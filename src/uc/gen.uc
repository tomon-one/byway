// Сборка конфига Xray (бывшие gen_* из config/gen.sh). Замок, слияние списков
// и метку сокетов готовит shell (cmd_gen) и отдаёт в BW_*; здесь -- настройки,
// направления, конфиг объектом, проверка движком и подмена рабочего. Рабочий
// меняется, только если ядро приняло конфиг (run -test).

const G_WHERE = 'конфига движка';
const G_TMP = '/var/run/byway-config.new.json';

// Состояние сборки -- глобальное: функции верхнего уровня (см. uc/keys.uc).
let G = null;

// ── проверка значений ─────────────────────────────────────────────────────
// val_or: значение настройки по образцу, иначе умолчание и слово вслух. Эти
// настройки прежде уходили в конфиг движка сырыми, и значением с `", ...`
// можно было задать всю конфигурацию Xray, исполняемую от root.
// Адрес входа DNS движка: только петля и не 127.0.0.1. На 127.0.0.1 и на
// адресах сетей слушает dnsmasq: движок не мог занять порт, а резолвер дома
// уводился в петлю на себя (Ф9, п1-3). Одна мерка для сборки и перехвата.
function g_dns_listen(loud) {
	let v = u('dns_listen');
	if (v === '' || (match(v, /^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/) && v != '127.0.0.1')) return v || '127.0.0.42';
	if (loud) warnf('настройка %s = «%s» не годится: нужен адрес петли 127.x.x.x, кроме 127.0.0.1 (его занимает dnsmasq), взято %s', 'dns_listen', v, '127.0.0.42');
	return '127.0.0.42';
}

// Мерки dns_bootstrap и fakeip_pool -- одни для сборки и byway set (н1-5).
const G_POOL_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/;
const G_BOOT_RE = /^([0-9]{1,3}(\.[0-9]{1,3}){3}|(tcp|udp):\/\/[0-9.]{7,15})(:[0-9]{1,5})?$/;

function g_val_or(name, val, re, def, where) {
	where ??= _t(G_WHERE);
	if (val === '') return def;
	if (match(val, /[\x01-\x1f\x7f]/)) {
		warnf('настройка %s содержит управляющие знаки и не годится для %s, взято %s', name, where, def);
		return def;
	}
	if (match(val, re)) return val;
	warnf('настройка %s = «%s» не годится для %s, взято %s', name, val, where, def);
	return def;
}

function g_port_ok(s) {
	return match(s, /^[0-9]{1,5}$/) != null && int(s) >= 1 && int(s) <= 65535;
}

// Вход «напрямую» для сетей вне interface (Ф9, п1-18): общий dnsmasq отдаёт им
// подставные адреса списка, а туннель им не положен. Порт выводится из
// tproxy_port (своей настройки нет): +2, мимо порта прокси роутера. Та же
// мерка у сборки и у правил nft (plumb.uc).
function g_direct_port(tp, lp) {
	let p = int(tp) + 2;
	if (p == int(lp)) p++;
	if (p > 65535) p = int(tp) - 2;
	if (p == int(lp)) p--;
	return '' + p;
}

// Ведущие цифры числом, как «+ 0» в awk: «24abc» -- 24, «abc» -- 0.
function g_lead_int(s) {
	let d = substr(s, 0, length(s) - length(ltrim(s, '0123456789')));
	return d === '' ? 0 : int(d);
}

// ── адреса ────────────────────────────────────────────────────────────────
// Пул в приватном или зарезервированном диапазоне мёртв молча: цепочка nft
// отсекает такие адреса первым правилом. Список тот же, что в RESERVED и в
// правиле блокировки (uc/plumb.uc): править вместе.
function g_pool_sane(p, quiet) {
	let s = index(p, '/');
	let pl = s < 0 ? p : substr(p, s + 1);
	if (pl === '' || ltrim(pl, '0123456789') !== '') {
		if (!quiet) warnf('пул %s без длины маски -- взято умолчание', p);
		return false;
	}
	if (int(pl) < 8 || int(pl) > 30) {
		if (!quiet) warnf('пул %s: маска /%s не годится -- взято умолчание', p, pl);
		return false;
	}
	if (!lj_v4_ok(substr(p, 0, s), false)) {
		if (!quiet) warnf('пул %s: адрес не годится -- взято умолчание', p);
		return false;
	}
	// Весь блок, а не первый адрес: 172.0.0.0/8 начинается вне частных, но
	// накрывает 172.16/12 (Ф9, п4-45). Список -- как RESERVED в uc/plumb.uc.
	let o = split(substr(p, 0, s), '.'), sz = 1 << (32 - int(pl));
	let lo = ((int(o[0]) << 24) | (int(o[1]) << 16) | (int(o[2]) << 8) | int(o[3])) & ~(sz - 1), hi = lo + sz - 1;
	for (let r in [ [ '0.0.0.0', 8 ], [ '10.0.0.0', 8 ], [ '100.64.0.0', 10 ], [ '127.0.0.0', 8 ], [ '169.254.0.0', 16 ],
	                [ '172.16.0.0', 12 ], [ '192.168.0.0', 16 ], [ '224.0.0.0', 3 ] ]) {
		let q = split(r[0], '.'), rs = (int(q[0]) << 24) | (int(q[1]) << 16), re = rs + (1 << (32 - r[1])) - 1;
		if (lo <= re && hi >= rs) {
			if (!quiet) warnf('пул %s задевает приватный или зарезервированный %s/%s -- он мёртв: цепочка nft отсекает такие адреса первым же правилом', p, r[0], r[1]);
			return false;
		}
	}
	return true;
}

// Пул IPv6: образец пропускал «fc00:::/18» и «::/200», Xray отвергал весь
// конфиг, и перехват не поднимался ни для IPv4, ни для IPv6 (Ф9, п4-39).
// Одна мерка для сборки и для nft.
// Годных записей в файле списка (мерка сборки, lj_entry).
function g_nvalid(file, dom) {
	let n = 0;
	for (let l in lj_lines(file)) if (lj_entry(l, dom, '') != null) n++;
	return n;
}

// Пул IPv6 по умолчанию -- один на сборку и перехват (прежде два: в shell
// и в plumb.uc; Ф9, п4-25, прогон 5).
const G_POOL6_DEF = 'fc00::/18';

// Пул -- только в частном fc00::/7 и не шире /16: «::/0» отправлял весь
// IPv6 мостов в tproxy, а подставные адреса совпадали с настоящими
// (Ф9, прогон 5). Та же мерка, что у пула IPv4 (g_pool_sane). Первая группа --
// целиком: «fd::/16» -- это 00fd::, вне fc00::/7 (н1-27). Без жалоб: set, doctor.
function g_pool6_ok(p) {
	if (!match(p, /^[0-9a-fA-F:]+\/[0-9]{1,3}$/) || !lj_v6_ok(p)) return false;
	let pl = int(substr(p, index(p, '/') + 1)), g1 = lc(split(p, ':')[0]);
	return pl >= 16 && pl <= 120 && length(g1) == 4 && (substr(g1, 0, 2) == 'fc' || substr(g1, 0, 2) == 'fd');
}

function g_pool6(def, where) {
	let p = g_val_or('fakeip6_pool', u('fakeip6_pool'), /^[0-9a-fA-F:]+\/[0-9]{1,3}$/, def, where);
	if (p == def || g_pool6_ok(p)) return p;
	warnf('настройка %s = «%s» не годится для %s, взято %s', 'fakeip6_pool', p, where ?? _t(G_WHERE), def);
	return def;
}

// Тот же суд без жалоб (g_pool_sane с quiet): статус, health.
function g_pool_ok(p) { return g_pool_sane(p, true); }

// Число адресов пула: для poolSize и для «список длиннее пула». Нижнего
// ограничителя нет: на /29 и /30 он завышал ёмкость, и защита молчала.
function g_pool_size(p) {
	let l = substr(p, index(p, '/') + 1);
	l = (l === '' || ltrim(l, '0123456789') !== '') ? 15 : int(l);
	if (l < 1 || l > 32) l = 15;
	let n = (1 << (32 - l)) - 2;
	return n < 1 ? 1 : n;
}

// Имя хоста из строки резолвера, пусто для адреса и литерала [IPv6].
function g_dns_host(s) {
	let h = pk_after(s, '://');
	h = pk_before(h, '/');
	if (substr(h, 0, 1) == '[') return '';
	h = pk_before(h, ':');
	return ltrim(h, '0123456789.') === '' ? '' : h;
}

// Адрес IPv4 имени через nslookup; res -- резолвер или пусто.
function g_a_of(name, res) {
	let argv = [ 'nslookup', name ];
	if (res) push(argv, res);
	let on = false;
	for (let l in split(run(argv).out, '\n')) {
		if (substr(l, 0, 5) == 'Name:') on = true;
		if (!on || substr(l, 0, 7) != 'Address') continue;
		let f = split(trim(l), /[ \t]+/);
		let a = f[length(f) - 1];
		if (match(a, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) return a;
	}
	return '';
}

// Настоящий адрес сервера для DNS через туннель: пин /etc/hosts, потом
// внешние резолверы, потом местный (он в этом режиме отдаёт прежний адрес).
function g_server_addr(h) {
	for (let l in split(fs.readfile('/etc/hosts') ?? '', '\n')) {
		let f = split(trim(l), /[ \t]+/);
		if (f[0] == '' || substr(f[0], 0, 1) == '#') continue;
		for (let i = 1; i < length(f); i++)
			if (f[i] == h) {
				if (match(f[0], /^[0-9]+(\.[0-9]+){3}$/)) return f[0];
				break;
			}
	}
	return g_a_of(h, '8.8.8.8') || g_a_of(h, '1.1.1.1') || g_a_of(h, '');
}

// Подсказки к отказам движка, текст которых не говорит, что делать.
function g_xray_hint(t) {
	if (index(t, 'without TLS') >= 0) {
		warn('  Xray-core с 26.7.11 не пускает vless и trojan без TLS или reality к публичному адресу');
		warn('  нужен ключ с security=tls или reality; без шифрования транспорта — только сервер в частной сети');
	} else if (index(t, '"allowInsecure"') >= 0) {
		warn('  Xray-core с 26.3.27 не даёт отключать проверку сертификата сервера (allowInsecure)');
		warn('  нужен отпечаток сертификата в ключе (pcs= или pinSHA256=) либо настоящий сертификат на сервере');
	}
}

// Ширина списка подсетей: миллион адресов
// суммарно или блок шире /12 -- сказать.
function g_net_width(file) {
	let tot = 0, big = 33, f = fs.open(file, 'r'), l;
	if (f) {
		while ((l = f.read('line')) != null && l !== '') {
			l = replace(l, /[ \t\n\r\x0b\x0c]/g, '');
			if (l === '' || substr(l, 0, 1) == '#' || substr(l, 0, 2) == '//') continue;
			let s = index(l, '/');
			let p = s < 0 ? 32 : g_lead_int(substr(l, s + 1));
			let n = 1;
			for (let i = 0; i < 32 - p; i++) n *= 2;
			tot += n;
			if (p < big) big = p;
		}
		f.close();
	}
	return [ tot, big == 33 ? 32 : big ];
}

function g_net_warn(file) {
	let w = g_net_width(file);
	if (w[0] > 1000000 || w[1] <= 12)
		warnf('  ВНИМАНИЕ: %s адресов, крупнейший блок /%s — в туннель уйдёт и чужой трафик, и скорость упадёт', w[0], w[1]);
}

// ── части конфига ─────────────────────────────────────────────────────────
// Ключ: аутбаунд и сообщения; отказ -- null (сообщения разбора тогда не
// печатаются). Направления и автовыбор не должны ронять сборку остальных.
function g_key(url, tag) {
	OB_OUT = [];
	OB_FATAL = null;
	let k = null;
	try {
		k = ob_key(url, tag, G.psni, G.pws);
	} catch (e) {
		if (e.message !== OB_STOP) raise(e.message);
	}
	if (k) { G.psni = k.N.SNI; G.pws = k.N.WSHOST; }
	return k;
}

// Направления со своим выходом: ноды, правила, хосты; домены направлений,
// получивших правило, в общее правило не идут (в fakedns -- идут).
function g_routes() {
	G.route_out = []; G.route_hosts = []; G.route_rules = []; G.route_skip = null;
	let secs = [], all = cursor().get_all('byway') ?? {};
	for (let n in all) if (all[n]['.type'] == 'route') push(secs, all[n]);
	secs = sort(secs, (a, b) => a['.index'] - b['.index']);
	let urls = ul('node_urls'), skip = {}, nok = 0;
	OB_QUIET_PARSE = true;
	for (let sec in secs) {
		let rn = sec['.name'];
		if (sec.enabled == '0') continue;
		let lb = sec.label ?? '';
		let rf = G.routes + '/' + rn + '.lst';
		let st = fs.stat(rf);
		if (!st || !st.size) { warnf('направление «%s»: список %s пуст, пропущено', rn, rf); continue; }
		let url = null;
		for (let k in urls) {
			if (k === '') continue;
			// Мерка метки -- как у разбора и панели (pk_label).
			if (pk_label(k) == lb) { url = k; break; }
		}
		if (url == null) { warnf('направление «%s»: ключа с меткой «%s» среди добавленных нет', rn, lb); continue; }
		let k = g_key(url, 'route-' + rn);
		// Причина -- из OB_FATAL одной строкой (Ф9, п4-4); из накопленного --
		// только предупреждения: отказ печатался второй раз меткой [x], как
		// отказ всей сборки (прогон 5).
		if (!k) {
			warnf('направление «%s»: ключ не разбирается (%s), пропущено', rn, OB_FATAL ?? '?');
			ob_emit(filter(OB_OUT, (m) => m.c == 'warn' || m.c == 'warnf'), true);
			continue;
		}
		ob_emit(OB_OUT);
		push(G.route_out, k.block);
		push(G.route_hosts, k.N.HOST);
		// Пробел внутри строки -- не запись, а строка формата hosts
		// («0.0.0.0 example.com»): в отброшенные, не склеивать.
		let dom = [], net = [];
		for (let l in lj_lines(rf)) {
			if (match(l, /[ \t\n\r\x0b\x0c]/)) { lj_reject(l); continue; }
			if (match(l, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/)) push(net, l);
			else { push(dom, l); skip[l] = true; }
		}
		let d = lj_items(dom, 'domain:'), s = lj_items(net, '');
		if (length(d)) push(G.route_rules, { type: 'field', domain: { __bw_list: d }, outboundTag: 'route-' + rn });
		if (length(s)) push(G.route_rules, { type: 'field', ip: { __bw_list: s }, outboundTag: 'route-' + rn });
		nok++;
	}
	OB_QUIET_PARSE = false;
	if (nok) {
		G.route_skip = skip;
		sayf('направлений со своим выходом: %s', nok);
	}
}

// Резолверы: пул fakeip, основной и запасной upstream, bootstrap.
function g_dns() {
	let p = g_val_or('fakeip_pool', u('fakeip_pool'), G_POOL_RE, '198.18.0.0/15');
	G.pool = g_pool_sane(p) ? p : '198.18.0.0/15';
	// Только то, что Xray понимает адресом сервера DNS (app/dns/nameserver.go):
	// udp://, tls:// и quic:// он принимал на -test, а DNS молчал (Ф9, п3-52).
	let re = /^(https|tcp):\/\/[A-Za-z0-9._:\/?=&%+-]+$/;
	G.up = g_val_or('dns_upstream', u('dns_upstream'), re, 'https://8.8.8.8/dns-query');
	// Запасной: Xray идёт к следующему серверу, когда предыдущий молчит.
	// Умолчание -- другой провайдер, отключает none.
	let u2 = u('dns_upstream2');
	G.up2 = (u2 == 'none' || u2 == 'off' || u2 == '-') ? '' : g_val_or('dns_upstream2', u2, re, 'https://1.1.1.1/dns-query');
	if (G.up2 == G.up) G.up2 = '';
	// bootstrap: имя DoH-сервера byway умеет спросить только у него же --
	// круг. Простой резолвер строго для этих имён.
	let bh = [];
	for (let x in [ G.up, G.up2 ]) {
		if (x === '') continue;
		let h = g_dns_host(x);
		if (h !== '') push(bh, 'full:' + h);
	}
	G.boot = null;
	if (length(bh)) {
		let bs = g_val_or('dns_bootstrap', u('dns_bootstrap'), G_BOOT_RE, '');
		if (bs !== '') {
			G.boot = { address: bs, domains: bh, skipFallback: true };
		} else {
			warn('резолвер задан именем, а bootstrap не задан — разрешать имя нечем, взяты адреса по умолчанию');
			warn('  вписать: byway set dns_bootstrap 77.88.8.8');
			G.up = 'https://8.8.8.8/dns-query';
			G.up2 = 'https://1.1.1.1/dns-query';
		}
	}
}

// Входы: DNS, tproxy, прокси роутера; метка и развилка direct по
// версии Xray.
function g_inbounds() {
	G.dns_listen = g_dns_listen(true);
	G.tp = g_val_or('tproxy_port', u('tproxy_port'), /^[0-9]{1,5}$/, '1602');
	if (!g_port_ok(G.tp)) G.tp = '1602';
	G.lp = g_val_or('local_proxy_port', u('local_proxy_port'), /^[0-9]{1,5}$/, '1603');
	if (!g_port_ok(G.lp)) G.lp = '1603';
	// Метка на исходящих сокетах движка при «VPN для программ на роутере»
	// (иначе петля через цепочку output) и у движка от root: по uid его не
	// узнать, а запрет ходить на свои адреса роутера держится на метке (Ф9,
	// п1-17). Метку передаёт shell (ob_env_mark) ровно в этих случаях.
	G.mark = getenv('BW_SELFMARK') ? int(getenv('BW_SELFMARK')) : null;
	// С 26.9.8 domainStrategy у direct живёт в sockopt; старым ядрам -- в settings.
	G.direct_ds = G.xver < 260908;
}

// Уровень журнала и журнал обращений.
function g_log() {
	let l = u('log_level');
	if (l != 'debug' && l != 'info' && l != 'warning' && l != 'error' && l != 'none') {
		if (l !== '') warnf('уровень журнала «%s» не годится, взят warning', l);
		l = 'warning';
	}
	G.loglevel = l;
	// Журнал обращений -- для «чем пользуются» и для отладки; в режиме «всё
	// через VPN» сбора нет: журнал писал бы адрес каждого соединения дома.
	if (l == 'info' || l == 'debug' || (u('show_usage') == '1' && u('list_mode') != 'all')) {
		G.access = G.access_file;
	} else {
		G.access = 'none';
		// Усекаем, не удаляем: движок держит файл открытым.
		if (fs.stat(G.access_file)) fs.writefile(G.access_file, '');
	}
}

// Аутбаунды; сообщения -- печатью, отказ -- выход.
function g_outbounds(skip) {
	OB_OUT = [];
	let R = null;
	try {
		R = ob_proxies(skip, G.psni, G.pws);
	} catch (e) {
		if (e.message !== OB_STOP) raise(e.message);
	}
	ob_emit(OB_OUT);
	G.psni = R.N.SNI; G.pws = R.N.WSHOST;
	G.R = R;
	// Ноды направлений тоже в исключения: иначе петля.
	G.vpn_hosts = [ ...R.hosts, ...G.route_hosts ];
}

// Пул v6, правило блокировки приватного, DNS через туннель.
function g_dns_route() {
	G.fake6 = null; G.qstrat = 'UseIPv4'; G.tp_listen = '0.0.0.0';
	let b6 = [ '::/128', '::1/128', 'fc00::/7', 'fe80::/10' ];
	if (u('ipv6') == '1') {
		let p6 = g_pool6(G_POOL6_DEF);
		G.fake6 = { ipPool: p6, poolSize: G.pool_size };
		G.qstrat = 'UseIP';
		G.tp_listen = '::';
		push(b6, p6);
	}
	// Приватное, зарезервированное и пулы fakeip одним списком: правило
	// маршрута и итоговые правила direct обязаны совпадать.
	G.privnets = [ '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	               '172.16.0.0/12', '192.168.0.0/16', G.pool, '224.0.0.0/4', '240.0.0.0/4', ...b6 ];
	// Итоговые правила freedom (26.5.9+) сверяют уже разрешённый адрес: имя
	// из Host не уведёт direct в домашнюю сеть. blockDelay 0: иначе движок
	// держит отказанное соединение 30-90 с.
	G.route_strat = 'IPIfNonMatch';
	G.final = null;
	if (G.xver >= 260509) G.final = [ { action: 'block', blockDelay: 0, ip: G.privnets } ];
	else G.route_strat = 'IPOnDemand';
	// Запросы встроенного DNS идут через маршрутизацию: своё правило всегда,
	// меняется цель.
	let dr = u('dns_route');
	if (dr !== '' && dr != 'direct' && dr != 'tunnel')
		warnf('dns_route=%s не понят — DNS идёт напрямую; допустимо direct или tunnel', dr);
	G.dns_hosts = null;
	G.dns_rule = { type: 'field', inboundTag: [ 'dns-query' ], outboundTag: 'direct' };
	if (dr == 'tunnel') {
		// Адрес ноды разрешается при сборке и кладётся статически: иначе
		// запрос ушёл бы в ещё не поднятый туннель.
		let hh = {}, any = false;
		for (let h in G.vpn_hosts) {
			if (!match(h, /[a-zA-Z]/)) continue;
			let ip = g_server_addr(h);
			// Последняя опора -- адрес из прежнего конфига.
			if (ip === '')
				ip = split(run([ 'sed', '-n', 's/.*"' + h + '"[[:space:]]*:[[:space:]]*"\\([0-9.]*\\)".*/\\1/p', G.out ]).out, '\n')[0] ?? '';
			if (ip === '') {
				if (G.R.N.PROTO == 'raw') {
					warnf('адрес %s из своего конфига не разрешился — пропущен', h);
					continue;
				}
				dief('адрес сервера %s не разрешился — без него DNS через туннель не собрать (запросы к серверу ушли бы в сам туннель); проверить интернет и DNS роутера', h);
			}
			hh[h] = ip; any = true;
		}
		if (any) G.dns_hosts = hh;
		G.dns_rule = { type: 'field', inboundTag: [ 'dns-query' ], ...G.R.target };
	}
}

// Конфиг объектом. Большие списки -- маркерами { __bw_list }: файл пишется в
// конфиг потоком при выводе, не через память.
function g_config() {
	let R = G.R;
	let fake = [ { ipPool: G.pool, poolSize: G.pool_size } ];
	if (G.fake6) push(fake, G.fake6);
	let servers = [];
	if (G.boot) push(servers, G.boot);
	push(servers, G.up);
	if (G.up2 !== '') push(servers, G.up2);
	// Имя сервера ключа, накрытое записью списка, движок разрешал через свой
	// же fakedns -- туннель мёртв, а проверки зелёные (н1-20). Настоящим
	// резолвером, до fakedns; при dns_route=tunnel их держит dns.hosts.
	if (!G.dns_hosts) {
		let hn = filter(G.vpn_hosts, (h) => h !== '' && match(h, /[a-zA-Z]/) && ltrim(h, ALNUM + '.-') === '');
		if (length(hn))
			push(servers, { ...(type(G.up) == 'object' ? G.up : { address: G.up }),
			                domains: map(hn, (h) => 'full:' + h), skipFallback: true });
	}
	// Проба -- и в fakedns: без fakeip клиент ушёл бы мимо перехвата.
	push(servers, { address: 'fakedns', skipFallback: true,
	                domains: [ { __bw_list: G.merged, pfx: 'domain:' }, 'full:' + G.probe ] });
	let dns = {};
	if (G.dns_hosts) dns.hosts = G.dns_hosts;
	dns.servers = servers;
	dns.queryStrategy = G.qstrat;
	dns.tag = 'dns-query';

	let sniff = { enabled: true, destOverride: [ 'fakedns', 'http', 'tls', 'quic' ], metadataOnly: false, routeOnly: false };
	let inb = [
		{ tag: 'dns-in', listen: G.dns_listen, port: 53, protocol: 'dokodemo-door',
		  settings: { address: G.dns_listen, port: 53, network: 'tcp,udp' } },
		// Не петля, а 0.0.0.0 (или "::"): tproxy не переписывает адрес
		// назначения, сокет на 127.0.0.1 пакет с 198.18.x.x не поймает.
		{ tag: 'tproxy-in', listen: G.tp_listen, port: int(G.tp), protocol: 'dokodemo-door',
		  settings: { network: 'tcp,udp', followRedirect: true },
		  streamSettings: { sockopt: { tproxy: 'tproxy' } }, sniffing: sniff },
		// Сети вне interface: подставной адрес -- обратно в имя и напрямую
		// (Ф9, п1-18). Сниффинг -- только fakedns: Host из http/tls подменил
		// бы адрес назначения, и вход стал бы форвардером в локальную сеть.
		{ tag: 'tproxy-direct', listen: G.tp_listen, port: int(g_direct_port(G.tp, G.lp)), protocol: 'dokodemo-door',
		  settings: { network: 'tcp,udp', followRedirect: true },
		  streamSettings: { sockopt: { tproxy: 'tproxy' } },
		  sniffing: { enabled: true, destOverride: [ 'fakedns' ], metadataOnly: false, routeOnly: false } },
		// Прокси для самого роутера: им byway скачивает себя и списки, в том
		// числе до правил перехвата.
		{ tag: 'local-in', listen: '127.0.0.1', port: int(G.lp), protocol: 'http',
		  sniffing: { enabled: true, destOverride: [ 'http', 'tls' ], metadataOnly: false, routeOnly: false } },
	];
	let direct = { tag: 'direct', protocol: 'freedom' }, set = {}, so = {};
	if (G.direct_ds) set.domainStrategy = 'UseIP'; else so.domainStrategy = 'UseIP';
	if (G.final) set.finalRules = G.final;
	if (G.mark != null) so.mark = G.mark;
	if (length(keys(set))) direct.settings = set;
	if (length(keys(so))) direct.streamSettings = { sockopt: so };
	let dnsout = { tag: 'dns-out', protocol: 'dns' };
	if (G.mark != null) dnsout.streamSettings = { sockopt: { mark: G.mark } };
	let outb = [ ...R.blocks, ...G.route_out, direct, dnsout, { tag: 'block', protocol: 'blackhole' } ];

	// Вход «напрямую» -- до всех правил: направления и списки его не касаются.
	// Без имени (подставной адрес прежнего запуска) назначение -- сам пул, он
	// в privnets: блок, а не виток (Ф9, п1-18).
	let rules = [ { type: 'field', inboundTag: [ 'dns-in' ], outboundTag: 'dns-out' }, G.dns_rule,
	              { type: 'field', inboundTag: [ 'tproxy-direct' ], ip: G.privnets, outboundTag: 'block' },
	              { type: 'field', inboundTag: [ 'tproxy-direct' ], outboundTag: 'direct' } ];
	// Направления -- ПЕРЕД общими правилами: Xray берёт первое совпавшее.
	for (let r in G.route_rules) push(rules, r);
	if (u('list_mode') == 'all') {
		// «Всё через VPN»: исключение -- сам сервер VPN, иначе его адрес ушёл
		// бы в ещё не поднятый туннель. Русские зоны мимо (.рф -- пуникодом).
		if (G.route_strat == 'IPOnDemand')
			push(rules, { type: 'field', ip: G.privnets, outboundTag: 'block' });
		if (u('ru_direct') == '1')
			push(rules, { type: 'field', domain: [ 'domain:ru', 'domain:su', 'domain:xn--p1ai' ], outboundTag: 'direct' });
		for (let h in G.vpn_hosts) {
			if (h === '' || h == '-' || ltrim(h, ALNUM + '.:_-') !== '') continue;
			if (match(h, /[a-zA-Z]/))
				push(rules, { type: 'field', domain: [ 'full:' + h ], outboundTag: 'direct' });
			else
				push(rules, { type: 'field', ip: [ h + '/32' ], outboundTag: 'direct' });
		}
	} else {
		// Домен-проба -- всегда: проверка «трафик проходит» смотрит через него
		// всю цепочку. Пустой список подсетей -- без правила: Xray отвергает
		// пустой массив.
		push(rules, { type: 'field', domain: [ { __bw_list: G.merged, pfx: 'domain:', skip: G.route_skip }, 'full:' + G.probe ], ...R.target });
		if (length(G.subnets))
			push(rules, { type: 'field', ip: { __bw_list: G.subnets }, ...R.target });
	}
	// Приватное, зарезервированное и пул -- в блок, и ОБЯЗАТЕЛЬНО до direct:
	// иначе вход tproxy -- открытый форвардер («Host: 192.168.1.1» от гостя),
	// а соединение на сам пул порождает витки без ограничителя.
	push(rules, { type: 'field', ip: G.privnets, outboundTag: 'block' });
	push(rules, { type: 'field', network: 'tcp,udp', ...R.last });

	let routing = {};
	if (R.balancers) routing.balancers = R.balancers;
	routing.domainStrategy = G.route_strat;
	routing.rules = rules;

	let c = { log: { loglevel: G.loglevel, access: G.access }, fakedns: fake, dns: dns,
	          inbounds: inb, outbounds: outb };
	if (R.observatory) c.observatory = R.observatory;
	c.routing = routing;
	return c;
}

// ── вывод ─────────────────────────────────────────────────────────────────
// Раскладка как прежде: объекты верхних уровней по строке на поле, правила и
// аутбаунды -- строкой, списки -- по записи на строку.
const G_DEPTH = { log: 0, fakedns: 0, dns: 2, inbounds: 2, outbounds: 1, observatory: 0, routing: 2 };

function g_is_list(v) { return type(v) == 'object' && v.__bw_list != null; }

function g_has_list(v) {
	let t = type(v);
	if (g_is_list(v)) return true;
	if (t == 'array') { for (let x in v) if (g_has_list(x)) return true; }
	else if (t == 'object') { for (let k in v) if (g_has_list(v[k])) return true; }
	return false;
}

// Записи маркера -- в массив: из памяти (массив строк) или потоком из файла.
function g_write_list(f, m, ind, first) {
	if (type(m.__bw_list) == 'array') {
		if (!length(m.__bw_list)) return 0;
		let a = [];
		for (let x in m.__bw_list) push(a, ind + sprintf('%J', x));
		f.write((first ? '\n' : ',\n') + join(',\n', a));
		return length(a);
	}
	// Отступ большого списка -- постоянный, как прежде: по строке на запись, и
	// два лишних пробела на 200 000 записей -- 0,8 МБ флеша.
	return lj_stream(f, m.__bw_list, m.pfx ?? '', m.skip, '        ', first);
}

function g_write(f, v, ind, n) {
	let t = type(v);
	if ((t != 'object' && t != 'array') || (n <= 0 && !g_has_list(v))) {
		f.write(sprintf('%J', v));
		return;
	}
	let ni = ind + '  ';
	if (g_is_list(v)) v = [ v ];
	if (type(v) == 'object') {
		let ks = keys(v);
		if (!length(ks)) { f.write('{ }'); return; }
		f.write('{\n');
		for (let i = 0; i < length(ks); i++) {
			f.write(ni + sprintf('%J', ks[i]) + ': ');
			g_write(f, v[ks[i]], ni, n - 1);
			f.write(i < length(ks) - 1 ? ',\n' : '\n');
		}
		f.write(ind + '}');
		return;
	}
	f.write('[');
	let first = true;
	for (let x in v) {
		if (g_is_list(x)) {
			if (g_write_list(f, x, ni, first)) first = false;
			continue;
		}
		f.write(first ? '\n' : ',\n');
		first = false;
		f.write(ni);
		g_write(f, x, ni, n - 1);
	}
	f.write(first ? ' ]' : '\n' + ind + ']');
}

// Черновик в память (/tmp), не во флеш: живёт секунды, а на неудачной сборке
// оставался бы файл с uuid. Права 600 до записи; движок не от root читает
// конфиг группой byway.
function g_write_tmp(c) {
	// Сперва удалить: имя предсказуемо, /tmp общий -- сосед мог создать файл
	// 0666 заранее и читать конфиг.
	fs.unlink(G_TMP);
	let f = fs.open(G_TMP, 'w', 0600);
	if (!f) dief('черновик конфига %s не записан: %s', G_TMP, fs.error());
	if (run([ 'chgrp', 'byway', G_TMP ]).code == 0) fs.chmod(G_TMP, 0640);
	f.write('{\n');
	let ks = keys(c);
	for (let i = 0; i < length(ks); i++) {
		f.write('  ' + sprintf('%J', ks[i]) + ': ');
		g_write(f, c[ks[i]], '  ', G_DEPTH[ks[i]] ?? 1);
		f.write(i < length(ks) - 1 ? ',\n\n' : '\n');
	}
	f.write('}\n');
	f.close();
}

function g_test() {
	let r = run([ G.xray, 'run', '-test', '-c', G_TMP ], true);
	return { ok: r.code == 0, out: rtrim(r.out, '\n') };
}

// Регулярку судит только сам движок (RE2 Go; мерка ucode расходится с ней),
// и одна негодная роняла всю сборку (Ф9, п3-3). Отвергнутые ищутся делением
// пополам на маленьком конфиге из одного правила; первое -- проверка всех.
const G_RETMP = '/var/run/byway-re-test.json';
function g_re_ok(a) {
	fs.unlink(G_RETMP);
	let f = fs.open(G_RETMP, 'w', 0600);
	if (!f) return true;
	f.write(sprintf('%J', { outbounds: [ { tag: 'direct', protocol: 'freedom' } ],
	        routing: { rules: [ { type: 'field', domain: a, outboundTag: 'direct' } ] } }));
	f.close();
	let ok = run([ G.xray, 'run', '-test', '-c', G_RETMP ], true).code == 0;
	fs.unlink(G_RETMP);
	return ok;
}

function g_re_bad(a) {
	if (!length(a) || g_re_ok(a)) return [];
	if (length(a) == 1) return a;
	let h = int(length(a) / 2);
	return [ ...g_re_bad(slice(a, 0, h)), ...g_re_bad(slice(a, h)) ];
}

// Отвергнутые -- из правил направлений (их записи уже в памяти) и в
// LJ_RE_SKIP для потока общего списка; правило без записей -- долой.
function g_re_drop(bad) {
	LJ_RE_SKIP = {};
	for (let x in bad) LJ_RE_SKIP[x] = true;
	let rr = [];
	for (let r in G.route_rules) {
		if (type(r.domain) == 'object' && type(r.domain.__bw_list) == 'array') {
			let k = [];
			for (let x in r.domain.__bw_list)
				if (LJ_RE_SKIP[x]) lj_reject(x); else push(k, x);
			r.domain.__bw_list = k;
			if (!length(k)) continue;
		}
		push(rr, r);
	}
	G.route_rules = rr;
}

// Отброшенные записи -- вслух: молчаливая потеря выглядит как «byway не
// работает с этим доменом». Уникальные: список читается дважды.
function g_report_bad() {
	if (LJ_BF) { LJ_BF.close(); LJ_BF = null; }
	let seen = {}, bad = [];
	for (let l in split(fs.readfile(G.badlist) ?? '', '\n'))
		if (l !== '' && !seen[l]) { seen[l] = true; push(bad, l); }
	if (!length(bad)) return;
	bad = sort(bad);
	warnf('записей отброшено как неподходящие: %s', length(bad));
	for (let i = 0; i < length(bad) && i < 10; i++) warnf('    %s', bad[i]);
	if (length(bad) > 10)
		warnf('    … и ещё %s (весь список: sort -u %s)', length(bad) - 10, G.badlist);
	warn('  причина: не похоже ни на домен (буквы, цифры, дефис и точки; последняя часть — не короче двух букв), ни на подсеть IPv4, либо длиннее 253 знаков, либо регулярку (regexp:) не принял движок');
}

// bw_uc gen: окружение -- от cmd_gen (config/gen.sh).
function cmd_gen() {
	if (run([ 'test', '-x', xray_bin() ]).code != 0) die('xray не найден');
	G = { out: getenv('BW_OUT'), lists: getenv('BW_LISTS'), routes: getenv('BW_ROUTES'),
	      merged: getenv('BW_MERGED'), subnets_file: getenv('BW_SUBNETS'), badlist: getenv('BW_BADLIST'),
	      access_file: getenv('BW_ACCESS'), probe: getenv('BW_PROBE'), xray: xray_bin(),
	      xver: xray_ver(), psni: '', pws: '' };
	LJ_BAD = G.badlist;
	LJ_BF = null;
	LJ_RE = {};
	LJ_RE_SKIP = null;
	let D = G.lists + '/domains.lst';

	g_routes();
	if (!fs.stat(D)) dief('нет списка доменов %s', D);
	if (!fs.stat(G.subnets_file))
		warnf('нет списка подсетей %s — правило по адресам не будет создано', G.subnets_file);
	g_dns();
	g_inbounds();
	g_log();
	// poolSize -- потолок пар «домен-адрес»; вытесненная пара отдаёт адрес
	// другому домену, и соединение уходит к чужому хосту без ошибки.
	G.pool_size = g_pool_size(G.pool);
	let dcount = lj_count(G.merged);
	if (dcount > G.pool_size)
		warnf('доменов %s, а адресов в пуле %s — часть будет вытесняться и уводить соединения к чужому хосту. Расширить пул (byway.main.fakeip_pool) либо укоротить список', dcount, G.pool_size);
	// Адрес берёт каждое спрошенное имя, а не запись списка: example.org
	// с поддоменами расходует пул на все. Малый пул молчал при одной
	// записи, а 17-й поддомен получал адрес первого (Ф9, п3-56).
	else if (G.pool_size < 4096)
		warnf('в пуле подставных адресов всего %s: адрес берёт каждое имя, включая поддомены, и при нехватке он переходит к другому домену — соединение уйдёт к чужому хосту. Расширить пул (byway.main.fakeip_pool), например до /16', G.pool_size);
	g_outbounds('');
	g_dns_route();
	G.subnets = (u('list_mode') != 'all' && fs.stat(G.subnets_file)) ?
		lj_items(lj_lines(G.subnets_file), '') : [];
	g_write_tmp(g_config());

	// Каталог журнала обращений: движок при проверке открывает файл.
	if (!fs.stat('/var/run/byway')) { fs.mkdir('/var/run/byway', 0755); fs.chmod('/var/run/byway', 0755); }
	let t = g_test();
	if (!t.ok && match(t.out, /error parsing regexp/)) {
		let bad = g_re_bad(sort(keys(LJ_RE)));
		if (length(bad)) {
			g_re_drop(bad);
			g_write_tmp(g_config());
			t = g_test();
		}
	}
	// Автовыбор: ключ, который отвергает только сам движок, снимается, и
	// сборка повторяется; хотя бы один ключ остаётся. Предела в шесть кругов
	// нет: седьмой отвергнутый ронял сборку при годных ключах (Ф9, п2-7);
	// каждый круг снимает ключ, повтор того же -- выход.
	let skip = '', gone = {};
	while (!t.ok && u('conn_mode') == 'urltest' && G.R.n > 1) {
		let bk = null, line = null;
		for (let l in split(t.out, '\n')) {
			let m = match(l, /.*proxy-([0-9]+)/);
			if (m) { bk = int(m[1]); break; }
		}
		if (bk == null || G.R.keyidx[bk] == null) break;
		let bki = G.R.keyidx[bk];
		if (gone[bki]) break;
		gone[bki] = true;
		for (let l in split(t.out, '\n')) if (index(l, 'proxy-' + bk) >= 0) { line = l; break; }
		warnf('ключ %s отвергнут движком — пропущен: %s', bki + 1, substr(pk_lastafter(line ?? '', '> '), 0, 120));
		skip += ' ' + bki;
		g_outbounds(skip);
		g_dns_route();
		g_write_tmp(g_config());
		t = g_test();
	}
	if (!t.ok) {
		warnf('движок отверг конфиг, черновик остался в %s:', G_TMP);
		let ls = split(t.out, '\n');
		for (let l in slice(ls, length(ls) > 5 ? length(ls) - 5 : 0)) print('    ', l, '\n');
		g_xray_hint(t.out);
		exit(1);
	}
	// Предупреждения движка не глотать: транспорт помечают устаревшим за
	// версию-другую до удаления.
	let dw = {}, dl = [];
	for (let l in split(t.out, '\n')) {
		if (!match(l, /deprecated|will be removed|migrate to/i)) continue;
		let i = rpos(l, 'errors: ');
		let w = substr(i < 0 ? l : substr(l, i + 8), 0, 96);
		if (!dw[w]) { dw[w] = true; push(dl, w); }
	}
	for (let w in sort(dl)) warnf('движок: %s', w);
	g_report_bad();

	let R = G.R, N = R.N;
	// Не изменилось -- рабочий не трогаем: панель и procd зовут gen при каждом
	// «Сохранить и применить».
	if (run([ 'cmp', '-s', G_TMP, G.out ]).code == 0) {
		fs.unlink(G_TMP);
		say('конфиг не изменился, рабочий оставлен как есть');
		sayf('  доменов %s, подсетей %s', dcount, length(G.subnets));
		return;
	}
	// Место -- до подмены: обрыв записи оставил бы половину конфига.
	let need = int(fs.stat(G_TMP).size / 1024) + 32;
	let df = split(split(run([ 'df', '-k', G.lists ]).out, '\n')[1] ?? '', /[ \t]+/);
	let have = df[3] ?? '';
	if (have !== '' && int(have) < need)
		dief('на флеше свободно %s КБ, для конфига нужно %s -- рабочий не тронут', have, need);
	// /tmp и флеш -- разные ФС: mv копирует прямо в рабочий файл, и обрыв
	// посередине оставлял его обрезанным (Ф9, п2-23). Копия рядом, сверка,
	// права -- и только потом переименование одним шагом.
	let nw = G.out + '.new', sz = fs.stat(G_TMP).size;
	let cp = run([ 'cp', G_TMP, nw ], true);
	if (cp.code != 0 || fs.stat(nw)?.size != sz) {
		fs.unlink(nw);
		dief('конфиг не перенесён на место: %s', trim(cp.out) || _t('на флеше нет места?'));
	}
	// В конфиге uuid ключа: root и, когда движок не от root, группа byway.
	if (u('xray_root') != '1' && run([ 'test', '-x', '/sbin/ujail' ]).code == 0 &&
	    run([ 'chgrp', 'byway', nw ]).code == 0)
		fs.chmod(nw, 0640);
	else
		fs.chmod(nw, 0600);
	if (!fs.rename(nw, G.out)) { fs.unlink(nw); dief('конфиг не перенесён на место: %s', fs.error() ?? '?'); }
	fs.unlink(G_TMP);
	sayf('конфиг собран и проверен движком: %s (%s байт)', G.out, fs.stat(G.out).size);
	// Годных, а не строк: отброшенные входили в итог («подсетей 5» при одной
	// годной; прогон 5).
	let own = g_nvalid(D, true), ns = length(G.subnets);
	// Разбивка -- когда есть чему добавить: по числам строк её давали и
	// отброшенные записи своего списка.
	if (u('preset') !== '' || length(G.route_out))
		sayf('  доменов %s (в своём списке %s, остальное — направления и пресеты), подсетей %s', dcount, own, ns);
	else
		sayf('  доменов %s, подсетей %s', own, ns);
	if (u('conn_mode') == 'urltest')
		sayf('  подключение: %s — Xray-core выбирает рабочий ключ по задержке', N.LABEL);
	else
		sayf('  подключение: %s (%s:%s), транспорт %s, защита %s', N.LABEL || N.HOST, N.HOST, N.PORT, N.TYPE, N.SEC);
	// Ширина -- по объединённому списку: 0.0.0.0/0 молча делает из «по
	// спискам» полный туннель.
	g_net_warn(G.subnets_file);
	sayf('  пул fakeip %s, DNS-вход %s:53, tproxy %s, прокси роутера 127.0.0.1:%s', G.pool, G.dns_listen, G.tp, G.lp);
}
