// Состояние для человека и панели (бывшие service/status.sh и cmd_health):
// status -- что поднято, health -- служба, VPN, трафик, DNS строками
// «ключ<таб>состояние<таб>подробность». Пути и номера от shell -- в BW_*.

const ST_TABLE = 'byway';
const ST_RT = '100';
const ST_BLOCK = '/tmp/byway-blocked';

// ── общее ─────────────────────────────────────────────────────────────────
// Действующий пул без жалоб (eff_pool в config/addr.sh): негодная настройка --
// умолчание, как у правил nft.
function st_pool() {
	let p = u('fakeip_pool');
	if (p === '' || match(p, /[\x01-\x1f\x7f]/) || !match(p, /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/))
		return '198.18.0.0/15';
	return g_pool_ok(p) ? p : '198.18.0.0/15';
}

// Адрес IPv4 в пуле a.b.c.d/len (вместо образца fakeip_re).
function st_ip_num(a) {
	let o = split(a, '.');
	if (length(o) != 4) return null;
	let n = 0;
	for (let x in o) {
		if (x === '' || ltrim(x, '0123456789') !== '' || length(x) > 3 || int(x) > 255) return null;
		n = n * 256 + int(x);
	}
	return n;
}
function st_in_pool(a, pool) {
	let s = index(pool, '/');
	let n = st_ip_num(a), b = st_ip_num(substr(pool, 0, s)), l = int(substr(pool, s + 1));
	if (n == null || b == null) return false;
	let span = 1 << (32 - l);
	return int(n / span) == int(b / span);
}

// Метка обвязки так, как её печатает ip rule (eff_mark).
function st_mark() {
	let m = u('mark');
	if (!match(m, /^0x[0-9a-fA-F]{1,8}$/)) m = '0x100000';
	return sprintf('0x%x', hex(substr(m, 2)));
}

// pid движка по pid-файлу procd; через ujail -- потомок обёртки. /proc
// подтверждает, что это наш Xray с нашим конфигом (xray_pid в core/util.sh).
function st_xray_pid() {
	let out = getenv('BW_OUT');
	let p = trim(fs.readfile('/var/run/byway.pid') ?? '');
	if (p !== '' && fs.readlink('/proc/' + p + '/exe') == '/sbin/ujail')
		p = split(trim(run([ 'pgrep', '-P', p ]).out), '\n')[0] ?? '';
	if (p !== '' && index(join(' ', split(fs.readfile('/proc/' + p + '/cmdline') ?? '', '\0')), 'run -c ' + out) >= 0)
		return p;
	// Запасной путь: движок запущен руками, мимо службы.
	for (let l in split(run([ 'ps', 'w' ]).out, '\n'))
		if (index(l, 'run -c ' + out) >= 0 && index(l, 'grep') < 0)
			return split(trim(l), /[ \t]+/)[0];
	return '';
}

// Возраст процесса в секундах: starttime из /proc/PID/stat против uptime.
function st_age(p) {
	let up = split(fs.readfile('/proc/uptime') ?? '', ' ')[0];
	let st = fs.readfile('/proc/' + p + '/stat') ?? '';
	let i = rindex(st, ') ');
	if (!up || i < 0) return 999999;
	return int(up) - int(int(split(substr(st, i + 2), ' ')[19]) / 100);
}

// Первый домен списка, который можно спросить у резолвера (plain_domains).
function st_plain_first(file) {
	let f = fs.open(file, 'r'), l;
	if (!f) return '';
	while ((l = f.read('line')) != null && l !== '') {
		l = lj_plain(l);
		if (l != null) { f.close(); return l; }
	}
	f.close();
	return '';
}

// Ответы nslookup у резолвера 127.0.0.1: последнее поле строк Address.
function st_resolve(d) {
	let r = [];
	for (let l in split(run([ 'nslookup', d, '127.0.0.1' ]).out, '\n'))
		if (substr(l, 0, 7) == 'Address') {
			let f = split(trim(l), /[ \t]+/);
			push(r, f[length(f) - 1]);
		}
	return r;
}

function st_fake_of(d, pool) {
	for (let a in st_resolve(d)) if (st_in_pool(a, pool)) return a;
	return '';
}

// Сравнение версий вида 1.2.3 (ver_gt).
function st_ver_gt(a, b) {
	let x = split(replace(a, /[^0-9]+/g, ' '), ' '), y = split(replace(b, /[^0-9]+/g, ' '), ' ');
	for (let i = 0; i < 3; i++) {
		let p = int(x[i] || '0'), q = int(y[i] || '0');
		if (p != q) return p > q;
	}
	return false;
}

// Ядро на Go 1.27 без -tags http2legacy и с x/net старше v0.60.0: XHTTP
// открывает соединение на каждый ждущий запрос (Xray#6797). Кэш -- тот же
// /tmp/byway-dialbug, что у eng_dial_bug в update/engine.sh.
function st_dial_bug(x) {
	let k = rtrim(run([ 'ls', '-lni', x ]).out, '\n');
	let c = split(fs.readfile('/tmp/byway-dialbug') ?? '', '\n');
	if (k !== '' && c[0] == k) return c[1] == '1';
	let v = split(run([ x, 'version' ]).out, '\n')[0];
	let bug = false;
	if (index(v, 'http2legacy') < 0 &&
	    (index(v, '(go1.27.') >= 0 || index(v, '(go1.27 ') >= 0 || index(v, '(go1.27)') >= 0))
		bug = run([ 'grep', '-q', 'http2legacy', x ]).code != 0 &&
		      run([ 'grep', '-qE', 'golang\\.org/x/net.v(0\\.([6-9][0-9]|[1-9][0-9][0-9])|[1-9][0-9]*)\\.', x ]).code != 0;
	fs.writefile('/tmp/byway-dialbug', k + '\n' + (bug ? '1' : '0') + '\n');
	return bug;
}

// ── status ────────────────────────────────────────────────────────────────
// Строки ВНИМАНИЕ панель не читает: они консольные. --short: вкладки читают
// только голову; остальное (ядро, ps, nft, nslookup) -- дорогое.
function cmd_status(arg) {
	let out = getenv('BW_OUT'), cst = fs.stat(out);
	print('byway       ', getenv('BW_VERSION'), '\n');
	print(_f('конфиг      %s\n', cst ? _f('%s байт', cst.size) : _t('НЕТ')));
	// Транспорт, режим, ключи -- одним grep по конфигу: в нём списки на
	// сотни тысяч строк, и разбор строками в ucode дольше.
	let tags = 0, nproxy = 0, net = '', sec = '', mux = '', xh = false;
	if (cst) {
		for (let m in split(run([ 'grep', '-oE',
		    '"tag": "proxy[^"]*"|"network": "[a-z0-9]*"|"security": "[a-z]*"|"concurrency": [0-9]*', out ]).out, '\n')) {
			if (substr(m, 0, 13) == '"tag": "proxy') { nproxy++; if (substr(m, 13, 1) == '-') tags++; }
			else if (substr(m, 0, 10) == '"network":') { net = substr(m, 12, length(m) - 13); if (net == 'xhttp') xh = true; }
			else if (substr(m, 0, 11) == '"security":') sec = substr(m, 13, length(m) - 14);
			else if (substr(m, 0, 14) == '"concurrency":' && mux === '') mux = trim(substr(m, 14));
		}
	}
	let mode = u('conn_mode');
	if (mode == 'urltest' && cst) {
		print(_f('подключение автовыбор из %s ключей\n', tags));
		// Активный ключ виден только по журналу обращений; цифра обязательна:
		// иначе ловится «proxy-» из «tproxy-in».
		let act = '';
		for (let m in match(run([ 'tail', '-200', getenv('BW_ACCESS') ]).out, /proxy-[0-9]+/g) ?? []) act = m[0];
		if (act !== '') print(_f('сейчас      %s\n', act));
	} else if (cst) {
		print(_f('транспорт   %s / %s%s\n', net || '?', sec || '?', mux !== '' ? ', mux=' + mux : ''));
		// Метка -- из ссылки: в конфиг Xray её не пишет. Строка -- всегда, когда
		// ключ задан: панель судит по её наличию.
		let url = u('node_url');
		if (url !== '') {
			let h = index(url, '#');
			let lb = h < 0 ? '' : pk_pctd(substr(url, h + 1));
			print(_f('ключ        %s\n', lb || _t('без имени')));
		} else if (mode == 'outbound') {
			print(_f('ключ        %s\n', u('conn_label') || _t('свой конфиг')));
		}
	}
	// Режим меняют через uci без пересборки: остаток автовыбора рвал соединения.
	if (cst && ((mode == 'urltest') != (nproxy > 1)))
		print(_t('ВНИМАНИЕ    конфиг собран для другого режима, применить: /etc/init.d/byway reload\n'));
	// Запрет виден только по файлу: health при нём зелёный.
	if (fs.stat(ST_BLOCK)) {
		let b = trim(fs.readfile(ST_BLOCK) ?? '');
		if (b == 'all')
			print(_t('ВНИМАНИЕ    трафик перечисленных сетей мимо VPN ЗАКРЫТ: туннеля нет, так велит «не пускать мимо VPN»\n'));
		else if (b == 'none')
			print(_t('ВНИМАНИЕ    «не пускать мимо VPN» включено, но закрывать было нечего — трафик идёт НАПРЯМУЮ\n'));
		else
			print(_t('ВНИМАНИЕ    доступ к списку ЗАКРЫТ: туннеля нет, так велит «не пускать мимо VPN»\n'));
	}
	if (arg == '--short') return;

	let x = getenv('BW_XRAY');
	let vf = split(split(run([ x, 'version' ]).out, '\n')[0], ' ');
	print(_f('движок      %s\n', join(' ', slice(vf, 0, 2)) + ' — ' + x));
	if (xh && st_dial_bug(x))
		print(_t('xmux        не ограничивает соединения: ядро собрано на Go 1.27, см. byway doctor\n'));
	// Процесс -- по пути к конфигу, не по имени бинарника.
	let p = st_xray_pid();
	print(p !== '' ? _f('xray        PID %s\n', p) : _t('xray        не запущен\n'));
	// Предел -- из окружения процесса: видно применённое, а не записанное.
	if (p !== '') {
		let rss = match(fs.readfile('/proc/' + p + '/status') ?? '', /\nVmRSS:[ \t]*([0-9]+)/);
		// environ -- строки через \0: регулярка на \0 обрывается, делим сами.
		let lim = null;
		for (let e in split(fs.readfile('/proc/' + p + '/environ') ?? '', '\0'))
			if (substr(e, 0, 11) == 'GOMEMLIMIT=') lim = substr(e, 11);
		print(_f('память      %s МБ, предел %s\n', rss ? int(int(rss[1]) / 1024) : '?', lim || _t('не задан')));
	}
	let nr = 0, all = cursor().get_all('byway') ?? {};
	for (let n in all) if (all[n]['.type'] == 'route' && all[n].enabled != '0') nr++;
	if (nr > 0) print(_f('направления %s со своим выходом\n', nr));

	// Три опоры перехвата: таблица (точное имя: «inet byway_block» -- другая),
	// правило, маршрут. Правило без маршрута уводит пакет настоящим адресом.
	let nt = run([ 'nft', 'list', 'table', 'inet', ST_TABLE ]);
	print(_f('таблица nft %s\n', nt.code == 0 ? _t('есть') : _t('НЕТ')));
	let mk = st_mark(), rule = false;
	for (let l in split(run([ 'ip', 'rule', 'show' ]).out, '\n'))
		if (match(l, regexp('fwmark ' + mk + '(/' + mk + ')?[ \t]+lookup ' + ST_RT + '([ \t]|$)'))) rule = true;
	print(_f('ip rule     %s\n', rule ? _t('есть') : _t('НЕТ')));
	let route = false;
	for (let l in split(run([ 'ip', 'route', 'show', 'table', ST_RT ]).out, '\n'))
		if (substr(l, 0, 13) == 'local default') route = true;
	print(_f('маршрут     %s\n', route ? _t('есть') : _t('НЕТ')));
	let srv = rtrim(run([ 'uci', '-q', 'get', 'dhcp.@dnsmasq[0].server' ]).out, '\n');
	print(_f('dnsmasq ->  %s\n', srv !== '' ? srv : _t('провайдер')));
	if (p !== '') {
		// Домен -- из своего списка: чужой тестовый давал «не выдаётся».
		let d = st_plain_first(getenv('BW_MERGED') ?? '');
		if (d !== '') {
			let a = st_fake_of(d, st_pool());
			print(a !== '' ? _f('fakeip      %s -> %s\n', d, a) : _f('fakeip      НЕ выдаётся на %s\n', d));
		}
		// Только правила tproxy: счётчики QUIC и закрытого порта считали бы
		// тот же пакет второй раз.
		let c = 0;
		for (let l in split(nt.out, '\n'))
			if (index(l, 'tproxy') >= 0)
				for (let m in match(l, /packets ([0-9]+)/g) ?? []) c += int(m[1]);
		print(_f('в tproxy    %s пакетов\n', c));
	}
	// Новая версия -- после состояния: канала извещений нет.
	let au = fs.readfile(getenv('BW_AULOG')) ?? '';
	if (au !== '') print(_f('ночью      %s\n', rtrim(au, '\n')));
	let nv = trim(fs.readfile(getenv('BW_NEWVER')) ?? ''), num = getenv('BW_NUM');
	if (nv !== '' && st_ver_gt(nv, num)) {
		print(_f('обновление  %s доступно (у вас %s)\n', nv, num));
		let rn = rtrim(fs.readfile(getenv('BW_RELNOTE')) ?? '', '\n');
		if (rn !== '') print('            ', rn, '\n');
		print(_t('            поставить: byway update\n'));
	}
}

// ── health ────────────────────────────────────────────────────────────────
let HL_YOUNG = false;

// Неудача при только что запущенной службе -- warn, не fail.
function hl_fail(k, m) {
	if (HL_YOUNG) print(k, '\twarn\t', _t('ещё запускается'), '\n');
	else print(k, '\tfail\t', m, '\n');
}

// Ключ для замера: { N } или null (не разобран). Свой конфиг -- N.PROTO raw.
function hl_key(url) {
	if (url === '' && u('conn_mode') == 'outbound') {
		if (u('outbound_json') === '' || ob_raw('proxy') == null) return null;
		return { PROTO: 'raw' };
	}
	if (url === '') url = u('node_url');
	if (url === '') return null;
	let r = parse_key(url, '', '');
	if (r.fatal) return null;
	let N = r.N;
	// Версию ядра -- только для шифрования VLESS: запуск xray дорог.
	if (N.ENC != '' && N.ENC != 'none') {
		let v = split(split(split(run([ getenv('BW_XRAY'), 'version' ]).out, '\n')[0], ' ')[1] ?? '', '.');
		if (length(v) == 3 && int(v[0]) * 10000 + int(v[1]) * 100 + int(v[2]) < 250829) return null;
	}
	if (!g_port_ok(N.PORT)) return null;
	return N;
}

// Сервер слушает UDP: замер TCP-соединением к нему не годится.
function hl_udp(N) { return N.PROTO == 'hysteria' || N.PROTO == 'wireguard' || N.TYPE == 'kcp'; }

// Секунды от curl (time_connect) в мс; 0 -- соединения не было. Быстрее
// миллисекунды -- 1, а не 0: сервер в локальной сети иначе «не отвечал».
function hl_ms(v) {
	let t = +(trim(v) || '0');
	return t > 0 ? (int(t * 1000) || 1) : 0;
}

// Время TCP-соединения в мс; 0 -- не ответил. --max-time обязателен:
// рукопожатие проходит, HTTP-ответа нет, и curl висел бы.
function hl_connect_ms(h, p) {
	let r = run([ 'curl', '-s', '-o', '/dev/null', '--connect-timeout', '3', '--max-time', '4',
	              '-w', '%{time_connect}', 'http://' + h + ':' + p ]);
	return hl_ms(r.out);
}

// vpn при автовыборе: все ключи разом, в фоне (по очереди десяток не уложился
// бы в 20 с панели).
function hl_urltest() {
	let keys = split(trim(u('node_urls')), /[ \t\n]+/);
	if (keys[0] == '') keys = [];
	let hn = length(keys), hu = 0, targets = [];
	for (let k in keys) {
		let N = hl_key(k);
		if (N == null || N.PROTO == 'raw') continue;
		// UDP-ключ в замер не входит и в «N из M» не считается.
		if (hl_udp(N)) { hu++; hn--; continue; }
		push(targets, N.HOST + ':' + N.PORT);
	}
	let ok = 0, best = 0;
	if (length(targets)) {
		let o = run([ 'sh', '-c', 'for hp; do curl -s -o /dev/null --connect-timeout 3 --max-time 4 -w "%{time_connect}\\n" "http://$hp" 2>/dev/null & done; wait', 'sh', ...targets ]);
		for (let l in split(o.out, '\n')) {
			let ms = hl_ms(l);
			if (ms <= 0) continue;
			ok++;
			if (best == 0 || ms < best) best = ms;
		}
	}
	if (ok == 0 && hu > 0 && hn == 0)
		print(_t('vpn\twarn\tсерверы на UDP: задержка не меряется\n'));
	else if (ok == 0)
		hl_fail('vpn', _t('не отвечает ни один ключ'));
	else if (ok == hn)
		print(_f('vpn\tok\tотвечают %s из %s ключей, лучший — %s мс\n', ok, hn, best));
	else
		print(_f('vpn\twarn\tотвечают %s из %s ключей, лучший — %s мс\n', ok, hn, best));
}

// Формат «ключ<таб>состояние<таб>подробность», состояния ok/warn/fail: панель
// красит, не разбирая текст.
function cmd_health() {
	let lp = u('local_proxy_port') || '1603';
	let probe = getenv('BW_PROBE');
	// 1. Служба. Молодой процесс -- warn: Xray поднимается ~15 с. Отличает
	// слепок applied (service_started пишет его раз за запуск): процесс молод,
	// слепок стар -- круг падений, это отказ.
	let p = st_xray_pid();
	if (p === '') {
		print(_t('service\tfail\tне запущена\n'));
		print(_t('vpn\tfail\tпроверять нечем\n'));
		print(_t('tunnel\tfail\tпроверять нечем\n'));
		print(_t('dns\tfail\tпроверять нечем\n'));
		return;
	}
	let ap = fs.stat('/var/run/byway.applied');
	HL_YOUNG = st_age(p) < 25 && ap != null && ap.mtime >= time() - 60;
	print(HL_YOUNG ? _t('service\twarn\tзапускается\n') : _t('service\tok\tработает\n'));

	// 2. Доступность VPN: время TCP-соединения до ноды (ICMP может быть закрыт).
	if (u('conn_mode') == 'urltest') {
		hl_urltest();
	} else {
		let N = hl_key('');
		if (N == null) {
			print(_t('vpn\tfail\tссылка не разобрана\n'));
			print(_t('tunnel\tfail\tпроверять нечем\n'));
			print(_t('dns\tfail\tпроверять нечем\n'));
			return;
		}
		if (N.PROTO == 'raw') {
			// Свой конфиг: адреса ноды у byway нет.
			print(_t('vpn\twarn\tсвой конфиг: адрес сервера неизвестен\n'));
		} else if (hl_udp(N)) {
			// TCP-замер к UDP-серверу всегда «не отвечает»; работу туннеля
			// показывает шаг tunnel.
			print(_t('vpn\twarn\tсервер на UDP: задержка не меряется\n'));
		} else {
			// Две попытки: одиночный замер изредка не укладывается в таймаут.
			let ms = hl_connect_ms(N.HOST, N.PORT);
			if (ms <= 0) { system([ 'sleep', '1' ]); ms = hl_connect_ms(N.HOST, N.PORT); }
			if (ms <= 0) hl_fail('vpn', _t('не отвечает'));
			else if (ms < 400) print(_f('vpn\tok\t%s мс\n', ms));
			else print(_f('vpn\twarn\t%s мс, медленно\n', ms));
		}
	}

	// 3. Трафик насквозь: через прокси-вход на домен-пробу, который byway
	// заворачивает всегда. Потолок 5 с: шаги 2-4 укладываются в 20 с панели.
	let c = trim(run([ 'curl', '-s', '-o', '/dev/null', '--max-time', '5', '-w', '%{http_code}',
	                   '--proxy', 'http://127.0.0.1:' + lp, 'https://' + probe + '/' ]).out);
	if ((c || '000') == '000') hl_fail('tunnel', _t('трафик не проходит'));
	else print(_t('tunnel\tok\tтрафик проходит\n'));

	// 4. Резолвер: домен-проба обязан получить fakeip. Две попытки: кэш
	// dnsmasq выключен, каждый резолв идёт полным путём.
	let pool = st_pool(), a = '';
	for (let i = 0; i < 2 && a === ''; i++) {
		if (i) system([ 'sleep', '1' ]);
		for (let l in split(run([ 'nslookup', probe, '127.0.0.1' ]).out, '\n'))
			if (substr(l, 0, 8) == 'Address:') {
				let v = ltrim(substr(l, 8), ' ');
				if (st_in_pool(v, pool)) { a = v; break; }
			}
	}
	if (a !== '') print(_t('dns\tok\tотвечает\n'));
	else hl_fail('dns', _t('не выдаёт адрес'));
}

// bw_uc rawok: свой конфиг -- один JSON-объект аутбаунда (для parse_node).
function cmd_rawok() { exit(ob_raw('proxy') == null ? 1 : 0); }
