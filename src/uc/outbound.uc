// Аутбаунд Xray из разобранного ключа: транспорт, защита (tls, reality), flow,
// mux, протокол -- перенос build_stream, build_outbound, proxy_block и
// build_proxies из shell. JSON собирается объектами, не склейкой строк.
// Сообщения копятся записями по порядку и печатаются вызывающим (ob_emit):
// gen, check, probe.
// Функции -- верхнего уровня, состояние -- OB_* (см. uc/keys.uc о ucode 22.03).

const OB_STOP = '__byway_outbound_stop__';
// OB_QUIET_PARSE: сообщения разбора не выводить (направления: сообщения
// разбора молчат, сообщения транспорта -- на экран).
let OB_OUT = [], OB_QUIET_PARSE = false, OB_FATAL = null;

// Сообщение -- записью { c: warn|warnf|die|dief, f, a, e: в stderr }; в тихом
// прогоне (проба ключа автовыбора) копятся, отказ запоминается текстом для
// «ключ пропущен».
function ob_cmd(name, fmt, args, err) {
	push(OB_OUT, { c: name, f: fmt, a: args, e: err });
}
function ob_warn(m)          { ob_cmd('warn', m, []); }
function ob_warnf(m, ...a)   { ob_cmd('warnf', m, a); }
function ob_die(m)           { OB_FATAL = _t(m); ob_cmd('die', m, []); raise(OB_STOP); }
function ob_dief(m, ...a)    { OB_FATAL = _pf(_t(m), a); ob_cmd('dief', m, a); raise(OB_STOP); }

// val_or: значение настройки по образцу, иначе умолчание с жалобой в stderr.
function ob_val_or(name, val, re, def, where) {
	if (val === '') return def;
	if (match(val, /[\x01-\x1f\x7f]/)) {
		ob_cmd('warnf', 'настройка %s содержит управляющие знаки и не годится для %s, взято %s', [ name, where, def ], true);
		return def;
	}
	if (match(val, re)) return val;
	ob_cmd('warnf', 'настройка %s = «%s» не годится для %s, взято %s', [ name, val, where, def ], true);
	return def;
}

function ob_xver() { return xray_ver(); }

// Версия ядра для сообщения: первая строка `xray version`, поля как у cut.
function ob_xrayv(fields) {
	let r = run([ xray_bin(), 'version' ]);
	let f = split(split(r.out, '\n')[0], ' ');
	return fields == 2 ? (f[1] ?? '') : join(' ', slice(f, 0, 2));
}

function ob_private(h) {
	return match(h, /^(10\.|192\.168\.|127\.|169\.254\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)/) != null;
}

// streamSettings: транспорт по N.TYPE.
function ob_transport(N) {
	let xv = ob_xver();
	let t = N.TYPE;
	if (t == 'ws') {
		// host отдельным полем с 1.8.24; у 1.8.3 (22.03) -- в headers.
		if (xv < 10824)
			return { network: 'ws', wsSettings: { path: N.PATH, headers: { Host: N.WSHOST } } };
		return { network: 'ws', wsSettings: { path: N.PATH, host: N.WSHOST } };
	}
	if (t == 'tcp' || t == 'raw') {
		if (N.HDR == 'http')
			return { network: 'tcp', tcpSettings: { header: { type: 'http',
				request: { path: [ N.PATH ], headers: { Host: [ N.WSHOST ] } } } } };
		return { network: 'tcp' };
	}
	if (t == 'kcp') {
		ob_warn('mkcp идёт поверх UDP, а в РФ UDP душат первым делом');
		// header и seed: до 26.1.23 работают, с 26.1.31 удалены (finalmask).
		let k = {};
		if (N.HDR != '') k.header = { type: N.HDR };
		if (N.SEED != '') k.seed = N.SEED;
		if (length(k) && xv >= 260131) {
			ob_warn('header и seed у mkcp удалены в Xray-core с 26.1.31 и в конфиг не пишутся: сервер с маскировкой mKCP не ответит; замена на сервере и в ключе — finalmask (mkcp-original, mkcp-aes128gcm)');
			k = {};
		}
		return length(k) ? { network: 'kcp', kcpSettings: k } : { network: 'kcp' };
	}
	if (t == 'grpc') {
		let g = { serviceName: N.SVC };
		if (N.MODE == 'multi') g.multiMode = true;
		if (N.AUTH != '') g.authority = N.AUTH;
		return { network: 'grpc', grpcSettings: g };
	}
	if (t == 'h2' || t == 'http') {
		ob_warn('HTTP/2 из Xray-core удалён, замена: xhttp в режиме stream-one');
		return { network: t, httpSettings: { path: N.PATH, host: [ N.WSHOST ] } };
	}
	if (t == 'quic') {
		ob_warn('QUIC из Xray-core удалён, замена: xhttp stream-one поверх H3; в РФ QUIC блокируют первым делом');
		return { network: 'quic', quicSettings: { security: N.QSEC || 'none', key: N.QKEY,
			header: { type: N.HDR || 'none' } } };
	}
	if (t == 'httpupgrade') {
		if (xv < 10824)
			ob_warn('движок старый: транспорт httpupgrade он может не знать, и тогда конфиг соберётся, а туннель не встанет');
		return { network: 'httpupgrade', httpupgradeSettings: { path: N.PATH, host: N.WSHOST } };
	}
	if (t == 'xhttp') {
		if (xv < 10824)
			ob_dief('движку %s транспорт xhttp неизвестен (нужен Xray-core 1.8.24 или новее) — обновить: byway engine tested, либо взять ключ на ws', ob_xrayv(12));
		let x = { path: N.PATH, host: N.WSHOST };
		if (N.MODE != '') x.mode = N.MODE;
		// extra -- один объект (json_obj_ok в разборе); не JSON вовсе --
		// отказ здесь, прежде отвергал движок.
		if (N.EXTRA != '') {
			let e = null;
			try { e = json(N.EXTRA); } catch (err) { e = null; }
			if (type(e) != 'object')
				ob_die('параметр extra в ссылке -- не один объект JSON: он подставляется в конфиг как есть, и такая ссылка переписывает соседние поля, включая адрес сервера и защиту');
			x.extra = e;
		}
		return { network: 'xhttp', xhttpSettings: x };
	}
	if (t == 'hysteria') {
		if (xv < 260327)
			ob_dief('hysteria2 нужен Xray-core 26.3.27 или новее, а стоит %s — обновить: byway engine tested', ob_xrayv(2));
		ob_warn('hysteria2 идёт поверх QUIC (UDP), а в РФ его ограничивают первым делом');
		let s = { network: 'hysteria', hysteriaSettings: { version: 2, auth: N.PASS } }, masks = [];
		// Смена портов, как у клиента hysteria2: порт сервера меняется раз в
		// 30 с. udphop сам открывает соединение и обязан стоять ПЕРВЫМ
		// (иначе ядро отвергает конфиг: «incorrect index»). Маска есть в
		// исходниках 26.9.30 (раньше -- quicParams.udpHop, новые ядра его
		// молча игнорируют); старое ядро -- основной порт.
		if (N.HOP) {
			if (xv < 260930)
				ob_warnf('смена портов hysteria2 нужна Xray-core 26.9.30 или новее, а стоит %s — соединение идёт только на порт %s; обновить: byway engine tested', ob_xrayv(2), N.PORT);
			else
				push(masks, { type: 'udphop', settings: { mode: 'intervalRemote', remotePorts: N.HOP } });
		}
		if (N.OBFS != '') {
			if (xv < 260711)
				ob_dief('obfs=salamander у hysteria2 нужен Xray-core 26.7.11 или новее, а стоит %s — обновить: byway engine tested', ob_xrayv(2));
			push(masks, { type: 'salamander', settings: { password: N.OBFSPW } });
		}
		if (length(masks)) s.finalmask = { udp: masks };
		return s;
	}
	// У wireguard транспорта нет; в streamSettings остаётся метка.
	if (t == 'wireguard') return {};
	ob_dief('транспорт %s не поддержан — есть ws, tcp/raw, kcp, grpc, httpupgrade, xhttp, hysteria', t);
}

// streamSettings: защита по N.SEC, поля -- в st.
function ob_security(N, st, sni) {
	let xv = ob_xver();
	if (N.SEC == 'tls') {
		let s = { serverName: sni };
		if (N.FP != '') s.fingerprint = N.FP;
		if (N.ALPN != '') s.alpn = split(N.ALPN, ',');
		// allowInsecure ядро с 26.3.27 отвергает; замена -- отпечаток или имя.
		if (N.INSEC == '1' || N.INSEC == 'true') {
			if (xv < 260327) {
				if (u('allow_insecure') != '1' && N.PIN + N.VCN == '')
					ob_die('в ключе отключена проверка сертификата (allowInsecure): соединение может подменить любой на пути. Для своего сервера с самоподписанным сертификатом: uci set byway.main.allow_insecure=1 && uci commit byway && /etc/init.d/byway reload');
				ob_warn('allowInsecure=1: проверка сертификата сервера отключена, соединение можно подменить');
				s.allowInsecure = true;
			} else if (N.PIN == '' && N.VCN == '') {
				ob_die('в ключе отключена проверка сертификата (allowInsecure или insecure), а Xray-core с 26.3.27 так не умеет: нужен отпечаток сертификата сервера (pcs= или pinSHA256=) либо настоящий сертификат на сервере');
			}
		}
		if (N.PIN != '' || N.VCN != '') {
			if (xv < 260327)
				ob_dief('проверка сертификата по отпечатку (pcs, vcn) нужна Xray-core 26.3.27 или новее, а стоит %s — обновить: byway engine tested', ob_xrayv(2));
			if (N.PIN != '') s.pinnedPeerCertSha256 = N.PIN;
			if (N.VCN != '') s.verifyPeerCertByName = N.VCN;
		}
		st.security = 'tls';
		st.tlsSettings = s;
	} else if (N.SEC == 'reality') {
		let r = { serverName: sni, fingerprint: N.FP, publicKey: N.PBK, shortId: N.SID };
		if (N.SPX != '') r.spiderX = N.SPX;
		if (N.PQV != '') r.mldsa65Verify = N.PQV;
		st.security = 'reality';
		st.realitySettings = r;
	} else if (N.SEC == 'none') {
		// vless и trojan без шифрования к публичному адресу ядро с 26.7.11
		// отвергает само; на старом -- то же решение здесь.
		if ((N.PROTO == 'vless' || N.PROTO == 'trojan') && xv < 260711 &&
		    u('allow_insecure') != '1' && !ob_private(N.HOST))
			ob_die('ключ vless или trojan без TLS к публичному адресу: ключ и трафик видны любому на пути. Нужен ключ с security=tls или reality; разрешить всё же: uci set byway.main.allow_insecure=1 && uci commit byway && /etc/init.d/byway reload');
		st.security = 'none';
	} else {
		ob_dief('security=%s не поддержан', N.SEC);
	}
}

// Протокол и settings.
function ob_outbound(N) {
	let p = N.PROTO, port = int(N.PORT);
	if (p == 'vless') {
		let usr = { id: N.UUID, encryption: N.ENC || 'none' };
		if (N.FLOW != '') usr.flow = N.FLOW;
		return { protocol: 'vless', settings: { vnext: [ { address: N.HOST, port: port, users: [ usr ] } ] } };
	}
	if (p == 'hysteria')
		return { protocol: 'hysteria', settings: { version: 2, address: N.HOST, port: port } };
	if (p == 'wireguard') {
		let peer = { publicKey: N.WGPUB, endpoint: N.HOST + ':' + N.PORT };
		if (N.WGPSK != '') peer.preSharedKey = N.WGPSK;
		if (N.WGKA != '') peer.keepAlive = int(N.WGKA);
		// noKernelTun: wireguard внутри процесса; с 24.11.30 Xray иначе
		// поднимает wg0 через /dev/net/tun (без kmod-tun -- отказ).
		let s = { noKernelTun: true, secretKey: N.WGKEY, address: split(N.WGADDR, ','), peers: [ peer ] };
		if (N.WGMTU != '') s.mtu = int(N.WGMTU);
		// Циклом, не map(…, int): map отдаёт вторым доводом номер, а у int
		// второй довод -- основание счисления.
		if (N.WGRES != '') { s.reserved = []; for (let x in split(N.WGRES, ',')) push(s.reserved, int(x)); }
		return { protocol: 'wireguard', settings: s };
	}
	if (p == 'vmess')
		return { protocol: 'vmess', settings: { vnext: [ { address: N.HOST, port: port,
			users: [ { id: N.UUID, alterId: int(N.AID || '0'), security: N.METHOD || 'auto' } ] } ] } };
	if (p == 'trojan')
		return { protocol: 'trojan', settings: { servers: [ { address: N.HOST, port: port, password: N.PASS } ] } };
	if (p == 'shadowsocks')
		return { protocol: 'shadowsocks', settings: { servers: [ { address: N.HOST, port: port,
			method: N.METHOD, password: N.PASS } ] } };
	if (p == 'socks') {
		let srv = { address: N.HOST, port: port };
		if (N.USER != '') srv.users = [ { user: N.USER, pass: N.PASS } ];
		return { protocol: 'socks', settings: { servers: [ srv ] } };
	}
	ob_dief('протокол %s не собран', p);
}

// Свой конфиг (conn_mode outbound): один объект JSON, тег -- наш.
function ob_raw(tag) {
	let o = null;
	try { o = json(u('outbound_json')); } catch (e) { o = null; }
	if (type(o) != 'object') return null;
	delete o.tag;
	o.tag = tag;
	return o;
}

// Адреса серверов своего конфига: address у settings, vnext, servers,
// endpoint у peers; без [IPv6] и порта, только имя или адрес.
function ob_raw_host(seen, h) {
	if (type(h) != 'string' || substr(h, 0, 1) == '[') return;
	h = replace(h, /:[0-9]+$/, '');
	if (match(h, /^[A-Za-z0-9.-]+$/) && !seen[h]) { seen[h] = 1; push(seen.__list, h); }
}
function ob_raw_hosts(o) {
	let seen = { __list: [] };
	let s = o.settings;
	if (type(s) != 'object') return [];
	ob_raw_host(seen, s.address);
	for (let k in [ 'vnext', 'servers' ])
		if (type(s[k]) == 'array') for (let x in s[k]) if (type(x) == 'object') ob_raw_host(seen, x.address);
	if (type(s.peers) == 'array') for (let x in s.peers) if (type(x) == 'object') ob_raw_host(seen, x.endpoint);
	return seen.__list;
}

// Разбор ключа (parse_key) и блок аутбаунда (как build_stream +
// proxy_block). url пуст -- ключ или свой конфиг из настроек. Итог --
// { N, block, host, raw }; отказ -- исключение OB_STOP.
function ob_key(url, tag, prev_sni, prev_wshost) {
	if (url == '' && u('conn_mode') == 'outbound') {
		let raw = u('outbound_json');
		if (raw == '') ob_die('выбран свой конфиг, но он пуст');
		let o = ob_raw(tag);
		if (o == null) ob_die('свой конфиг — не один JSON-объект аутбаунда: проверить скобки и кавычки');
		let lbl = u('conn_label');
		let N = { PROTO: 'raw', RAW: raw, LABEL: lbl != '' ? lbl : _t('свой конфиг'),
		          TYPE: '-', SEC: '-', HOST: '-', PORT: '0' };
		return { N: N, block: o, raw: true };
	}
	if (url == '') url = u('node_url');
	if (url == '') ob_die('ключ не задан');
	let r = parse_key(url, prev_sni, prev_wshost);
	if (!OB_QUIET_PARSE)
		for (let m in r.msgs) ob_cmd(length(m) > 1 ? 'warnf' : 'warn', m[0], slice(m, 1));
	if (r.fatal) {
		if (length(r.fatal) > 1) ob_dief(...r.fatal); else ob_die(r.fatal[0]);
	}
	let N = r.N;
	// Схему и имя разбор кладёт прямо в вывод для sh, мимо N.
	N.SCHEME = r.scheme;
	N.LABEL = r.label;
	// В ss sni и host не задаются: остаются прежние, как в shell.
	if (N.SNI == null) N.SNI = prev_sni;
	if (N.WSHOST == null) N.WSHOST = prev_wshost;
	if (N.ENC != '' && N.ENC != 'none' && ob_xver() < 250829)
		ob_dief('шифрование VLESS (encryption=mlkem768x25519plus) появилось в Xray-core 25.8.29, а стоит %s — обновить: byway engine tested', ob_xrayv(2));
	if (!match(N.PORT, /^[0-9]+$/) || int(N.PORT) < 1 || int(N.PORT) > 65535)
		ob_dief('порт в ссылке недопустим: %s', N.PORT);

	let st = ob_transport(N);
	ob_security(N, st, N.SNI);
	if (N.FLOW != '' && N.TYPE != 'tcp' && N.TYPE != 'raw')
		ob_warnf('flow=%s с транспортом %s не работает: Xray-core примет конфиг и сломается в бою', N.FLOW, N.TYPE);
	let ob = ob_outbound(N);

	// mux: в поставке 0; с flow, своим мультиплексированием и wireguard -- нет.
	let mux = null;
	let mc = ob_val_or('mux_concurrency', u('mux_concurrency'), /^[0-9]{1,3}$/, '0', _t('конфига движка'));
	if (mc != '' && mc != '0') {
		if (N.FLOW != '')
			ob_warnf('mux отключён: он не сочетается с flow=%s (Vision делит поток сам)', N.FLOW);
		else if (N.TYPE == 'xhttp' || N.TYPE == 'grpc' || N.TYPE == 'hysteria')
			ob_warnf('mux отключён: у транспорта %s своё мультиплексирование, второй слой поверх только вредит', N.TYPE);
		else if (N.PROTO == 'wireguard')
			ob_warn('mux к wireguard не применяется: у него нет потока, который можно делить');
		else
			mux = { enabled: true, concurrency: int(mc) };
	}
	// Метка на исходящих при «VPN для программ на роутере» (число -- из
	// shell, self_mark_dec, до переноса перехвата).
	let sm = getenv('BW_SELFMARK');
	if (u('router_via_vpn') == '1' && sm) st.sockopt = { mark: int(sm) };

	let b = { tag: tag, protocol: ob.protocol, settings: ob.settings };
	if (mux) b.mux = mux;
	b.streamSettings = st;
	return { N: N, block: b, raw: false };
}

// Записи -- печатью здесь же (gen, check, probe): отказ -- [x] и выход, как
// die в shell; soft -- [x] без выхода, итог false (probe --all идёт дальше).
function ob_emit(list, soft) {
	for (let m in list) {
		if (m.c == 'warn' || m.c == 'warnf') { _warn(_pf(_t(m.f), m.a)); continue; }
		if (!soft) die_raw(_pf(_t(m.f), m.a));
		print(_mark(31, '[x]'), _pf(_t(m.f), m.a), '\n');
		return false;
	}
	return true;
}

// Аутбаунды целиком (бывший build_proxies). Обычные режимы -- один с тегом
// proxy; urltest -- по одному на ключ (proxy-N) и балансировщик leastPing.
// Негодный ключ автовыбора пропускается с причиной. skip -- номера ключей,
// которые отверг сам движок (повтор сборки в gen). psni, pws -- sni и host
// прежнего ключа (у ss своих нет). Сообщения -- в OB_OUT, отказ -- OB_STOP.
function ob_proxies(skip, psni, pws) {
	let all = u('list_mode') == 'all';
	let R = { blocks: [], hosts: [], keyidx: [], n: 0, N: null,
	          target: { outboundTag: 'proxy' }, last: null, observatory: null, balancers: null };
	if (u('conn_mode') != 'urltest') {
		let k = ob_key('', 'proxy', psni, pws);
		R.N = k.N;
		push(R.blocks, k.block);
		R.last = all ? R.target : { outboundTag: 'direct' };
		if (k.raw) {
			R.hosts = ob_raw_hosts(k.block);
			if (!length(R.hosts))
				ob_warn('свой конфиг: адрес сервера лежит внутри чужого JSON, byway его не знает и из перехвата не исключит — проверить, что адрес сервера не попал в списки, иначе туннель замкнётся сам на себя');
			if (u('router_via_vpn') == '1' && index(k.N.RAW, '"mark"') < 0)
				ob_warnf('свой конфиг: включено «VPN для программ на роутере», а метки в нём нет — если адрес сервера попадёт в списки, соединение движка к нему уйдёт в перехват по кругу; дописать в streamSettings поле sockopt.mark = %s', getenv('BW_SELFMARK') ?? '');
		} else {
			R.hosts = [ k.N.HOST ];
		}
		return R;
	}
	let keys = split(trim(u('node_urls')), /[ \t\n]+/);
	if (keys[0] == '') ob_die('выбран автовыбор, но ни одного ключа не добавлено');
	skip = ' ' + (skip ?? '') + ' ';
	for (let ki = 0; ki < length(keys); ki++) {
		if (index(skip, ' ' + ki + ' ') >= 0) continue;
		// Тихий прогон: сообщения ключа -- только если он годен.
		let saved = OB_OUT;
		OB_OUT = [];
		OB_FATAL = null;
		let k = null;
		try {
			k = ob_key(keys[ki], 'proxy-' + R.n, psni, pws);
		} catch (e) {
			if (e.message !== OB_STOP) raise(e.message);
		}
		let msgs = OB_OUT;
		OB_OUT = saved;
		if (k == null) {
			ob_warnf('ключ пропущен: %s', OB_FATAL ?? '');
			continue;
		}
		for (let m in msgs) push(OB_OUT, m);
		psni = k.N.SNI; pws = k.N.WSHOST;
		push(R.blocks, k.block);
		push(R.keyidx, ki);
		push(R.hosts, k.N.HOST);
		R.N = k.N;
		R.n++;
	}
	if (!R.n) ob_die('ни один ключ не разобрался');
	let iv = ob_val_or('probe_interval', u('probe_interval'), /^[0-9]{1,4}[smh]$/, '3m', _t('конфига движка'));
	R.observatory = { subjectSelector: [ 'proxy-' ], probeUrl: 'https://www.google.com/generate_204', probeInterval: iv };
	R.balancers = [ { tag: 'auto', selector: [ 'proxy-' ], strategy: { type: 'leastPing' } } ];
	R.target = { balancerTag: 'auto' };
	R.last = all ? R.target : { outboundTag: 'direct' };
	R.N.LABEL = _f('автовыбор из %s', R.n);
	return R;
}
