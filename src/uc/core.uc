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

// Как `uci -q get byway.main.X`: незаданное -- пустая строка, список --
// через пробел.
function u(opt) {
	let v = cursor().get('byway', 'main', opt);
	if (v == null) return '';
	return type(v) == 'array' ? join(' ', v) : '' + v;
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
	if (substr(rindex(f, '/') >= 0 ? substr(f, rindex(f, '/') + 1) : f, 0, 4) != 'xray') return false;
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
		if (s && s.type == 'file' && (s.mode & 73)) warnf('путь к движку отклонён: %s', x);
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
