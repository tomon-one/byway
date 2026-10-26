// Каркас части byway на ucode: настройки (UCI), перевод, вывод и журнал,
// запуск программ. Опора -- только модули fs и uci: на 22.03 других нет.

let fs = require('fs');
let uci = require('uci');

// Встроенный die бросает исключение; имя die ниже занимает вывод «[x]» с
// выходом. Объявления функций не поднимаются: здесь ещё встроенный.
const raise = die;

const LISTS = '/etc/byway';

// ── настройки ──────────────────────────────────────────────────────────────
// Один курсор на запуск: каждый `u` в shell -- отдельный процесс uci.
// BW_UCI_DIR -- подставной каталог конфигов для стендов (как подменённый u).
let _cur = null;
function cursor() {
	if (_cur == null) {
		let d = getenv('BW_UCI_DIR');
		_cur = d ? uci.cursor(d) : uci.cursor();
	}
	return _cur;
}

// Ключи -- отдельным пакетом UCI byway_key (600): роль панели «только
// чтение» получала через `uci: ["byway"]` весь byway.main, с ключом и
// подпиской (Ф9, п1-12). Её права byway_key не включают.
const KEY_PKG = 'byway_key';
const KEY_OPTS = [ 'node_url', 'node_urls', 'sub_url', 'outbound_json' ];
function opt_pkg(opt) { return index(KEY_OPTS, opt) >= 0 ? KEY_PKG : 'byway'; }

// Значение: ключи -- из byway_key, а пока перенос не случился (нет места,
// подставной каталог) -- из byway.
function u_raw(opt) {
	let c = cursor(), v = c.get(opt_pkg(opt), 'main', opt);
	if (v == null && opt_pkg(opt) == KEY_PKG) v = c.get('byway', 'main', opt);
	return v;
}

// Как `uci -q get byway.main.X`: незаданное -- пустая строка, список --
// через пробел.
function u(opt) {
	let v = u_raw(opt);
	if (v == null) return '';
	return type(v) == 'array' ? join(' ', v) : '' + v;
}

// Списочная опция массивом: u() склеивает список через пробел, и ключ с
// пробелом в метке («#Node 2 EU») резался на части (Ф9, п3-34). Строка (опция
// прежних версий) -- по словам.
function ul(opt) {
	let v = u_raw(opt);
	if (v == null) return [];
	if (type(v) == 'array') return filter(map(v, (x) => trim(x)), (x) => x !== '');
	return filter(split(trim('' + v), /[ \t\n]+/), (x) => x !== '');
}

// ── перевод ────────────────────────────────────────────────────────────────
// Словарь тот же, что у shell: lang/<язык>.tsv, «ключ<TAB>перевод». Ключ --
// русская строка как в shell-коде, то есть с \n и \t двумя знаками; здесь
// строки уже с настоящими переводами строки, поэтому при поиске они
// записываются обратно, а в переводе -- раскрываются.
let LANG = getenv('BW_LANG') || u('lang');
if (!match(LANG, /^[a-z][a-z]$/)) LANG = 'ru';
let _dict = null;

// Ключи и переводы словаря пишут \n, \t и \033 (ESC) текстом, как в shell.
function _unesc(s) {
	return replace(replace(replace(s, '\\n', '\n'), '\\t', '\t'), '\\033', '\033');
}

function _t(s) {
	if (LANG == 'ru') return s;
	if (_dict == null) {
		_dict = {};
		for (let l in split(fs.readfile(LISTS + '/lang/' + LANG + '.tsv') ?? '', '\n')) {
			let i = index(l, '\t');
			if (i > 0) _dict[substr(l, 0, i)] ??= substr(l, i + 1);
		}
	}
	let v = _dict[replace(replace(replace(s, '\n', '\\n'), '\t', '\\t'), '\033', '\\033')];
	return v == null ? s : _unesc(v);
}

// Формат с подстановками, как shell printf: недостающие доводы -- пустые
// строки (sprintf печатал бы «(null)»).
function _pf(fmt, args) {
	let n = length(match(fmt, /%[^%]/g) ?? []);
	let a = [ ...args ];
	while (length(a) < n) push(a, '');
	return sprintf(fmt, ...a);
}

function _f(fmt, ...args) { return _pf(_t(fmt), args); }

// ── вывод и журнал ─────────────────────────────────────────────────────────
// Те же знаки и цвета, что у shell (core/output.sh): вывод разбирают панель
// и человек, по [*] [!] [x].
// PLAIN -- без цветов (отчёт: уходит файлом постороннему).
let PLAIN = false;
function _mark(c, m) { return PLAIN ? m + ' ' : '\x1b[1;' + c + 'm' + m + '\x1b[0m '; }
function _say(s)   { print(_mark(32, '[*]'), s, '\n'); }
// WARN_ERR -- жалобы в stderr (byway nft: вывод идёт прямо в `nft -f`).
let WARN_ERR = null;
function _warn(s)  {
	if (WARN_ERR) WARN_ERR.write(_mark(33, '[!]') + s + '\n');
	else print(_mark(33, '[!]'), s, '\n');
}
function die_raw(s) { print(_mark(31, '[x]'), s, '\n'); exit(1); }

function say(s)  { _say(_t(s)); }
function warn(s) { _warn(_t(s)); }
function die(s)  { die_raw(_t(s)); }
function sayf(fmt, ...a)  { _say(_pf(_t(fmt), a)); }
function warnf(fmt, ...a) { _warn(_pf(_t(fmt), a)); }
function dief(fmt, ...a)  { die_raw(_pf(_t(fmt), a)); }

// Журнал системы -- logger со списком доводов, без оболочки: текст из
// настроек и ключей в командную строку не попадает.
function logt(s)          { system([ 'logger', '-t', 'byway', _t(s) ]); }
function logf(fmt, ...a)  { system([ 'logger', '-t', 'byway', _pf(_t(fmt), a) ]); }

// rindex на ucode 22.03/23.05 (до 2024-11-29) отвечает -1, когда последнее
// совпадение стоит в позиции 0: «\n000» от curl читался как «нет перевода
// строки», и проверка обновлений бросала цепочку прокси -> напрямую -> DoH
// на первом шаге (Ф9, п1-5, п2-9, п2-11). Все вызовы -- через эту.
function rpos(s, c) {
	let i = rindex(s, c);
	return (i < 0 && length(c) && substr(s, 0, length(c)) == c) ? 0 : i;
}

// ── запуск программ ────────────────────────────────────────────────────────
// popen принимает только строку для оболочки: каждый довод -- в одинарных
// кавычках.
function q(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }

// system() со сбросом своего вывода: иначе при выводе в файл (панель, job)
// строки byway шли бы после вывода дочерней программы.
function sys(argv) {
	fs.stdout?.flush();
	return system(argv);
}

// Вывод и код выхода программы; stderr -- вместе с выводом, если err.
function run(argv, err) {
	let p = fs.popen(join(' ', map(argv, q)) + (err ? ' 2>&1' : ' 2>/dev/null'), 'r');
	if (!p) return { code: 127, out: '' };
	let out = p.read('all') ?? '';
	return { code: p.close(), out: out };
}

// ── запись настроек UCI ────────────────────────────────────────────────────
// `uci commit` при полном флеше возвращает 0 и подменяет файл пустым: libuci
// пишет во временный файл, не глядя на ошибки записи, и переименовывает его
// поверх (Ф9, п2-35: так пропадал ключ VPN, а с dhcp и firewall -- сеть дома).
// Поэтому место проверяется до записи, файл сверяется после, и испорченный
// возвращается из копии в памяти: место прежнего файла к тому времени свободно.
// Ложь -- не записано; несохранённая правка снимается, чтобы её не унёс
// следующий чужой commit.
function uci_commit(pkg) {
	let f = '/etc/config/' + pkg, old = fs.readfile(f), sz = length(old ?? '');
	let df = split(split(run([ 'df', '-k', '/etc/config' ]).out, '\n')[1] ?? '', /[ \t]+/);
	if (df[3] != null && match(df[3], /^[0-9]+$/) && int(df[3]) * 1024 < sz + 65536) {
		run([ 'uci', '-q', 'revert', pkg ]);
		return false;
	}
	let ok = run([ 'uci', '-q', 'commit', pkg ]).code == 0;
	if (sz > 0 && !length(fs.readfile(f) ?? '')) {
		run([ 'uci', '-q', 'revert', pkg ]);
		if (fs.writefile(f + '.bw-new', old) == sz && fs.rename(f + '.bw-new', f)) return false;
		fs.unlink(f + '.bw-new');
		// Вернуть не вышло: копия -- в памяти до перезагрузки, путь -- человеку.
		fs.writefile('/var/run/byway-' + pkg + '.uci', old);
		warnf('файл %s испорчен нехваткой места, копия — %s: освободить флеш и вернуть её на место', f, '/var/run/byway-' + pkg + '.uci');
		return false;
	}
	_cur = null;
	return ok;
}

// Чужая незаписанная правка пакета (приём, убитый kill -9; `uci set` без
// commit) уехала бы во флеш вместе с нашей: сказать и снять (Ф9, прогон 5).
function uci_fresh(pkg) {
	let ch = trim(run([ 'uci', '-q', 'changes', pkg ]).out);
	if (ch === '') return;
	warnf('в %s была незаписанная правка (%s строк) — снята, записывается только эта команда', pkg, length(split(ch, '\n')));
	run([ 'uci', '-q', 'revert', pkg ]);
	_cur = null;
}

// Файл целиком: во временный рядом, сверка длины, потом на место. При нехватке
// места fs.writefile пишет, сколько влезло, и молчит: обрезанный список вставал
// на место рабочего (Ф9, п2-3…п2-5). Ложь -- рабочий файл не тронут.
function put_file(f, t, mode) {
	let n = f + '.new';
	if (fs.writefile(n, t) !== length(t)) { fs.unlink(n); return false; }
	if (mode != null) fs.chmod(n, mode);
	if (!fs.rename(n, f)) { fs.unlink(n); return false; }
	return true;
}

// Число из строки (метки: plumb, set, doctor), как арифметика оболочки: 0x -- шестнадцатеричное, ведущий
// ноль -- восьмеричное; негодное -- null.
function pl_num(s) {
	if (substr(s, 0, 2) == '0x' || substr(s, 0, 2) == '0X') return hex(substr(s, 2));
	if (length(s) > 1 && substr(s, 0, 1) == '0') {
		if (ltrim(s, '01234567') !== '') return null;
		let n = 0;
		for (let i = 1; i < length(s); i++) n = n * 8 + int(substr(s, i, 1));
		return n;
	}
	return int(s);
}

// Пакет ключей: файл с секцией main, права 600 -- до первой записи в него.
function key_ensure() {
	let d = getenv('BW_UCI_DIR') || '/etc/config', f = d + '/' + KEY_PKG;
	if (!fs.stat(f) && !put_file(f, "\nconfig key 'main'\n", 0600)) return false;
	fs.chmod(f, 0600);
	if (cursor().get(KEY_PKG, 'main') == null) {
		run([ 'uci', '-q', ...(getenv('BW_UCI_DIR') ? [ '-c', d ] : []), 'set', KEY_PKG + '.main=key' ]);
		if (!uci_commit(KEY_PKG)) return false;
	}
	return true;
}

// Перенос ключей из byway в byway_key (прежние версии, откат и возврат).
// Сперва пишется byway_key, потом стирается в byway: нехватка места оставляет
// ключ на прежнем месте, а не нигде. Действующий ключ запись в byway не
// заменяет: роль панели без права на ключ пишет в byway (н1-11). Отвергнутое
// -- вслух, а не молча (н1-2).
function key_move() {
	if (getenv('BW_UCI_DIR')) return;
	let c = cursor(), have = [];
	for (let o in KEY_OPTS) if (c.get('byway', 'main', o) != null) push(have, o);
	if (!length(have) || !key_ensure()) return;
	c = cursor();
	for (let o in have) {
		let v = c.get('byway', 'main', o), k = c.get(KEY_PKG, 'main', o);
		if (k == null || k == '') c.set(KEY_PKG, 'main', o, v);
		else if (sprintf('%J', k) != sprintf('%J', v)) {
			// И в журнал: первым запись часто видит cron (watch, pulse).
			warnf('в byway.main.%s вписано значение, отличное от действующего, — оно не принято и убрано: ключ меняется командой byway key или в панели', o);
			logf('в byway.main.%s вписано значение, отличное от действующего, -- не принято и убрано', o);
		}
	}
	// save() без довода: save('byway') на ucode 22.03 отвечает «Invalid argument».
	if (!c.save() || !uci_commit(KEY_PKG)) { run([ 'uci', '-q', 'revert', KEY_PKG ]); _cur = null; return; }
	c = cursor();
	for (let o in have) c.delete('byway', 'main', o);
	if (!c.save() || !uci_commit('byway')) run([ 'uci', '-q', 'revert', 'byway' ]);
	_cur = null;
}

// Часы роутера раньше 2024 года -- не выставлены (NTP не дошёл): сертификаты
// GitHub для curl «ещё не действуют» (код 60), а ядро Xray 26.10 на часах до
// 2012 падает при старте. byway говорил «не скачалось» и «путь к движку
// отклонён», не называя причину (Ф9, п2-12, п2-14).
function clock_bad() { return time() < 1704067200; }
function clock_say() {
	if (clock_bad())
		warnf('часы роутера показывают %s — проверка сертификатов не пройдёт, ядро Xray может не запуститься: дождаться синхронизации времени (NTP) или выставить его', trim(run([ 'date', '+%Y-%m-%d %H:%M' ]).out));
}

// ── колонки в терминале ───────────────────────────────────────────────────
// Длина в знаках, а не байтах: русская подпись иначе сдвигала колонку.
// Коды цвета (ESC [ … m) места не занимают.
function c_len(s) {
	let n = 0, esc = false;
	for (let i = 0; i < length(s); i++) {
		let c = ord(s, i);
		if (esc) { if (c == 109) esc = false; continue; }
		if (c == 27) { esc = true; continue; }
		if ((c & 0xC0) != 0x80) n++;
	}
	return n;
}
function c_pad(s, w) { let n = w - c_len(s); return n > 0 ? s + sprintf('%' + n + 's', '') : s; }

// ── движок ─────────────────────────────────────────────────────────────────
// Путь к Xray -- из UCI (xray_bin): рядом пакетный и свежий ручной, переключение
// одной опцией. Значение пишет панель, а запускает root: без проверки нельзя
// (так устроены CVE luci-app-travelmate и samba4; валидатор панели не защита).
// Порядок: каталог (в системные пишет только root), исполняемость, имя xray*
// и ELF -- и лишь затем запуск: xray_bin=/sbin/reboot с панели перезагружал
// роутер на каждом вызове byway. Проверка -- только у команд, которым нужен
// движок: `xray version` стоит ~0,05 с на роутере (2026-10-18).
function x_ok(f) {
	if (!match(f, /^\/(usr\/bin|usr\/sbin|usr\/local\/bin|bin|sbin)\//) || index(f, '..') >= 0) return false;
	let s = fs.stat(f);
	if (!s || s.type != 'file' || !(s.mode & 73)) return false;
	if (substr(rpos(f, '/') >= 0 ? substr(f, rpos(f, '/') + 1) : f, 0, 4) != 'xray') return false;
	let h = fs.open(f, 'r'), b = h ? h.read(4) : '';
	if (h) h.close();
	if (index(b ?? '', 'ELF') < 0) return false;
	return match(split(run([ f, 'version' ]).out, '\n')[0] ?? '', /^Xray /i) != null;
}

// BW_GEN_XRAY -- замена ядра собирает конфиг под НОВЫМ движком (uc/engine.uc).
// Негодный xray_bin -- жалоба в stderr (вывод разбирают панель и nft) и
// движок из PATH.
let X_BIN = null, X_VER = null;
function xray_bin() {
	if (X_BIN != null) return X_BIN;
	X_BIN = getenv('BW_GEN_XRAY') ?? '';
	if (X_BIN !== '') return X_BIN;
	let x = u('xray_bin');
	if (x !== '' && x_ok(x)) return X_BIN = x;
	if (x !== '') {
		let s = fs.stat(x), e = WARN_ERR;
		WARN_ERR = fs.stderr;
		// Файла нет или у него нет права запуска -- не «отклонён» (Ф-13).
		if (s && s.type == 'file' && (s.mode & 73)) { warnf('путь к движку отклонён: %s', x); clock_say(); }
		else warnf('движок не найден или не исполняемый: %s', x);
		WARN_ERR = e;
	}
	for (let d in split(getenv('PATH') ?? '', ':')) {
		let s = d !== '' ? fs.stat(d + '/xray') : null;
		if (s && s.type == 'file' && (s.mode & 73)) return X_BIN = d + '/xray';
	}
	return X_BIN = '/usr/bin/xray';
}

// Версия движка числом: 26.7.28 -> 260728, 1.8.3 -> 10803 -- нумерация Xray
// менялась, сравнение по числам её переживает. Нужна, потому что Go молча
// отбрасывает незнакомые поля JSON, и `run -test` старого Xray (1.8.3 на
// OpenWrt 22.03) принимает конфиг с потерянным полем. Не определилась --
// считаем современной, старую форму не пишем.
function _xv_n(s) { return match(s ?? '', /^[0-9]+$/) ? int(s) : 0; }
function xray_ver() {
	if (X_VER != null) return X_VER;
	let v = replace(split(split(run([ xray_bin(), 'version' ]).out, '\n')[0], ' ')[1] ?? '', /[^0-9.]/g, '');
	let p = split(v, '.');
	X_VER = v === '' ? 999999 : _xv_n(p[0]) * 10000 + _xv_n(p[1]) * 100 + _xv_n(p[2]);
	return X_VER;
}
