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
		print(_t('  3. Проверить: byway health — все четыре строки зелёные.\n'));
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
	c_help('health', _t('проверить: служба, VPN, трафик, DNS'));
	c_help('menu', _t('всё то же пунктами меню'));
	print('\n', _t('  Все команды: byway help'), '\n');
}

// ── byway help ────────────────────────────────────────────────────────────
function cmd_help() {
	print(C_B, 'byway ', getenv('BW_VERSION'), C_0, _t(' — раздельное туннелирование через VPN\n'));
	c_group(_t('Подключение'));
	c_help("key 'ССЫЛКА'", _t('вписать ключ (проверяется до записи) и применить; ссылку — в одинарных кавычках'));
	c_help('on | off', _t('включить или выключить byway'));
	c_help('probe [ССЫЛКА|--all]', _t('проверить ключ отдельно, не трогая работающий туннель; --all — все ключи'));
	c_help('sub АДРЕС', _t('скачать ключи из подписки'));
	c_group(_t('Списки'));
	c_help('add САЙТ|ПОДСЕТЬ …', _t('добавить в свои списки и применить; сразу несколько, через пробел; «-» — читать список со ввода до Ctrl+D'));
	c_help('del САЙТ|ПОДСЕТЬ …', _t('убрать из своих списков и применить'));
	c_help('presets', _t('обновить готовые списки'));
	c_help('top [N]', _t('чем на самом деле пользуются'));
	c_group(_t('Состояние'));
	c_help('health', _t('быстрая проверка: служба, VPN, трафик, DNS'));
	c_help('status [--short]', _t('что сейчас работает, подробно'));
	c_help('doctor', _t('проверка окружения: что не так и как исправить'));
	c_help('report [файл]', _t('отчёт для обращения, без ключа от VPN'));
	c_group(_t('Обслуживание'));
	c_help('menu', _t('те же действия пунктами меню'));
	c_help('update [--check|--force|--rollback|--no-verify]', _t('новая версия byway: --check — только проверить, --force — переставить ту же, --rollback — вернуть прежнюю, --no-verify — без проверки подписи'));
	c_help('engine [ВЕРСИЯ|tested|newest|stable|restore|/tmp/ФАЙЛ]', _t('ядро Xray-core: без довода — есть ли обновление и подробности, с доводом — замена'));
	c_help('lang [ru|en]', _t('язык вывода и панели'));
	c_help('export [файл] [--with-key]', _t('выгрузить настройки; по умолчанию без ключа'));
	c_help('import ФАЙЛ [--no-key]', _t('принять настройки из выгрузки; --no-key — ключ не трогать'));
	c_help('clear log|stat|all', _t('очистить журнал состояния, статистику или то и другое'));
	c_group(_t('Для опытных'));
	c_help('check [ССЫЛКА]', _t('разобрать ключ и проверить конфиг, без соединений'));
	c_help('gen', _t('пересобрать конфиг из настроек и списков'));
	c_help('show', _t('собранный конфиг без секретов: счётчики и правила'));
	c_help('nft', _t('правила перехвата, не применяя их'));
	c_help('plumb on | off', _t('включить или снять перехват (nft, маршрут, DNS)'));
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
