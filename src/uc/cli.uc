// Консоль для человека (владелец 2026-10-18: «функционал cli и luci
// одинаковый», «улучшили luci, осталось cli»): ключ, включение и списки --
// одной командой, сводка на `byway` без доводов -- как «Основное» в панели,
// список команд -- по группам.

const C_OK = '\033[1;32m', C_WARN = '\033[1;33m', C_BAD = '\033[1;31m', C_DIM = '\033[2m', C_B = '\033[1m', C_0 = '\033[0m';


// Строка «команда — описание» с переносом описания по словам.
// opt -- уточнение (флаги, вторая форма) серым после описания.
// Подстановки в записи команды (ССЫЛКА, САЙТ, …) -- на языке интерфейса:
// кириллица в английской справке выглядела недосказанной (Ф9, п3-24, п3-44).
// Ключи словаря -- явными _t: lang-sync сверяет словарь с кодом по ним.
function c_ph(cmd) {
	let T = { 'ССЫЛКА': _t('ССЫЛКА'), 'САЙТ': _t('САЙТ'), 'АДРЕС': _t('АДРЕС'), 'ФАЙЛ': _t('ФАЙЛ'),
	          'ВЕРСИЯ': _t('ВЕРСИЯ'), 'ИМЯ': _t('ИМЯ'), 'ЗНАЧЕНИЕ': _t('ЗНАЧЕНИЕ') };
	return replace(cmd, /ССЫЛКА|САЙТ|АДРЕС|ФАЙЛ|ВЕРСИЯ|ИМЯ|ЗНАЧЕНИЕ/g, (m) => T[m]);
}

function c_help(cmd, txt, opt) {
	cmd = c_ph(cmd);
	let W = 78, I = 24, line;
	if (opt) txt += '  ' + C_DIM + opt + C_0;
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
// Экран для просмотра (help, list, keys, set) -- с чистого листа, только в
// терминале (BW_TTY от cli_uc); действия (add, key, on) печатают под командой.
function c_cls() { if (getenv('BW_TTY') == '1') print('\033[H\033[2J'); }
function c_group(t) { print('\n', C_B, t, C_0, '\n'); }

// Ключа нет -- по способу подключения, как у сборки (outbound.uc) и
// update.uc (up_idle): автовыбор берёт только список, остальные -- node_url.
// Прежде «есть ключ» считалось по любому из двух, и в автовыборе с пустым
// списком блок «С чего начать» пропадал, хотя сборка отказывала (Ф9, п4-52).
function c_nokey() {
	let m = u('conn_mode') || 'key';
	if (m == 'outbound') return trim(u('outbound_json')) === '';
	if (m == 'urltest') return !length(ul('node_urls'));
	return trim(u('node_url')) === '';
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
	// В автовыборе проба одного ключа проверяет node_url, а не ключи в
	// работе: совет -- проверить все и обновить подписку (Ф9, п3-11).
	if (u('conn_mode') == 'urltest' && (c_fail(seen, 'vpn') || c_fail(seen, 'tunnel')))
		push(out, _t('Ни один ключ автовыбора не даёт связи. Проверить все: byway probe --all; обновить ключи из подписки: byway key sub АДРЕС.'));
	else if (c_fail(seen, 'vpn'))
		push(out, _t("Связи с сервером VPN нет: ключ вставлен не целиком, устарел, или сервер выключен либо заблокирован. Проверить ключ: byway probe; если «НЕ РАБОТАЕТ», возьмите свежий ключ у сервиса VPN и впишите: byway key 'ССЫЛКА'."));
	// «Перехвата нет» -- не ключ, а правила: совет про ключ уводил не туда
	// (Ф9, прогон 5).
	else if (c_fail(seen, 'tunnel') && seen.tunnel.note == _t('перехвата нет: трафик дома идёт мимо туннеля'))
		push(out, _t('Правил перехвата нет, трафик дома идёт мимо туннеля. Поднять: byway plumb on; не помогло — /etc/init.d/byway restart и byway doctor.'));
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
	// Ширина -- по самой длинной подписи: английская длиннее 17 знаков, и
	// подпись слипалась с пояснением (Ф9, прогон 5).
	let w = 17;
	for (let c in c_checks()) if (c_len(c[1]) + 1 > w) w = c_len(c[1]) + 1;
	for (let c in c_checks()) {
		let v = seen[c[0]] ?? { st: 'warn', note: _t('нет данных') };
		let col = v.st == 'ok' ? C_OK : (v.st == 'fail' ? C_BAD : C_WARN);
		print('  ', col, '●', C_0, ' ', c_pad(c[1], w), C_DIM, v.note, C_0, '\n');
	}
	for (let a in c_advice(seen)) print('\n  ', C_BAD, '! ', C_0, a, '\n');
}

// bw_uc hfmt: строки health со входа -- для человека (byway health в терминале).
function cmd_hfmt() { c_health(fs.stdin.read('all')); }

// Каирн (знак на тропе) и имя: сверху сводки и help, чтобы не терялись среди команд.
// В терминале с 256 цветами -- полублоками, как logo.svg: буква карты -- цвет
// пикселя, две строки карты -- одна строка экрана. Иначе -- ASCII той же формы.
const CAIRN_PIX = [
	'..........HO........',
	'.........HOOOo......',
	'..........ooo.......',
	'......LLLL..........',
	'.....LMMMMMD........',
	'......DDDDD.........',
	'.......LLLLLLLL.....',
	'.....LMMMMMMMMMMD...',
	'......DDDDDDDDDD....',
	'..LLLLLLLLLLLLL.....',
	'LMMMMMMMMMMMMMMMMD..',
	'LMMMMMMMMMMMMMMMMMD.',
	'.DMMMMMMMMMMMMMMMD..',
	'...DDDDDDDDDDDD.....',
];
const CAIRN_PAL = { L: 253, M: 247, D: 240, H: 229, O: 214, o: 166 };
const CAIRN_ASC = [
	"          (__)'",
	"      .-'''''-.",
	"     (_.:::::._)'",
	"        .-'''''''-.",
	"       (_.:::::::._)'",
	"   .-''''''''''''''-.",
	"  (_.::::::::::::::._)'",
];
const LOGO_WORD = [
	'',
	'  _',
	" | |__  _   ___      ____ _ _   _",
	" | '_ \\| | | \\ \\ /\\ / / _` | | | |",
	' | |_) | |_| |\\ V  V / (_| | |_| |',
	' |_.__/ \\__, | \\_/\\_/ \\__,_|\\__, |',
	'        |___/               |___/',
];

function c_cairn_pix(y) {
	let top = CAIRN_PIX[y * 2], bot = CAIRN_PIX[y * 2 + 1], s = '';
	for (let x = 0; x < length(top); x++) {
		let t = CAIRN_PAL[substr(top, x, 1)], b = CAIRN_PAL[substr(bot, x, 1)];
		if (t == null && b == null) s += C_0 + ' ';
		else if (b == null) s += sprintf('\033[0;38;5;%dm▀', t);
		else if (t == null) s += sprintf('\033[0;38;5;%dm▄', b);
		else if (t == b) s += sprintf('\033[0;38;5;%dm█', t);
		else s += sprintf('\033[0;38;5;%d;48;5;%dm▀', t, b);
	}
	return s + C_0 + ' ';
}

function c_logo() {
	let pix = getenv('BW_TTY') == '1' && match(getenv('TERM') ?? '', /256color|truecolor|direct/);
	for (let y = 0; y < length(LOGO_WORD); y++) {
		let a = CAIRN_ASC[y];
		let cairn = pix ? c_cairn_pix(y)
		                : (y == 0 ? C_WARN : C_B) + a + C_0 + substr('                       ', 0, 23 - length(a));
		print(cairn, C_B, LOGO_WORD[y], C_0, '\n');
	}
}

// ── byway без доводов ─────────────────────────────────────────────────────
function cmd_home() {
	// В терминале -- с чистого экрана: сводка не смешивается с прежним выводом.
	c_cls();
	c_logo();
	print(C_B, 'byway ', getenv('BW_VERSION'), C_0, _t(' — раздельное туннелирование через VPN\n'));
	print(C_DIM, _t('Собрано задолго до рассвета'), C_0, '\n\n');
	if (c_nokey()) {
		if (u('conn_mode') == 'urltest') print(_t('  Выбран автовыбор, а список ключей пуст: взять ключи из подписки — byway key sub АДРЕС, либо один ключ, как в шаге 1.\n\n'));
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
	// В терминале -- сразу в меню по Enter: новичку не нужно помнить команды.
	// Из скрипта и ssh 'byway' (не терминал) -- ничего не спрашивается.
	if (getenv('BW_INTERACTIVE') != '1') { print('\n', _t('  Подробнее: byway help'), '\n'); return; }
	print('\n  ', C_B, 'Enter', C_0, _t(' — открыть меню'), '\n');
	print('  ', _t('или команда: '), C_B, 'list', C_0, ', ', C_B, 'help', C_0, _t(' — подробнее'), '\n');
	print('  ', C_B, 'q', C_0, _t(' — выйти'), '\n\n  › ');
	fs.stdout?.flush();
	let l = fs.stdin.read('line');
	// Enter -- меню; набранное -- команда (с «byway» и без него); q -- выход.
	let w = filter(split(trim(l ?? ''), /[ \t]+/), (x) => x != '');
	if (w[0] == 'byway') shift(w);
	if (l != null && !length(w)) sys([ m_self(), 'menu' ]);
	else if (length(w) && w[0] != 'q') sys([ m_self(), ...w ]);
}

// ── byway help ────────────────────────────────────────────────────────────
// Команды -- по предметам (ключ, списки, состояние); служебные -- только в
// `byway help all` (владелец 2026-10-18: «максимально просто»).
function cmd_help(all) {
	c_cls();
	c_logo();
	print(C_B, 'byway ', getenv('BW_VERSION'), C_0, _t(' — раздельное туннелирование через VPN\n'));
	print(C_DIM, _t('Собрано задолго до рассвета'), C_0, '\n');
	c_group(_t('Состояние'));
	c_help('byway', _t('сводка: служба, VPN, трафик, DNS'));
	c_help('status', _t('подробно, что работает'));
	c_help('doctor', _t('что не так и как исправить'), _t('--fix — починить'));
	c_help('on | off', _t('включить, выключить'));
	c_group(_t('Ключ'));
	c_help("key 'ССЫЛКА'", _t('вписать ключ и применить'), _t('в одинарных кавычках'));
	c_help('key', _t('какой ключ стоит'));
	c_help('keys', _t('все ключи'), _t('выбрать: key use N'));
	c_help('key sub АДРЕС', _t('ключи из подписки'));
	c_help('probe', _t('проверить ключ, не трогая туннель'), _t('--all — все'));
	c_group(_t('Списки'));
	c_help('list', _t('что идёт через VPN'));
	c_help('add САЙТ …', _t('добавить сайты или подсети'), _t('несколько через пробел'));
	c_help('del САЙТ …', _t('убрать'));
	c_help('list ready', _t('готовые списки'), _t('вкл.: list ready on ИМЯ'));
	c_help('mode lists|all', _t('по спискам или всё через VPN'));
	c_help('top', _t('чем пользуются на самом деле'));
	c_group(_t('Настройки'));
	c_help('set', _t('все настройки'), _t('изменить: set ИМЯ ЗНАЧЕНИЕ'));
	c_help('menu', _t('то же пунктами меню'));
	c_help('lang ru|en', _t('язык'));
	c_group(_t('Обслуживание'));
	c_help('update', _t('новая версия byway'), _t('--check, --rollback'));
	c_help('core', _t('ядро Xray-core'), _t('tested, ВЕРСИЯ'));
	c_help('export [ФАЙЛ]', _t('настройки в файл, без ключа'), _t('--with-key'));
	c_help('import ФАЙЛ', _t('настройки из файла'), _t('--no-key'));
	c_help('report', _t('отчёт для обращения, без ключа'));
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
	c_help('job update|engine|probe|gen|presets|restart|reload|import|log', _t('то же в фоне, ход в журнале (так зовёт панель)'));
	c_help('version', _t('версия'));
}

// ── ключ и включение ──────────────────────────────────────────────────────
// Применить: gen показывает, что собралось, reload службы перезапускает
// только при отличии (как «Сохранить и применить» в панели).
// Снимок настроек и своих списков до правки: сборка отказала -- правка
// уходит назад. Прежде значение оставалось записанным, хотя консоль
// говорила «работает прежняя настройка», и всплывало при следующей
// сборке (Ф9, п4-53).
let _snap = null;
function c_snap() {
	_snap = {};
	let L = getenv('BW_LISTS');
	for (let f in [ '/etc/config/byway', '/etc/config/' + KEY_PKG, L + '/domains.lst', L + '/subnets.lst' ]) {
		let st = fs.stat(f);
		_snap[f] = { t: fs.readfile(f), m: st ? st.mode & 0777 : null };
	}
}

// Вернуть снимок c_snap; ложь -- что-то не вернулось (нет места).
function c_restore() {
	let ok = true;
	for (let f, o in _snap ?? {}) {
		if (o.t == null) fs.unlink(f);
		else if (fs.readfile(f) !== o.t && !put_file(f, o.t, o.m)) ok = false;
	}
	_cur = null;
	return ok;
}

// Запись не легла (нет места): то, что успело записаться до неё, -- назад.
function c_nostore() {
	c_restore();
	exit(1);
}

function c_apply() {
	if (sys([ m_self(), 'gen' ]) != 0) {
		// Без ядра сборка отказывает при любой правке: ключ и настройки
		// тогда записываются впрок, до установки ядра.
		if (_snap && run([ 'test', '-x', xray_bin() ]).code == 0) {
			let ok = c_restore();
			if (!ok) die('не применилось, и прежняя настройка не вернулась (нет места?) — проверить: byway doctor');
			print('  ', C_BAD, _t('не применилось'), C_0, _t(' — правка отменена, работает прежняя настройка'), '\n');
			exit(1);
		}
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
	c_snap();
	if (!m_uci('node_url=' + url, 'conn_mode=key')) c_nostore();
	say('ключ записан, способ подключения — один ключ');
	c_apply();
}

// bw_uc on | off. Выключение -- остановкой службы: она снимает перехват и
// запрет «Не пускать», дом остаётся с интернетом без VPN.
function cmd_onoff(on) {
	if (!m_uci('enabled=' + (on ? '1' : '0'))) c_nostore();
	if (on) {
		run([ '/etc/init.d/byway', 'enable' ]);
		sys([ '/etc/init.d/byway', 'restart' ]);
		// Ядра нет -- «поднимается» было бы неправдой (Ф9, п3-28).
		if (run([ 'test', '-x', xray_bin() ]).code != 0) {
			warn('byway включён, но ядра Xray нет — служба не поднимется; что делать — строками выше');
			exit(1);
		}
		// Ждём движок до 15 с: не поднялся (адрес DNS занят, конфиг отвергнут)
		// -- сказать сразу, а не зелёным «включён» (Ф9, п3-57, прогон 5).
		// Движок, падающий на старте, procd поднимает снова: живым считаем pid,
		// переживший три секунды.
		// Счёт -- по часам: круг с проверкой pid длится 4 с, и 15 кругов
		// давали до минуты при тексте «за 15 секунд» (н1-9).
		let up = false, end = time() + 15;
		while (!up && time() < end) {
			let p = st_xray_pid();
			if (p !== '') { run([ 'sleep', '3' ]); up = st_xray_pid() == p; }
			if (!up) run([ 'sleep', '1' ]);
		}
		if (!up) {
			warn('byway включён, но движок не поднялся за 15 секунд — причина: byway doctor; журнал: logread -e xray');
			exit(1);
		}
		say('byway включён, движок работает; проверить: byway health');
		if (c_nokey()) warn("ключ не задан — вписать: byway key 'ССЫЛКА'");
	} else {
		// reload, а не stop: при enabled 0 он останавливает и заново
		// регистрирует службу в procd -- иначе «Включить» в панели потом
		// ничего не запускал (Ф9, п3-64).
		sys([ '/etc/init.d/byway', 'reload' ]);
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
			// Запятая разделяет записи, кроме regexp: -- в ней она часть
			// выражения ({2,3}); прежде запись резалась надвое (Ф9, п3-4).
			for (let w in split(ln, /[ \t\r]+/))
				for (let l in (substr(w, 0, 7) == 'regexp:' ? [ w ] : split(w, ','))) {
					l = trim(l);
					if (l !== '') push(out, l);
				}
		}
	}
	return out;
}

// Ссылка вида https://www.example.com/path -- имя сайта; регистр -- строчный.
function c_host(l) {
	// regexp: -- как написано: строчные меняли смысл (\D -> \d; Ф9, п4-50).
	if (substr(l, 0, 7) == 'regexp:') return l;
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
	// Первый файл пары уже мог лечь: снимок -- назад, иначе «прежний на
	// месте» было бы неправдой (н1-1).
	if (!put_file(f, t)) { if (_snap) c_restore(); dief('на флеше нет места: %s не записан, прежний на месте', f); }
	return true;
}

// bw_uc add ЗАПИСЬ … : проверка -- той же меркой, что при сборке (lj_entry),
// повторы -- мимо, в конце -- применить.
function cmd_add(...args) {
	let items = c_items(args);
	if (!length(items)) die('что добавить: byway add youtube.com instagram.com 91.108.4.0/22; список со ввода: byway add -');
	let cur = { domains: c_read('domains'), subnets: c_read('subnets') }, n = 0, bad = 0, add = { domains: [], subnets: [] };
	for (let raw in items) {
		let l = c_host(raw), k = c_kind(l);
		if (lj_entry(l, k == 'domains', '') == null) { print('  ', C_BAD, '✗', C_0, ' ', _f('не похоже ни на сайт, ни на подсеть: %s', raw), '\n'); bad++; continue; }
		if (index(cur[k], l) >= 0 || index(add[k], l) >= 0) { print('  ', C_DIM, '=', C_0, ' ', _f('уже есть: %s', l), '\n'); continue; }
		push(add[k], l);
		print('  ', C_OK, '+', C_0, ' ', l, C_DIM, k == 'subnets' ? _t('  (подсеть)') : '', C_0, '\n');
		n++;
	}
	// Ни одной годной записи -- отказ кодом 1; одни повторы -- не ошибка (Ф9, п3-23).
	if (!n) { print(_t('  добавлять нечего\n')); if (bad) exit(1); return; }
	c_snap();
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
	if (!n) { print(_t('  убирать нечего\n')); exit(1); }
	c_snap();
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
		// Мерка -- как у сборки (g_dns) и панели: https:// и tcp://.
		[ 'dns_upstream', 'r', '^(https|tcp)://[A-Za-z0-9._:/?=&%+-]+$', _t('DNS-сервер, шифрованный (DoH): https://…/dns-query') ],
		[ 'dns_upstream2', 'r', '^((https|tcp)://[A-Za-z0-9._:/?=&%+-]+|none)$', _t('запасной DNS-сервер; none — без запасного') ],
		[ 'dns_bootstrap', 'r', '^[0-9a-z.:/]+$', _t('DNS для имени DoH-сервера, если тот вписан именем') ],
		[ 'dns_route', 'e', 'direct tunnel', _t('путь к DNS-серверу: напрямую или через VPN') ],
		[ 'block_quic', 'f', '', _t('отказ QUIC для сайтов через VPN') ],
		[ 'router_via_vpn', 'f', '', _t('VPN для программ на самом роутере') ],
		[ 'ipv6', 'f', '', _t('IPv6 (экспериментально)') ],
		[ 'log_level', 'e', 'none error warning info debug', _t('подробность журнала ядра') ],
		[ 'probe_interval', 'r', '^[0-9]{1,4}[smh]$', _t('шаг проверки ключей в автовыборе: 3m, 30s') ],
		[ 'show_usage', 'f', '', _t('сбор статистики «чем пользуются»') ],
		[ 'lists_update', 'r', '^[0-9]{1,5}[mhd]?([0-9]{1,5}[mhd])*$', _t('период обновления готовых списков: 12h, 1d; 0 — только вручную') ],
		[ 'update_check', 'f', '', _t('проверка новых версий byway') ],
		[ 'auto_update', 'f', '', _t('автоматическая установка новых версий') ],
		[ 'auto_update_hour', 'r', '^([01]?[0-9]|2[0-3])$', _t('час автоматической установки, по часам роутера') ],
		[ 'guard', 'f', '', _t('восстановление перехвата раз в пять минут') ],
		// Мерка -- как у init (xray_memlimit): K, KB, T, TB он не понимал и
		// молча брал авто (Ф9, п4-30).
		[ 'xray_memlimit', 'r', '^(off|no|[0-9]{1,7}(MiB|GiB|TiB|MB|M|Mi|GB|G|Gi)?)$', _t('предел памяти ядра: 96, 128MiB; 0 — без предела') ],
		[ 'xray_root', 'f', '', _t('ядро от root — небезопасно') ],
		[ 'allow_insecure', 'f', '', _t('незащищённые ключи — небезопасно, соединение можно подменить') ],
		[ 'xray_bin', 'r', '^/[^ ]+$', _t('путь к ядру Xray; обычно его вписывает byway core') ],
		[ 'fakeip_pool', 'r', '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$', _t('пул подставных адресов') ],
		[ 'fakeip6_pool', 'r', '^[0-9a-fA-F:]+/[0-9]+$', _t('пул подставных адресов IPv6') ],
		[ 'dns_listen', 'r', '^127\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$', _t('адрес резолвера byway') ],
		[ 'tproxy_port', 'r', '^[0-9]{1,5}$', _t('порт перехвата') ],
		[ 'local_proxy_port', 'r', '^[0-9]{1,5}$', _t('порт прокси byway') ],
		// Метка -- только шестнадцатеричная: перехват и status читают её так,
		// десятичную молча заменяли умолчанием (Ф9, п3-9).
		[ 'mark', 'r', '^0x[0-9a-fA-F]{1,8}$', _t('метка пакетов') ],
		[ 'self_mark', 'r', '^(0x[0-9a-fA-F]{1,8}|[0-9]{1,10})$', _t('метка соединений ядра') ],
	];
}

// Флаг: да/нет любыми словами -> 1/0; не флаг -- null.
function c_flag(v) {
	// lc() кириллицу не опускает: заглавные -- списком (Ф9, п4-31).
	v = lc(v);
	if (index([ '1', 'on', 'yes', 'true', 'да', 'Да', 'ДА', 'вкл', 'Вкл', 'ВКЛ' ], v) >= 0) return '1';
	if (index([ '0', 'off', 'no', 'false', 'нет', 'Нет', 'НЕТ', 'выкл', 'Выкл', 'ВЫКЛ' ], v) >= 0) return '0';
	return null;
}

function c_uci(cmd) { return run([ 'uci', '-q', ...cmd ]).code == 0; }

// Записать настройку: значение (или список) и commit; курсор -- заново.
function c_store(name, vals, list) {
	// Ключи -- в своём пакете (Ф9, п1-12).
	let pk = opt_pkg(name);
	if (pk == KEY_PKG && !key_ensure()) die('на флеше нет места: настройка не записана, прежняя на месте');
	uci_fresh(pk);
	c_uci([ 'delete', pk + '.main.' + name ]);
	if (list) { for (let v in vals) c_uci([ 'add_list', pk + '.main.' + name + '=' + v ]); }
	else if (length(vals)) c_uci([ 'set', pk + '.main.' + name + '=' + vals[0] ]);
	if (!uci_commit(pk)) die('на флеше нет места: настройка не записана, прежняя на месте');
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
		c_cls();
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
	// «default» -- значение поставки (etc-config-byway). Стёртую опцию код
	// читает как «выключено», а поставка эти три включает: default выключал
	// их (Ф9, п3-1). У остальных умолчание кода и поставки совпадают.
	let SHIPPED = { router_via_vpn: '1', ru_direct: '1', mux_concurrency: '8' };
	if (length(rest) == 1 && rest[0] == 'default') vals = SHIPPED[name] != null ? [ SHIPPED[name] ] : [];
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
		// Предел в байтах и КиБ и меньше 16 МиБ -- сборка мусора без остановки,
		// движок стоит (прогон 5).
		if (name == 'xray_memlimit') {
			let mm = match(vals[0], /^([0-9]+)(MiB|MB|M|Mi)?$/);
			if (mm && int(mm[1]) != 0 && int(mm[1]) < 16) dief('предел памяти %s слишком мал: меньше 16 МиБ ядро только собирает мусор — 0 или от 16', vals[0]);
			// Ноль с единицей init читал как предел 0 байт, а не «без
			// предела» (н1-6): любой ноль -- ровно «0».
			if (match(vals[0], /^0+[A-Za-z]*$/)) vals = [ '0' ];
		}
		// Та же мерка, что у сборки и перехвата: принятое здесь потом молча
		// заменялось умолчанием (н1-5).
		if (name == 'dns_bootstrap' && !match(vals[0], G_BOOT_RE)) dief('значение «%s» не годится для %s', vals[0], name);
		if (name == 'fakeip_pool' && (!match(vals[0], G_POOL_RE) || !g_pool_sane(vals[0], true))) dief('значение «%s» не годится для %s', vals[0], name);
		if (name == 'fakeip6_pool' && !g_pool6_ok(vals[0])) dief('значение «%s» не годится для %s', vals[0], name);
		if (name == 'self_mark') {
			let n = pl_num(vals[0]);
			if (n == null || n <= 0 || n > 4294967295) dief('значение «%s» не годится для %s', vals[0], name);
		}
		if (name == 'mark' && hex(substr(vals[0], 2)) == 0) die('метка 0 не годится: ip rule с ней ловит весь трафик роутера');
		if (name == 'dns_listen' && vals[0] == '127.0.0.1') die('127.0.0.1 занят dnsmasq — нужен другой адрес петли, например 127.0.0.42');
		// Порт 0 nft принимал как «tproxy to :0», 99999 -- отвергал всю
		// таблицу; set при этом говорил «применено» (Ф9, п3-17).
		if ((name == 'tproxy_port' || name == 'local_proxy_port') && !g_port_ok(vals[0])) dief('порт — от 1 до 65535: %s', vals[0]);
		// Мост, которого нет: правила ложились, проверки зелёные, а перехвата
		// у сети нет (Ф9, п3-58). Не отказ: мост гостевой сети поднимается позже.
		if (name == 'interface')
			for (let i in vals)
				if (!fs.stat('/sys/class/net/' + i)) warnf('устройства %s сейчас нет — проверьте имя: ip link', i);
	}
	c_snap();
	c_store(name, vals, s[1] == 'l');
	print('  ', C_B, name, C_0, ' = ', c_show_val(name, s[1]), '\n');
	c_apply();
}

// ── ключи ────────────────────────────────────────────────────────────────
function c_keylist() {
	let v = u_raw('node_urls');
	if (v == null) return [];
	return type(v) == 'array' ? v : [ v ];
}

// Ключ одной строкой: схема, сервер, имя -- uuid и пароль не печатаются.
// Схема, сервер и имя -- тем же разбором, что у сборки: имя -- после первой
// «#», а ss и vmess в base64 печатались целиком, с паролем и uuid (Ф9, п4-1).
function c_keyshort(k) {
	let R = parse_key(k, '', ''), name = R.label || (R.N?.PS ?? '');
	if (!R.fatal && R.N.HOST !== '')
		return R.scheme + '://…@' + R.N.HOST + ':' + R.N.PORT + (name !== '' ? ' · ' + name : '');
	let m = match(k, /^([a-z0-9+.-]+):\/\//);
	return (m ? m[1] + '://…' : '…') + (name !== '' ? ' · ' + name : '');
}

// byway keys: список с номерами, активный отмечен.
// Список без очистки экрана: `key sub` печатает его под своими
// предупреждениями, и c_cls их стирал (н1-7).
function c_keys_print() {
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

function cmd_keys() {
	c_cls();
	c_keys_print();
}

// byway key use N: активный -- N-й из списка; способ -- «несколько вручную».
function c_key_use(n) {
	// «2abc» int() читал как 2: только цифры (Ф9, п4-62).
	let L = c_keylist(), i = match(n ?? '', /^[0-9]{1,4}$/) ? int(n) : 0;
	// Один ключ без списка: `byway keys` показывает его под номером 1 (Ф9, п3-18).
	if (!length(L) && u('node_url') !== '' && i == 1) { say('ключ один и уже активный'); return; }
	if (!length(L)) die("в списке ключей пусто — сначала: byway key sub АДРЕС или byway key 'ССЫЛКА'");
	if (!(i >= 1 && i <= length(L))) dief('номер ключа — от 1 до %s: byway keys', length(L));
	c_snap();
	if (!m_uci('node_url=' + L[i - 1], 'conn_mode=selector')) c_nostore();
	sayf('активный ключ: %s', c_keyshort(L[i - 1]));
	c_apply();
}

// byway key sub АДРЕС: ключи подписки -- в список, активный остаётся, если
// он есть среди них, иначе первый; способ -- «несколько вручную», если не
// был выбран автовыбор (он остаётся).
function c_key_sub(url) {
	// Без адреса -- из файла (меню) или сохранённый: в командной строке он
	// виден другим процессам роутера (н1-12).
	if (!url) { url = trim(fs.readfile(PS_SUB_FILE) ?? ''); fs.unlink(PS_SUB_FILE); }
	if (!url) url = u('sub_url');
	if (!url) die('byway key sub АДРЕС — адрес подписки https://…');
	// Адрес -- файлом root: окружение дочернего процесса шло через `sh -c`,
	// и строка с адресом висела в /proc/*/cmdline на всё время загрузки (Ф9, п1-4; н1-12).
	if (!put_file(PS_SUB_FILE, url + '\n', 0600)) die('в /var/run нет места — подписка не загружена');
	let r = run([ m_self(), 'sub' ], true);
	fs.unlink(PS_SUB_FILE);
	// Тело чужого ответа -- в терминал без управляющих знаков и коротко (Ф9,
	// п2-30); отказ скачивания -- отказ команды, а не «ключей нет».
	// ESC (\x1b) -- тоже: через него CSI и OSC доходили до терминала (Ф9, п2-30, прогон 5).
	let shown = substr(replace(r.out, /[\x01-\x08\x0b-\x1f\x7f]/g, ''), 0, 600);
	if (r.code != 0) { print(shown, '\n'); die('подписка не принята — настройки не изменены'); }
	// Каждый ключ -- через разбор, как `byway key`: негодный первым вставал
	// активным, и туннель ложился (Ф9, п1-14).
	let keys = [], bad = 0;
	for (let l in split(r.out, '\n')) {
		l = trim(l);
		// BOM в начале подписки: панель ключ брала, консоль теряла (Ф9, п4-68).
		if (substr(l, 0, 3) == '\xef\xbb\xbf') l = substr(l, 3);
		// Схема -- строчными, как у разбора: «VLESS://» сборка не берёт (п4-67).
		let m = match(l, /^([a-z0-9+.-]+):\/\//);
		if (!m || index([ 'vless', 'vmess', 'trojan', 'ss', 'socks', 'hysteria2', 'hy2', 'wireguard', 'wg' ], m[1]) < 0) continue;
		if (parse_key(l, '', '').fatal) { bad++; continue; }
		push(keys, l);
	}
	if (bad) warnf('ключей не разобрано и пропущено: %s', bad);
	if (!length(keys)) { print(shown, '\n'); die('ключей в подписке не нашлось — настройки не изменены'); }
	// Активный -- прежний; сервис сменил ему имя (#метка) -- тот же по
	// остальной ссылке, а не первый попавшийся (Ф9, п3-5).
	let cur = u('node_url'), act = null;
	if (index(keys, cur) >= 0) act = cur;
	else for (let k in keys) if (act == null && cur !== '' && pk_before(k, '#') == pk_before(cur, '#')) act = k;
	if (act == null) {
		act = keys[0];
		if (cur !== '') warn('прежнего ключа в подписке нет — активным стал первый');
	}
	c_snap();
	c_store('node_urls', keys, true);
	if (!m_uci('node_url=' + act, 'sub_url=' + url, (u('conn_mode') == 'urltest' ? 'conn_mode=urltest' : 'conn_mode=selector'))) c_nostore();
	sayf('ключей из подписки: %s', length(keys));
	c_keys_print();
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
	else if (m != 'urltest') print('  ', c_keyshort(u('node_url') || c_keylist()[0]), '\n');
	print('\n');
	// Автовыбор: в работе все ключи списка, а не node_url (Ф9, п3-11).
	if (m == 'urltest') sys([ 'env', 'BW_TTY=1', m_self(), 'probe', '--all' ]);
	else sys([ 'env', 'BW_TTY=1', m_self(), 'probe' ]);
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
		c_cls();
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
	c_snap();
	c_store('preset', P, true);
	// Не скачался -- подключение остаётся (автообновление повторит), но
	// команда отвечает отказом, а не «применено» (Ф9, п3-25).
	let pr = act == 'on' ? sys([ m_self(), 'presets' ]) : 0;
	c_apply();
	if (pr != 0) {
		// GitHub закрыт по IP: первая загрузка идёт мимо туннеля, повтор тем
		// же путём не поможет (н1-8).
		warn('список подключён, но не скачан — если GitHub недоступен напрямую: byway add githubusercontent.com, затем byway presets');
		exit(1);
	}
}

function cmd_list(what, ...rest) {
	if (what == 'domains' || what == 'subnets') {
		for (let l in c_read(what)) print(l, '\n');
		return;
	}
	if (what == 'ready') return c_ready(rest[0], slice(rest, 1));
	if (what) dief('byway list [domains|subnets|ready] — не %s', what);
	c_cls();
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
		// Без довода -- показать режим; неизвестный довод -- отказ (Ф9, п3-23).
		if (m != null && m !== '') dief('режим — lists или all: %s', m);
		print('  ', _t('Режим: '), C_B, u('list_mode') == 'all' ? _t('всё через VPN') : _t('по спискам'), C_0, '\n');
		print(_t('  byway mode lists — через VPN только списки; byway mode all — весь трафик\n'));
		return;
	}
	c_snap();
	if (!m_uci('list_mode=' + m)) c_nostore();
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
	// Порог от длины слова: у коротких два правки -- уже другое слово
	// («foo», «qq» -> «on»; Ф9, п3-26).
	// До трёх букв -- без подсказки: «ons» -> «on» тоже было мимо (прогон 5).
	let wl = length(w ?? '');
	if (best && wl > 3 && bd <= (wl <= 4 ? 1 : 2)) printf(_t('byway: нет команды «%s». Может быть: byway %s\n'), w, best);
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
	let cr = run([ 'crontab', '-l' ]).out, add = '', cc = dr_cron();
	if (!cc.watch) add += '*/5 * * * * /usr/local/bin/byway watch >/dev/null 2>&1\n';
	if (!cc.stat) add += '7 * * * * /usr/local/bin/byway stat >/dev/null 2>&1\n';
	if (!cc.pulse) add += '* * * * * /usr/local/bin/byway pulse >/dev/null 2>&1\n';
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
