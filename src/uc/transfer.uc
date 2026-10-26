// Перенос настроек (бывший data/transfer.sh): тело выгрузки, приём выгрузки в
// UCI и списки, очистка накопленного. Путь к файлу проверяет shell (path_ok),
// сборку, перезапуск и откат -- тоже он (data/transfer.sh).
//
// Формат -- один текстовый файл, читаемый глазами и вставляемый в переписку.
// Список опций явный, а не «всё из секции»: чужой файл не должен задавать
// роутеру произвольную опцию. xray_bin не переносится: путь к программе,
// которую byway запускает, из чужого файла брать незачем.
const TF_KEYS = [ 'enabled', 'conn_mode', 'node_url', 'sub_url', 'outbound_json', 'conn_label',
	'list_mode', 'ru_direct', 'preset', 'interface', 'fakeip_pool', 'dns_upstream',
	'dns_upstream2', 'dns_bootstrap', 'dns_listen', 'tproxy_port', 'local_proxy_port',
	'router_via_vpn', 'mark', 'self_mark', 'log_level', 'ipv6', 'fakeip6_pool',
	'show_usage', 'mux_concurrency', 'probe_interval', 'guard', 'block_quic', 'allow_insecure',
	'lists_update', 'dns_route', 'on_failure', 'node_urls', 'lang', 'update_check',
	'auto_update', 'auto_update_hour' ];
// Опции с ключом: ими различаются «поделиться настройкой» и «отдать доступ».
// Адрес DNS и имя подключения -- тоже: в адресе DoH бывает личный
// идентификатор, а выгрузку «без ключа» обещано можно показывать (Ф9, п1-9).
const TF_SECRET = [ 'node_url', 'node_urls', 'sub_url', 'outbound_json', 'conn_label',
	'dns_upstream', 'dns_upstream2', 'dns_bootstrap' ];
// Списочные опции UCI: вводятся по словам, иначе одна строка с пробелами.
const TF_LIST = [ 'preset', 'interface', 'node_urls' ];
// Снятые настройки прежних версий: выгрузка 0.3 их несёт, это не ошибка.
const TF_GONE = [ 'redirect_port' ];

function tf_has(a, k) { return index(a, k) >= 0; }

// Строки текста, как их видят grep и awk: последний перевод строки -- конец
// строки, а не пустая строка после него.
function tf_lines(t) {
	if (t == null || t === '') return [];
	if (substr(t, -1) == '\n') t = substr(t, 0, length(t) - 1);
	return split(t, '\n');
}

function tf_routes() {
	let all = cursor().get_all('byway') ?? {}, r = [];
	for (let n in all) if (all[n]['.type'] == 'route') push(r, all[n]);
	return sort(r, (a, b) => a['.index'] - b['.index']);
}

// Строки файла без начинающихся со скобки: их не отличить от заголовка.
function tf_list_body(file) {
	for (let l in tf_lines(fs.readfile(file)))
		if (substr(l, 0, 1) != '[') print(l, '\n');
}

// bw_uc export 0|1: тело выгрузки (1 -- без ключа).
function cmd_export(nokey) {
	nokey = nokey == '1';
	print('# byway export 1\n');
	print(_f('# программа: byway %s\n', getenv('BW_VERSION')));
	let host = rtrim(run([ 'uci', '-q', 'get', 'system.@system[0].hostname' ]).out, '\n');
	print(_f('# снято: %s с %s\n', trim(run([ 'date', '+%Y-%m-%d %H:%M' ]).out), host !== '' ? host : _t('роутера')));
	if (nokey) print(_t('# БЕЗ КЛЮЧА: подключение к VPN придётся вписать заново'), '\n');
	print('\n[settings]\n');
	for (let k in TF_KEYS) {
		if (nokey && tf_has(TF_SECRET, k)) continue;
		// Список -- по элементам: пробел внутри ключа (метка «#Node 2 EU»)
		// кодируется, иначе приём резал бы ключ на слова (Ф9, п3-34).
		let v = tf_has(TF_LIST, k) ? join(' ', map(ul(k), (x) => replace(x, ' ', '%20'))) : u(k);
		if (v === '') continue;
		// Перевод строки рвёт формат (свой конфиг вставляют многострочным).
		print(k, '=', replace(v, /[\n\r]/g, ' '), '\n');
	}
	// Пустой строки перед заголовком нет намеренно: она попала бы в конец
	// предыдущего списка, и приём менял бы разбивку файла.
	let lists = getenv('BW_LISTS');
	print('[domains]\n');
	tf_list_body(lists + '/domains.lst');
	print('[subnets]\n');
	tf_list_body(lists + '/subnets.lst');
	// Направления -- своими разделами: без них трафик, разложенный по нодам,
	// шёл бы весь в основную.
	for (let s in tf_routes()) {
		let n = s['.name'];
		print('[route:', n, ']\n');
		print('label=', s.label ?? '', '\n');
		print('enabled=', s.enabled ?? '1', '\n');
		print('[routelist:', n, ']\n');
		tf_list_body(getenv('BW_ROUTES') + '/' + n + '.lst');
	}
}

// Копия до правки: конфиг (с ключом -- 600 в каталоге 700) и списки. Ради
// отката ПОСЛЕ удачного приёма; следующий приём перезапишет.
// Каждая копия сверяется: обрезанная нехваткой места при откате вставала бы
// на место «прежнего» (Ф9, п2-4). Ложь -- копии нет, приём не начинать.
function tf_backup(bak) {
	let lists = getenv('BW_LISTS'), routes = getenv('BW_ROUTES');
	fs.mkdir(bak, 0700);
	fs.chmod(bak, 0700);
	fs.unlink(bak + '/config');
	let c = fs.readfile(getenv('BW_CONF'));
	// Каталог 700: файл с ключом до chmod никому не виден.
	if (c != null && !put_file(bak + '/config', c, 0600)) return false;
	// Ключи -- своим файлом рядом (Ф9, п1-12); нет его -- и копии нет.
	fs.unlink(bak + '/config_key');
	let ck = fs.readfile('/etc/config/' + KEY_PKG);
	if (ck != null && !put_file(bak + '/config_key', ck, 0600)) return false;
	for (let l in [ 'domains.lst', 'subnets.lst' ]) {
		let t = fs.readfile(lists + '/' + l);
		if (t != null && !put_file(bak + '/' + l, t)) return false;
	}
	// Списки направлений -- каждый раз заново: копия прошлого приёма вернула
	// бы при отказе чужие списки.
	run([ 'rm', '-rf', bak + '/routes' ]);
	fs.mkdir(bak + '/routes', 0700);
	fs.chmod(bak + '/routes', 0700);
	for (let f in fs.lsdir(routes) ?? [])
		if (substr(f, -4) == '.lst' && fs.stat(routes + '/' + f)?.type == 'file' &&
		    !put_file(bak + '/routes/' + f, fs.readfile(routes + '/' + f) ?? ''))
			return false;
	return true;
}

// Имя направления из заголовка; негодное -- null (станет именем секции и файла).
function tf_name(h) {
	let n = substr(h, index(h, ':') + 1);
	n = substr(n, 0, length(n) - 1);
	return (n !== '' && ltrim(n, ALNUM + '_-') === '') ? n : null;
}

// Разбор выгрузки по разделам: settings, domains, subnets, route.N,
// routelist.N -- массивы строк; routes -- имена по порядку. Раздел есть, только
// если в нём была строка. Неизвестный раздел -- НЕ дописывать в предыдущий.
function tf_parse(text) {
	let S = { routes: [] }, cur = null;
	for (let l in tf_lines(text)) {
		if (match(l, /^\[.*\]$/)) {
			cur = null;
			if (l == '[settings]' || l == '[domains]' || l == '[subnets]') cur = substr(l, 1, length(l) - 2);
			else if (substr(l, 0, 7) == '[route:') {
				let n = tf_name(l);
				if (n != null) { push(S.routes, n); cur = 'route.' + n; }
			} else if (substr(l, 0, 11) == '[routelist:') {
				let n = tf_name(l);
				if (n != null) cur = 'routelist.' + n;
			}
			continue;
		}
		if (substr(l, 0, 1) == '#' || cur == null) continue;
		S[cur] ??= [];
		push(S[cur], l);
	}
	return S;
}

// Строки -> текст файла; последняя пустая (из одних пробелов) снимается:
// пустые внутри -- ручная разбивка на секции.
function tf_text(lines) {
	let a = [ ...lines ];
	if (length(a) && trim(a[length(a) - 1], WS) === '') pop(a);
	return length(a) ? join('\n', a) + '\n' : '';
}

// bw_uc import ФАЙЛ 0|1: выгрузка -> UCI (save без commit) и списки (1 -- ключ
// не трогать). Сборку и перезапуск делает shell; откат -- uci revert и копия.
// Значения, которые перехват и сборка молча заменили бы умолчанием, а doctor
// читал бы как есть (метка 2097152, порт 0): мерка -- как у byway set
// (Ф9, прогон 5). Пустое -- «по умолчанию», годно.
function tf_val_ok(k, v) {
	if (v === '') return true;
	if (k == 'mark') return match(v, /^0x[0-9a-fA-F]{1,8}$/) != null && hex(substr(v, 2)) != 0;
	if (k == 'tproxy_port' || k == 'local_proxy_port') return g_port_ok(v);
	if (k == 'dns_listen') return match(v, /^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/) != null && v != '127.0.0.1';
	if (k == 'fakeip_pool') return g_pool_sane(v, true);
	return true;
}

function cmd_import(src, nokey) {
	nokey = nokey == '1';
	let text = fs.readfile(src);
	if (text == null) dief('не читается: %s', src);
	if (substr(text, 0, 14) != '# byway export') die('это не выгрузка byway: в первой строке нет заголовка');
	let lists = getenv('BW_LISTS'), routes = getenv('BW_ROUTES');
	if (!tf_backup(lists + '/before-import')) die('на флеше нет места на копию для отката — настройки из файла не приняты, прежние на месте');
	// Выгрузка с ключом разбирается в памяти, не во временный каталог.
	let S = tf_parse(text);
	// Файлы списков -- сперва все во временные рядом, потом разом на место:
	// обрезанный нехваткой места не встаёт вместо рабочего (Ф9, п2-4).
	let c = cursor(), n = 0, skip = '', W = [], kready = false;
	for (let l in S.settings ?? []) {
		if (l === '') continue;
		let e = index(l, '=');
		if (e < 0) continue;
		let k = substr(l, 0, e), v = substr(l, e + 1);
		if (tf_has(TF_GONE, k)) continue;
		if (!tf_has(TF_KEYS, k)) { skip += ' ' + k; continue; }
		// «Оставить нынешний ключ» -- и способ подключения нынешний: режим из
		// файла при прежних ключах давал, например, автовыбор без списка
		// ключей (Ф9, п3-35).
		if (nokey && (tf_has(TF_SECRET, k) || k == 'conn_mode')) continue;
		if (!tf_val_ok(k, v)) { warnf('значение «%s» для %s не годится — пропущено', v, k); continue; }
		// Ключи -- в свой пакет (Ф9, п1-12).
		let pk = opt_pkg(k);
		if (pk == KEY_PKG && !kready) {
			if (!key_ensure()) die('на флеше нет места: настройки из файла не приняты, прежние на месте');
			c = cursor();
			kready = true;
		}
		if (tf_has(TF_LIST, k)) {
			c.delete(pk, 'main', k);
			let w = split(trim(v), /[ \t]+/);
			if (w[0] !== '') c.set(pk, 'main', k, w);
		} else if (v === '') {
			c.delete(pk, 'main', k);
		} else {
			c.set(pk, 'main', k, v);
		}
		n++;
	}
	if (skip !== '') warnf('настройки неизвестны и пропущены:%s', skip);
	// Пустой раздел (ни строки) -- «про список речи не было».
	for (let l in [ 'domains', 'subnets' ])
		if (S[l] != null) push(W, [ lists + '/' + l + '.lst', tf_text(S[l]) ]);
	// Направления заменяются целиком; нет раздела -- прежние на месте.
	if (length(S.routes)) {
		for (let s in tf_routes()) {
			let o = s['.name'], t = fs.readfile(routes + '/' + o + '.lst');
			if (t != null) put_file(lists + '/before-import/routes/' + o + '.lst', t);
			c.delete('byway', o);
		}
		if (!fs.stat(routes)) fs.mkdir(routes, 0755);
		for (let rn in S.routes) {
			// Имя занято секцией другого типа (main и прочие): присвоение
			// сменило бы её тип.
			let ty = c.get('byway', rn);
			if (ty != null && ty != 'route') {
				warnf('направление «%s» пропущено: имя занято настройкой byway', rn);
				continue;
			}
			c.set('byway', rn, 'route');
			for (let l in S['route.' + rn] ?? []) {
				if (substr(l, 0, 6) == 'label=') c.set('byway', rn, 'label', substr(l, 6));
				else if (substr(l, 0, 8) == 'enabled=') c.set('byway', rn, 'enabled', substr(l, 8));
			}
			push(W, [ routes + '/' + rn + '.lst', S['routelist.' + rn] != null ? tf_text(S['routelist.' + rn]) : '' ]);
			n++;
		}
	}
	for (let w in W)
		if (fs.writefile(w[0] + '.new', w[1]) !== length(w[1])) {
			for (let x in W) fs.unlink(x[0] + '.new');
			die('на флеше нет места: настройки из файла не приняты, прежние на месте');
		}
	for (let w in W) fs.rename(w[0] + '.new', w[0]);
	// save() без довода: save('byway') на ucode 22.03 отвечает «Invalid argument».
	if (!c.save()) dief('настройки не записаны в UCI: %s', c.error() ?? '?');
	sayf('принято настроек: %s', n);
	if (nokey) {
		say('ключ оставлен прежний');
		// Ключ в файле есть, но не взят: иначе отказ вылезет позже строкой
		// «конфиг не собрался».
		if (match(text, /(^|\n)node_url=../))
			warn('в выгрузке ключ ЕСТЬ, но принят не был -- так велит --no-key (в панели это галочка «Оставить нынешний ключ»)');
	}
}

// bw_uc clear log|stat|all: обнулить накопленное. Файлы обнуляются, а не
// удаляются: byway дописывает в них на ходу.
function cmd_clear(what) {
	let lists = getenv('BW_LISTS'), dir = '/var/run/byway';
	let log = what == 'log' || what == 'all', st = what == 'stat' || what == 'all';
	if (!log && !st) die('byway clear log | stat | all');
	if (log) {
		fs.writefile(lists + '/health.log', '');
		fs.writefile('/var/run/byway-watch.last', '');
	}
	if (st) {
		// И сырьё (журнал обращений с адресами), и карта с позицией и
		// отсечкой: иначе карта считалась бы построенной, и всё шло бы в
		// «(поддомены)».
		fs.writefile(lists + '/usage.tsv', '');
		fs.writefile(dir + '/fakemap', '');
		let acc = getenv('BW_ACCESS');
		if (fs.stat(acc)) fs.writefile(acc, '');
		fs.unlink(dir + '/fakemap.pos');
		fs.unlink(dir + '/statmark');
	}
	if (what == 'log') say('журнал состояния очищен');
	else if (what == 'stat') say('статистика использования очищена');
	else say('журнал и статистика очищены');
}
