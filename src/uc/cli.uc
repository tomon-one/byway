// Консоль для человека (владелец 2026-10-18: «функционал cli и luci
// одинаковый», «улучшили luci, осталось cli»): ключ, включение и списки --
// одной командой, сводка на `byway` без доводов -- как «Основное» в панели,
// список команд -- по группам.

const C_OK = '\033[1;32m', C_WARN = '\033[1;33m', C_BAD = '\033[1;31m', C_DIM = '\033[2m', C_B = '\033[1m', C_0 = '\033[0m';


// Строка «команда — описание» с переносом описания по словам.
function c_help(cmd, txt) {
	let W = 78, I = 24, line;
	// Длинная команда -- своей строкой, описание под ней с отступом.
	if (c_len(cmd) > I - 3) { print('  ', C_B, cmd, C_0, '\n'); line = sprintf('%' + I + 's', ''); }
	else line = '  ' + C_B + cmd + C_0 + sprintf('%' + (I - 2 - c_len(cmd)) + 's', '');
	let cur = I;
	for (let w in split(txt, ' ')) {
		if (cur > I && cur + 1 + c_len(w) > W) { print(line, '\n'); line = sprintf('%' + I + 's', ''); cur = I; }
		line += (cur > I ? ' ' : '') + w;
		cur += (cur > I ? 1 : 0) + c_len(w);
	}
	print(line, '\n');
}
function c_group(t) { print('\n', C_B, t, C_0, '\n'); }

// Ключа нет -- по способу подключения, как в панели.
// В режимах нескольких ключей byway работает и на одиночном ключе, если
// список пуст: «нет ключа» -- только когда пусто и там, и там.
function c_nokey() {
	if ((u('conn_mode') || 'key') == 'outbound') return trim(u('outbound_json')) === '';
	return trim(u('node_url')) === '' && trim(u('node_urls')) === '';
}

// ── проверка для человека ────────────────────────────────────────────────
// Вход -- строки byway health «проверка<TAB>состояние<TAB>пояснение» (их
// же разбирает панель); выход -- точки цветом и что делать.
function c_checks() {
	return [ [ 'service', _t('Служба') ], [ 'vpn', _t('Связь с VPN') ], [ 'tunnel', _t('Трафик через VPN') ], [ 'dns', 'DNS' ] ];
}

// Стрелка с захватом seen на ucode 22.03/23.05 роняла бы программу -- проверка
// отдельной функцией.
function c_fail(seen, k) { return seen[k] != null && seen[k].st == 'fail'; }
function c_advice(seen) {
	if (c_nokey()) return [];
	if (c_fail(seen, 'service'))
		return [ _t('Служба не запущена. Включить и запустить: byway on. Не помогло — byway doctor назовёт причину.') ];
	let out = [];
	if (c_fail(seen, 'vpn'))
		push(out, _t("Связи с сервером VPN нет: ключ вставлен не целиком, устарел, или сервер выключен либо заблокирован. Проверить ключ: byway probe; если «НЕ РАБОТАЕТ», возьмите свежий ключ у сервиса VPN и впишите: byway key 'ССЫЛКА'."));
	else if (c_fail(seen, 'tunnel'))
		push(out, _t("Сервер отвечает, но трафик через него не идёт. Чаще всего ключ устарел или в нём ошибка: byway probe, при неудаче — новый ключ: byway key 'ССЫЛКА'."));
	if (c_fail(seen, 'dns') && !length(out))
		push(out, _t('Резолвер byway не отвечает, и сайты из списков не откроются. Перезапустить: /etc/init.d/byway restart; не помогло — byway doctor.'));
	return out;
}

function c_health(text) {
	let seen = {};
	for (let l in split(text ?? '', '\n')) {
		let p = split(l, '\t');
		if (length(p) >= 3) seen[p[0]] = { st: p[1], note: p[2] };
	}
	for (let c in c_checks()) {
		let v = seen[c[0]] ?? { st: 'warn', note: _t('нет данных') };
		let col = v.st == 'ok' ? C_OK : (v.st == 'fail' ? C_BAD : C_WARN);
		print('  ', col, '●', C_0, ' ', c_pad(c[1], 17), C_DIM, v.note, C_0, '\n');
	}
	for (let a in c_advice(seen)) print('\n  ', C_BAD, '! ', C_0, a, '\n');
}

// bw_uc hfmt: строки health со входа -- для человека (byway health в терминале).
function cmd_hfmt() { c_health(fs.stdin.read('all')); }

// ── byway без доводов ─────────────────────────────────────────────────────
function cmd_home() {
	print(C_B, 'byway ', getenv('BW_VERSION'), C_0, _t(' — раздельное туннелирование через VPN\n\n'));
	if (c_nokey()) {
		print(_t('  С чего начать:\n'));
		print(_t('  1. Вписать ключ — ссылку от сервиса VPN, в одинарных кавычках:\n'), "       byway key 'vless://…'\n");
		print(_t('  2. Добавить сайты, которые должны идти через VPN:\n       byway add youtube.com instagram.com\n'));
		print(_t('  3. Проверить: byway — все четыре строки зелёные.\n'));
		print(_t('  Подробно, по шагам: https://github.com/tomon-one/byway/blob/main/docs/beginner.md\n'));
	} else {
		c_health(run([ m_self(), 'health' ]).out);
		let g = {};
		for (let l in pl_lines(run([ m_self(), 'status', '--short' ]).out)) {
			let m = match(l, /^(\S+)\s+(.*)$/);
			if (m) g[m[1]] = trim(m[2]);
		}
		let name = g[_t('подключение')] ?? g[_t('ключ')], tr = g[_t('транспорт')];
		if (name) print('\n  ', _t('Подключение: '), name, tr ? ' · ' + tr : '', '\n');
		if (u('enabled') != '1') print('  ', C_WARN, _t('byway выключен'), C_0, _t(' — включить: byway on'), '\n');
	}
	c_group(_t('Частые команды'));
	c_help("key 'ССЫЛКА'", _t('вписать ключ и применить'));
	c_help('add САЙТ …', _t('добавить сайты или подсети в свои списки'));
	c_help('list', _t('что пускается через VPN'));
	c_help('set', _t('все настройки'));
	c_help('menu', _t('всё то же пунктами меню'));
	print('\n', _t('  Все команды: byway help'), '\n');
	// В терминале -- сразу в меню по Enter: новичку не нужно помнить команды.
	// Из скрипта и ssh 'byway' (не терминал) -- ничего не спрашивается.
	if (getenv('BW_INTERACTIVE') == '1') {
		print('\n', C_B, _t('  Enter — открыть меню, Ctrl+C — выйти'), C_0, ' ');
		fs.stdout?.flush();
		let l = fs.stdin.read('line');
		if (l != null && trim(l) === '') sys([ m_self(), 'menu' ]);
	}
}

// ── byway help ────────────────────────────────────────────────────────────
// Команды -- по предметам (ключ, списки, состояние); служебные -- только в
// `byway help all` (владелец 2026-10-18: «максимально просто»).
function cmd_help(all) {
	print(C_B, 'byway ', getenv('BW_VERSION'), C_0, _t(' — раздельное туннелирование через VPN\n'));
	c_group(_t('Ключ'));
	c_help("key 'ССЫЛКА'", _t('вписать ключ (проверяется до записи) и применить; ссылку — в одинарных кавычках'));
	c_help('key', _t('какой ключ стоит и работает ли'));
	c_help('keys', _t('список ключей, активный отмечен'));
	c_help('key use N', _t('сделать активным ключ номер N'));
	c_help('key sub АДРЕС', _t('взять ключи из подписки'));
	c_help('probe [--all]', _t('проверить ключ, не трогая работающий туннель; --all — все ключи'));
	c_group(_t('Списки'));
	c_help('list', _t('что пускается через VPN: режим, свои списки, готовые'));
	c_help('add САЙТ|ПОДСЕТЬ …', _t('добавить в свои списки и применить; сразу несколько, через пробел; «-» — читать список со ввода до Ctrl+D'));
	c_help('del САЙТ|ПОДСЕТЬ …', _t('убрать из своих списков и применить'));
	c_help('list ready', _t('готовые списки; подключить: list ready on ИМЯ'));
	c_help('mode lists|all', _t('по спискам или всё через VPN'));
	c_help('top [N]', _t('чем на самом деле пользуются'));
	c_group(_t('Работа'));
	c_help('(без команды)', _t('проверка: служба, VPN, трафик, DNS, и что делать'));
	c_help('on | off', _t('включить или выключить byway'));
	c_help('status', _t('что сейчас работает, подробно'));
	c_help('doctor [--fix]', _t('проверка окружения: что не так и как исправить; --fix — починить, что чинится само'));
	c_help('set [ИМЯ ЗНАЧЕНИЕ]', _t('все настройки и их значения; изменить одну и применить'));
	c_help('menu', _t('всё то же пунктами меню'));
	c_group(_t('Обслуживание'));
	c_help('update [--check|--rollback]', _t('новая версия byway: --check — только проверить, --rollback — вернуть прежнюю'));
	c_help('core [tested|ВЕРСИЯ]', _t('ядро Xray-core: без довода — есть ли обновление; tested — поставить проверенное'));
	c_help('lang ru|en', _t('язык вывода и панели'));
	c_help('export [файл] [--with-key]', _t('выгрузить настройки; по умолчанию без ключа'));
	c_help('import ФАЙЛ [--no-key]', _t('принять настройки из выгрузки; --no-key — ключ не трогать'));
	c_help('report [файл]', _t('отчёт для обращения, без ключа от VPN'));
	if (all != 'all') { print('\n', _t('  Служебные команды: byway help all'), '\n'); return; }
	c_group(_t('Служебные'));
	c_help('health', _t('проверка строками для скриптов и панели; в терминале — как byway без доводов'));
	c_help('check [ССЫЛКА]', _t('разобрать ключ и проверить конфиг, без соединений'));
	c_help('sub АДРЕС', _t('скачать подписку и напечатать ключи'));
	c_help('presets', _t('скачать подключённые готовые списки'));
	c_help('update --force|--no-verify', _t('--force — переставить ту же версию, --no-verify — без проверки подписи'));
	c_help('core newest|stable|restore|/tmp/ФАЙЛ', _t('свежее или стабильное ядро, вернуть пропавшее, своя сборка; engine — то же'));
	c_help('clear log|stat|all', _t('очистить журнал состояния, статистику или то и другое'));
	c_help('gen', _t('пересобрать конфиг из настроек и списков'));
	c_help('show', _t('собранный конфиг без секретов: счётчики и правила'));
	c_help('nft', _t('правила перехвата, не применяя их'));
	c_help('plumb on|off', _t('включить или снять перехват (nft, маршрут, DNS)'));
	c_help('job update|engine|probe|log', _t('то же в фоне, ход в журнале (так зовёт панель)'));
	c_help('version', _t('версия'));
}

// ── ключ и включение ──────────────────────────────────────────────────────
// Применить: gen показывает, что собралось, reload службы перезапускает
// только при отличии (как «Сохранить и применить» в панели).
function c_apply() {
	if (sys([ m_self(), 'gen' ]) != 0) {
		print('  ', C_BAD, _t('не применилось'), C_0, _t(' — работает прежняя настройка'), '\n');
		return false;
	}
	if (u('enabled') != '1') {
		print('  ', C_WARN, _t('собрано, но byway выключен'), C_0, _t(' — включить: byway on'), '\n');
		return true;
	}
	run([ '/etc/init.d/byway', 'reload' ]);
	print('  ', C_OK, _t('применено'), C_0, '\n');
	return true;
}

// bw_uc key ССЫЛКА: проверка до записи -- неразобранный ключ в настройках
// оставил бы дом без туннеля и без понятной причины.
function cmd_key(url) {
	if (!url) die("нужна ссылка: byway key 'vless://…' — в одинарных кавычках, иначе оболочка обрежет её на знаке &");
	let r = run([ m_self(), 'check', url ], true);
	print(r.out);
	if (r.code != 0) die('ключ не принят — настройки не изменены');
	m_uci('node_url=' + url, 'conn_mode=key');
	say('ключ записан, способ подключения — один ключ');
	c_apply();
}

// bw_uc on | off. Выключение -- остановкой службы: она снимает перехват и
// запрет «Не пускать», дом остаётся с интернетом без VPN.
function cmd_onoff(on) {
	m_uci('enabled=' + (on ? '1' : '0'));
	if (on) {
		run([ '/etc/init.d/byway', 'enable' ]);
		sys([ '/etc/init.d/byway', 'restart' ]);
		say('byway включён — ядро поднимается до 15 секунд; проверить: byway health');
		if (c_nokey()) warn("ключ не задан — вписать: byway key 'ССЫЛКА'");
	} else {
		sys([ '/etc/init.d/byway', 'stop' ]);
		say('byway выключен: интернет идёт напрямую, без VPN; включить: byway on');
	}
}

// ── свои списки ───────────────────────────────────────────────────────────
// Записи из доводов: несколько через пробел или запятую, «-» -- со ввода
// (вставить список и Ctrl+D). Комментарии и пустые -- мимо.
function c_items(args) {
	let out = [];
	for (let a in args) {
		let t = a == '-' ? (fs.stdin.read('all') ?? '') : a;
		// Комментарий -- до конца строки, потом слова: иначе «# видео»
		// давало запись «видео».
		for (let ln in split(t, '\n')) {
			let c = index(ln, '#'), d = index(ln, '//');
			// «//» после «:» -- часть ссылки (https://), не комментарий.
			if (d > 0 && substr(ln, d - 1, 1) == ':') d = index(substr(ln, d + 2), '//') >= 0 ? d + 2 + index(substr(ln, d + 2), '//') : -1;
			if (c >= 0) ln = substr(ln, 0, c);
			if (d >= 0 && (c < 0 || d < c)) ln = substr(ln, 0, d);
			for (let l in split(ln, /[ \t\r,]+/)) {
				l = trim(l);
				if (l !== '') push(out, l);
			}
		}
	}
	return out;
}

// Ссылка вида https://www.example.com/path -- имя сайта; регистр -- строчный.
function c_host(l) {
	let m = match(l, /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/([^\/?#:]+)/);
	if (m) l = m[1];
	return lc(l);
}

// Подсеть или адрес (IPv4 a.b.c.d[/n], IPv6 с двоеточием без приставки
// full:/keyword:…) -- в subnets.lst, остальное -- в domains.lst.
function c_kind(l) {
	if (match(l, /^[0-9.]+(\/[0-9]+)?$/)) return 'subnets';
	if (index(l, ':') >= 0 && match(l, /^[0-9a-fA-F:]+(\/[0-9]{1,3})?$/)) return 'subnets';
	return 'domains';
}

function c_file(kind) { return getenv('BW_LISTS') + '/' + kind + '.lst'; }
function c_read(kind) { return map(pl_lines(fs.readfile(c_file(kind))), (x) => trim(x)); }
function c_write(kind, lines) {
	let f = c_file(kind), t = join('\n', lines);
	if (t !== '') t += '\n';
	fs.writefile(f + '.new', t);
	return fs.rename(f + '.new', f);
}

// bw_uc add ЗАПИСЬ … : проверка -- той же меркой, что при сборке (lj_entry),
// повторы -- мимо, в конце -- применить.
function cmd_add(...args) {
	let items = c_items(args);
	if (!length(items)) die('что добавить: byway add youtube.com instagram.com 91.108.4.0/22; список со ввода: byway add -');
	let cur = { domains: c_read('domains'), subnets: c_read('subnets') }, n = 0, add = { domains: [], subnets: [] };
	for (let raw in items) {
		let l = c_host(raw), k = c_kind(l);
		if (lj_entry(l, k == 'domains', '') == null) { print('  ', C_BAD, '✗', C_0, ' ', _f('не похоже ни на сайт, ни на подсеть: %s', raw), '\n'); continue; }
		if (index(cur[k], l) >= 0 || index(add[k], l) >= 0) { print('  ', C_DIM, '=', C_0, ' ', _f('уже есть: %s', l), '\n'); continue; }
		push(add[k], l);
		print('  ', C_OK, '+', C_0, ' ', l, C_DIM, k == 'subnets' ? _t('  (подсеть)') : '', C_0, '\n');
		n++;
	}
	if (!n) { print(_t('  добавлять нечего\n')); return; }
	for (let k in [ 'domains', 'subnets' ])
		if (length(add[k])) c_write(k, [ ...cur[k], ...add[k] ]);
	sayf('добавлено: %s', n);
	c_apply();
}

// bw_uc del ЗАПИСЬ … : только из своих списков; запись из готового списка
// убирается вместе с ним.
function cmd_del(...args) {
	let items = c_items(args);
	if (!length(items)) die('что убрать: byway del example.com 91.108.4.0/22');
	let cur = { domains: c_read('domains'), subnets: c_read('subnets') }, n = 0;
	for (let raw in items) {
		let l = c_host(raw), k = c_kind(l);
		if (index(cur[k], l) < 0) { print('  ', C_DIM, '=', C_0, ' ', _f('нет в своих списках: %s', l), '\n'); continue; }
		let keep = [];
		for (let x in cur[k]) if (x != l) push(keep, x);
		cur[k] = keep;
		print('  ', C_WARN, '−', C_0, ' ', l, '\n');
		n++;
	}
	if (!n) { print(_t('  убирать нечего\n')); return; }
	c_write('domains', cur.domains);
	c_write('subnets', cur.subnets);
	sayf('убрано: %s', n);
	c_apply();
}

// ── настройки: byway set ──────────────────────────────────────────────────
// Всё, что есть в панели, -- одной командой, с той же проверкой значения и
// применением (владелец 2026-10-18: «ни одной подсказки с uci»). default --
// вернуть умолчание (опция удаляется). Вид: f -- да/нет, e -- из списка,
// r -- по образцу, l -- список через пробел.
function c_sets() {
	return [
		[ 'conn_mode', 'e', 'key sub selector urltest outbound', _t('способ подключения: один ключ, подписка, несколько вручную, несколько автоматически, свой конфиг') ],
		[ 'list_mode', 'e', 'lists all', _t('режим: по спискам или всё через VPN (то же — byway mode)') ],
		[ 'ru_direct', 'f', '', _t('.ru, .su и .рф — напрямую в режиме «всё через VPN»') ],
		[ 'on_failure', 'e', 'open closed', _t('если VPN не поднялся: open — пустить напрямую, closed — не пускать') ],
		[ 'interface', 'l', '^[A-Za-z0-9._-]+$', _t('сети роутера, которые пользуются VPN (br-lan — домашняя)') ],
		[ 'mux_concurrency', 'r', '^[0-9]{1,3}$', _t('Mux: запросов в одном соединении, 0 — выключено') ],
		[ 'dns_upstream', 'r', '^https://[^ ]+$', _t('DNS-сервер, шифрованный (DoH): https://…/dns-query') ],
		[ 'dns_upstream2', 'r', '^(https://[^ ]+|none)$', _t('запасной DNS-сервер; none — без запасного') ],
		[ 'dns_bootstrap', 'r', '^[0-9a-fA-F.:]+$', _t('DNS для имени DoH-сервера, если тот вписан именем') ],
		[ 'dns_route', 'e', 'direct tunnel', _t('путь к DNS-серверу: напрямую или через VPN') ],
		[ 'block_quic', 'f', '', _t('отказ QUIC для сайтов через VPN') ],
		[ 'router_via_vpn', 'f', '', _t('VPN для программ на самом роутере') ],
		[ 'ipv6', 'f', '', _t('IPv6 (экспериментально)') ],
		[ 'log_level', 'e', 'none error warning info debug', _t('подробность журнала ядра') ],
		[ 'probe_interval', 'r', '^[0-9]+[smh]?$', _t('шаг проверки ключей в автовыборе: 3m, 30s') ],
		[ 'show_usage', 'f', '', _t('сбор статистики «чем пользуются»') ],
		[ 'lists_update', 'r', '^[0-9]+[mhd]?([0-9]+[mhd])*$', _t('период обновления готовых списков: 12h, 1d; 0 — только вручную') ],
		[ 'update_check', 'f', '', _t('проверка новых версий byway') ],
		[ 'auto_update', 'f', '', _t('автоматическая установка новых версий') ],
		[ 'auto_update_hour', 'r', '^([01]?[0-9]|2[0-3])$', _t('час автоматической установки, по часам роутера') ],
		[ 'guard', 'f', '', _t('восстановление перехвата раз в пять минут') ],
		[ 'xray_memlimit', 'r', '^([0-9]+([KMGT]i?B|[KMG])?|off|no)$', _t('предел памяти ядра: 96, 128MiB; 0 — без предела') ],
		[ 'xray_root', 'f', '', _t('ядро от root — небезопасно') ],
		[ 'allow_insecure', 'f', '', _t('незащищённые ключи — небезопасно, соединение можно подменить') ],
		[ 'xray_bin', 'r', '^/[^ ]+$', _t('путь к ядру Xray; обычно его вписывает byway core') ],
		[ 'fakeip_pool', 'r', '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$', _t('пул подставных адресов') ],
		[ 'fakeip6_pool', 'r', '^[0-9a-fA-F:]+/[0-9]+$', _t('пул подставных адресов IPv6') ],
		[ 'dns_listen', 'r', '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$', _t('адрес резолвера byway') ],
		[ 'tproxy_port', 'r', '^[0-9]{1,5}$', _t('порт перехвата') ],
		[ 'local_proxy_port', 'r', '^[0-9]{1,5}$', _t('порт прокси byway') ],
		[ 'mark', 'r', '^(0x[0-9a-fA-F]{1,8}|[0-9]{1,10})$', _t('метка пакетов') ],
		[ 'self_mark', 'r', '^(0x[0-9a-fA-F]{1,8}|[0-9]{1,10})$', _t('метка соединений ядра') ],
	];
}

// Флаг: да/нет любыми словами -> 1/0; не флаг -- null.
function c_flag(v) {
	v = lc(v);
	if (index([ '1', 'on', 'yes', 'true', 'да', 'вкл' ], v) >= 0) return '1';
	if (index([ '0', 'off', 'no', 'false', 'нет', 'выкл' ], v) >= 0) return '0';
	return null;
}

function c_uci(cmd) { return run([ 'uci', '-q', ...cmd ]).code == 0; }

// Записать настройку: значение (или список) и commit; курсор -- заново.
function c_store(name, vals, list) {
	c_uci([ 'delete', 'byway.main.' + name ]);
	if (list) { for (let v in vals) c_uci([ 'add_list', 'byway.main.' + name + '=' + v ]); }
	else if (length(vals)) c_uci([ 'set', 'byway.main.' + name + '=' + vals[0] ]);
	c_uci([ 'commit', 'byway' ]);
	_cur = null;
}

function c_show_val(name, kind) {
	let v = u(name);
	if (v === '') return C_DIM + _t('по умолчанию') + C_0;
	if (kind == 'f') return v == '1' ? C_OK + _t('да') + C_0 : _t('нет');
	return v;
}

function cmd_set(name, ...rest) {
	let S = c_sets();
	if (!name) {
		print(C_B, _t('Настройки'), C_0, _t(' — изменить: byway set ИМЯ ЗНАЧЕНИЕ; вернуть умолчание: byway set ИМЯ default\n\n'));
		for (let s in S) {
			print('  ', C_B, c_pad(s[0], 18), C_0, ' ', c_pad(c_show_val(s[0], s[1]), 22), ' ', C_DIM, s[3], C_0, '\n');
		}
		return;
	}
	let s = null;
	for (let x in S) if (x[0] == name) s = x;
	if (!s) dief('нет такой настройки: %s — список: byway set', name);
	if (!length(rest)) {
		print('  ', C_B, s[0], C_0, ' = ', c_show_val(s[0], s[1]), '\n  ', s[3], '\n');
		if (s[1] == 'f') print(_t('  значения: on или off\n'));
		else if (s[1] == 'e') print(_f('  значения: %s\n', join(', ', split(s[2], ' '))));
		return;
	}
	let vals = rest;
	if (length(rest) == 1 && rest[0] == 'default') vals = [];
	else if (s[1] == 'f') {
		let f = c_flag(rest[0]);
		if (f == null) dief('%s — да или нет: on или off', name);
		vals = [ f ];
	} else if (s[1] == 'e') {
		if (index(split(s[2], ' '), rest[0]) < 0) dief('%s — одно из: %s', name, join(', ', split(s[2], ' ')));
		vals = [ rest[0] ];
	} else {
		if (s[1] != 'l') vals = [ join(' ', rest) ];
		for (let v in vals) if (!match(v, regexp(s[2]))) dief('значение «%s» не годится для %s', v, name);
		if (name == 'xray_bin' && !x_ok(vals[0])) dief('%s — не запускаемое ядро Xray в системном каталоге', vals[0]);
	}
	c_store(name, vals, s[1] == 'l');
	print('  ', C_B, name, C_0, ' = ', c_show_val(name, s[1]), '\n');
	c_apply();
}

// ── ключи ────────────────────────────────────────────────────────────────
function c_keylist() {
	let v = cursor().get('byway', 'main', 'node_urls');
	if (v == null) return [];
	return type(v) == 'array' ? v : [ v ];
}

// Ключ одной строкой: схема, сервер, имя -- uuid и пароль не печатаются.
function c_keyshort(k) {
	let b = split(k, '#')[0], h = rindex(k, '#');
	// В ucode (POSIX) нет (?:…) -- учётная часть отдельной группой.
	let m = match(b, /^([a-z0-9+.-]+):\/\/([^@\/?]*@)?([^\/?#]+)/);
	let name = h >= 0 ? pk_pctd(substr(k, h + 1)) : '';
	return (m ? m[1] + '://…@' + m[3] : substr(b, 0, 40) + '…') + (name !== '' ? ' · ' + name : '');
}

// byway keys: список с номерами, активный отмечен.
function cmd_keys() {
	let L = c_keylist(), cur = u('node_url');
	if (!length(L) && cur !== '') L = [ cur ];
	if (!length(L)) { print(_t("  ключей нет — вписать: byway key 'ССЫЛКА' или из подписки: byway key sub АДРЕС"), '\n'); return; }
	let i = 0;
	for (let k in L) {
		i++;
		print('  ', k == cur ? C_OK + '●' + C_0 : ' ', ' ', C_B, i, C_0, '  ', c_keyshort(k), '\n');
	}
	print('\n', _t('  ● — активный. Выбрать: byway key use N; проверить все: byway probe --all\n'));
}

// byway key use N: активный -- N-й из списка; способ -- «несколько вручную».
function c_key_use(n) {
	let L = c_keylist(), i = int(n ?? '0');
	if (!length(L)) die("в списке ключей пусто — сначала: byway key sub АДРЕС или byway key 'ССЫЛКА'");
	if (!(i >= 1 && i <= length(L))) dief('номер ключа — от 1 до %s: byway keys', length(L));
	m_uci('node_url=' + L[i - 1], 'conn_mode=selector');
	sayf('активный ключ: %s', c_keyshort(L[i - 1]));
	c_apply();
}

// byway key sub АДРЕС: ключи подписки -- в список, активный остаётся, если
// он есть среди них, иначе первый; способ -- «несколько вручную».
function c_key_sub(url) {
	if (!url) die('byway key sub АДРЕС — адрес подписки https://…');
	let r = run([ 'env', 'BW_SUB_URL=' + url, m_self(), 'sub', url ], true);
	let keys = [];
	for (let l in split(r.out, '\n')) {
		l = trim(l);
		let m = match(l, /^([a-z0-9+.-]+):\/\//);
		if (m && index([ 'vless', 'vmess', 'trojan', 'ss', 'socks', 'hysteria2', 'hy2', 'wireguard', 'wg' ], lc(m[1])) >= 0) push(keys, l);
	}
	if (!length(keys)) { print(r.out); die('ключей в подписке не нашлось — настройки не изменены'); }
	c_store('node_urls', keys, true);
	let cur = u('node_url'), act = index(keys, cur) >= 0 ? cur : keys[0];
	m_uci('node_url=' + act, 'sub_url=' + url, (u('conn_mode') == 'urltest' ? 'conn_mode=urltest' : 'conn_mode=selector'));
	sayf('ключей из подписки: %s', length(keys));
	cmd_keys();
	c_apply();
}

// byway key [ССЫЛКА | use N | sub АДРЕС]: без довода -- какой ключ и
// работает ли (проба, ~6 с).
function cmd_key2(a, b) {
	if (a == 'use') return c_key_use(b);
	if (a == 'sub') return c_key_sub(b);
	if (a) return cmd_key(a);
	if (c_nokey()) { print(_t("  ключ не задан — вписать: byway key 'ССЫЛКА'"), '\n'); return; }
	let m = u('conn_mode') || 'key';
	if (m == 'outbound') print(_t('  свой конфиг аутбаунда\n'));
	else print('  ', c_keyshort(u('node_url') || c_keylist()[0]), '\n');
	print('\n');
	sys([ 'env', 'BW_TTY=1', m_self(), 'probe' ]);
}

// ── списки ───────────────────────────────────────────────────────────────
// byway list: что в списках; domains|subnets -- свои целиком; ready --
// готовые (on|off ИМЯ -- подключить или убрать).
function c_presets() {
	let v = cursor().get('byway', 'main', 'preset');
	if (v == null) return [];
	return type(v) == 'array' ? v : split(trim(v), /[ \t]+/);
}

function c_ready(act, names) {
	let P = c_presets();
	if (!act) {
		for (let n in PS_NAMES)
			print('  ', index(P, n) >= 0 ? C_OK + '●' + C_0 : ' ', ' ', C_B, c_pad(n, 20), C_0, ' ', C_DIM, ps_about(n), C_0, '\n');
		print('\n', _t('  ● — подключён. Подключить: byway list ready on ИМЯ; убрать: byway list ready off ИМЯ\n'));
		return;
	}
	if (act != 'on' && act != 'off') die('byway list ready on|off ИМЯ …');
	if (!length(names)) dief('какой список: %s', join(', ', PS_NAMES));
	for (let n in names) {
		if (index(PS_NAMES, n) < 0) dief('нет такого готового списка: %s — есть: %s', n, join(', ', PS_NAMES));
		if (act == 'on' && index(P, n) < 0) push(P, n);
		if (act == 'off') { let k = []; for (let x in P) if (x != n) push(k, x); P = k; }
	}
	c_store('preset', P, true);
	if (act == 'on') sys([ m_self(), 'presets' ]);
	c_apply();
}

function cmd_list(what, ...rest) {
	if (what == 'domains' || what == 'subnets') {
		for (let l in c_read(what)) print(l, '\n');
		return;
	}
	if (what == 'ready') return c_ready(rest[0], slice(rest, 1));
	if (what) dief('byway list [domains|subnets|ready] — не %s', what);
	let all = u('list_mode') == 'all';
	print('  ', _t('Режим: '), C_B, all ? _t('всё через VPN') : _t('по спискам'), C_0, C_DIM, _t('  (сменить: byway mode lists|all)'), C_0, '\n\n');
	print('  ', c_pad(_t('свои сайты'), 22), lj_count(c_file('domains')), C_DIM, _t('   byway list domains'), C_0, '\n');
	print('  ', c_pad(_t('свои подсети'), 22), lj_count(c_file('subnets')), C_DIM, _t('   byway list subnets'), C_0, '\n');
	let P = c_presets();
	print('  ', c_pad(_t('готовые списки'), 22), length(P) ? join(', ', P) : _t('не подключены'), C_DIM, _t('   byway list ready'), C_0, '\n');
	let rd = getenv('BW_ROUTES'), R = filter(fs.lsdir(rd) ?? [], (f) => substr(f, -4) == '.lst');
	if (length(R)) print('  ', c_pad(_t('направления'), 22), length(R), '\n');
	print('\n', _t('  Добавить: byway add САЙТ|ПОДСЕТЬ …   убрать: byway del …\n'));
}

// byway mode lists|all
function cmd_mode(m) {
	if (m != 'lists' && m != 'all') {
		print('  ', _t('Режим: '), C_B, u('list_mode') == 'all' ? _t('всё через VPN') : _t('по спискам'), C_0, '\n');
		print(_t('  byway mode lists — через VPN только списки; byway mode all — весь трафик\n'));
		return;
	}
	m_uci('list_mode=' + m);
	if (m == 'all') say('режим: всё через VPN');
	else say('режим: по спискам');
	c_apply();
}

// ── опечатка в команде ───────────────────────────────────────────────────
// Ближайшая по расстоянию правки команда: «helth» -> «health».
const C_NAMES = [ 'help', 'key', 'keys', 'on', 'off', 'add', 'del', 'list', 'mode', 'set', 'probe', 'health',
	'status', 'doctor', 'menu', 'update', 'core', 'engine', 'lang', 'export', 'import', 'report', 'top', 'clear',
	'presets', 'sub', 'check', 'gen', 'show', 'nft', 'plumb', 'version' ];
function c_dist(a, b) {
	let p = [];
	for (let j = 0; j <= length(b); j++) push(p, j);
	for (let i = 1; i <= length(a); i++) {
		let q = [ i ];
		for (let j = 1; j <= length(b); j++)
			push(q, min(p[j] + 1, q[j - 1] + 1, p[j - 1] + (substr(a, i - 1, 1) == substr(b, j - 1, 1) ? 0 : 1)));
		p = q;
	}
	return p[length(b)];
}
function cmd_unknown(w) {
	let best = null, bd = 99;
	for (let n in C_NAMES) { let d = c_dist(lc(w ?? ''), n); if (d < bd) { bd = d; best = n; } }
	if (best && bd <= 2) printf(_t('byway: нет команды «%s». Может быть: byway %s\n'), w, best);
	else printf(_t('byway: нет команды «%s». Все команды: byway help\n'), w);
	exit(1);
}

// ── byway doctor --fix ───────────────────────────────────────────────────
// Чинит то, что чинится само и без риска; остальное -- советом doctor.
function cmd_fix() {
	let n = 0;
	if (u('enabled') == '1' && !fs.stat('/etc/rc.d/S21byway')) {
		run([ '/etc/init.d/byway', 'enable' ]); say('автозапуск службы включён'); n++;
	}
	let cr = run([ 'crontab', '-l' ]).out, add = '';
	if (index(cr, 'byway watch') < 0) add += '*/5 * * * * /usr/local/bin/byway watch >/dev/null 2>&1\n';
	if (index(cr, 'byway stat') < 0) add += '7 * * * * /usr/local/bin/byway stat >/dev/null 2>&1\n';
	if (index(cr, 'byway pulse') < 0) add += '* * * * * /usr/local/bin/byway pulse >/dev/null 2>&1\n';
	if (add !== '') {
		let t = (cr !== '' && substr(cr, -1) != '\n') ? cr + '\n' : cr;
		let p = fs.popen('crontab -', 'w');
		if (p) { p.write(t + add); p.close(); say('задачи cron byway возвращены'); n++; }
	}
	if (run([ 'pidof', 'crond' ]).code != 0) {
		run([ '/etc/init.d/cron', 'enable' ]); run([ '/etc/init.d/cron', 'start' ]); say('crond запущен'); n++;
	}
	if (u('enabled') == '1' && !c_nokey()) {
		if (st_xray_pid() === '') {
			sys([ '/etc/init.d/byway', 'restart' ]); say('служба перезапущена'); n++;
		} else if (!pl_has_table(PL_TABLE) || !fs.stat(dm_file(DM_DNS) || '/nonexistent')) {
			sys([ m_self(), 'plumb', 'on' ]); say('перехват поднят заново'); n++;
		}
	}
	if (!fs.stat('/sbin/ujail'))
		warn("пакета procd-ujail нет — ядро работает от root; поставить: apk add procd-ujail (или opkg install) && /etc/init.d/byway restart");
	if (!n) say('чинить само нечего');
	print('\n');
}
