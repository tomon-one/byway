// Записи списков -> строки JSON-массива (бывший list_to_json): та же форма
// записи, что прежде. Файл читается по строке и пишется в конфиг сразу: на
// потолке пресета (200 000 доменов) список в памяти занял бы десятки МБ рядом
// с движком.

// Строка из списка попадает в конфиг как есть, поэтому для домена -- только
// буквы, цифры, точка и дефис, последняя часть -- не короче двух букв либо
// xn--; кавычки и обратной косой в наборе нет, выйти из строки JSON нечем.
// regexp: -- единственная форма, где они законны: экранируются по JSON.
// geosite: и ext: требуют файла данных, которого byway не поставляет: Xray
// без него не стартует вовсе. Отброшенное -- строкой в bad.
// [[:space:]] awk: пробел, \t, \n, \r, \v, \f.
const WS = ' \t\n\r\x0b\x0c';
const ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const ALNUM = ALPHA + '0123456789';

// Только знаки из набора: ltrim снимает их все -- остаётся пусто.
function _only(s, set) { return ltrim(s, set) === ''; }

// Домен без регулярок: match() в ucode стоит ~8 мкс на вызов даже на
// простейшем выражении (стенд 2026-10-16; на роутере 200 000 строк -- 61 с
// против 17 у awk), а ltrim/index работают на C. Равносильно паре
//   ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$  и
//   \.([A-Za-z][A-Za-z]+|xn--[A-Za-z0-9-]+)$
// плюс отказ на «..» (dots -- без него: так судит lj_plain).
function _domain_ok(v, dots) {
	let n = length(v);
	if (!n || !_only(v, ALNUM + '.-') || index(ALNUM, substr(v, 0, 1)) < 0 ||
	    index(ALNUM, substr(v, n - 1, 1)) < 0 || (!dots && index(v, '..') >= 0))
		return false;
	let d = rpos(v, '.');
	if (d < 0) return false;
	// Метка длиннее 63 знаков: dnsmasq отвергал запрет доменов целиком, а
	// ожидание движка висело на пробе (Ф9, п4-36).
	for (let x in split(v, '.')) if (length(x) > 63) return false;
	let tld = substr(v, d + 1);
	if (length(tld) >= 2 && _only(tld, ALPHA)) return true;
	return substr(tld, 0, 4) == 'xn--' && length(tld) > 4 && _only(substr(tld, 4), ALNUM + '-');
}

// Число из цифр больше предела -- как awk «x + 0 > n»: int() на двадцати
// цифрах переполняется, и 999999999999999999999.1.1.1 проходил бы.
function _numgt(s, lim) {
	s = ltrim(s, '0');
	return length(s) > 3 || (s !== '' && int(s) > lim);
}

// Число строго: цифры, без ведущего нуля (кроме самого «0»), не больше lim.
// «091» nft разбирал как имя хоста и отвергал всю таблицу, «010» молча
// читал восьмеричным 8, а Xray отвергал весь конфиг (Ф9, п4-35, п4-44).
function lj_num(x, lim) {
	return x !== '' && _only(x, '0123456789') && (length(x) == 1 || substr(x, 0, 1) != '0') && !_numgt(x, lim);
}

// a.b.c.d (net -- и a.b.c.d/n). Одна мерка для сборки и для nft.
function lj_v4_ok(l, net) {
	let s = index(l, '/'), a = s < 0 ? l : substr(l, 0, s);
	if (s >= 0 && (!net || !lj_num(substr(l, s + 1), 32))) return false;
	let o = split(a, '.');
	if (length(o) != 4) return false;
	for (let x in o) if (!lj_num(x, 255)) return false;
	return true;
}

// IPv6 разбирается ЦЕЛИКОМ, а не «не больше восьми групп»: «2001:db8:»,
// «1:::2» и пустая группа посреди адреса уходили в elements, и ядро
// отвергало весь документ -- с ветками по доменам и по IPv4 (таблица inet
// одна на оба семейства). Четвёртый аудит, заход 3. Та же мерка -- у сборки
// (Ф9, п4-44: dead:beef и /200 проходили в конфиг Xray).
const HEX = '0123456789abcdefABCDEF';
function lj_v6_ok(l) {
	let s = index(l, '/'), e = s < 0 ? l : substr(l, 0, s);
	if (s >= 0) {
		// Пустая длина после «/» прежде проходила (ядро отвергало набор).
		let p = substr(l, s + 1);
		// «/0128» -- не длина: ведущий ноль nft и Xray читают по-разному (прогон 5).
		if (p === '' || !_only(p, '0123456789') || _numgt(p, 128) || (length(p) > 1 && substr(p, 0, 1) == '0')) return false;
	}
	if (e === '' || !_only(e, HEX + ':') || index(e, ':') < 0) return false;
	let c = 0, t = e, j;
	while ((j = index(t, '::')) >= 0) { c++; t = substr(t, j + 2); }
	if (c > 1) return false;
	if (c == 1) {
		let p = index(e, '::'), ng = 0;
		for (let h in [ substr(e, 0, p), substr(e, p + 2) ]) {
			if (h === '') continue;
			let g = split(h, ':');
			for (let x in g) if (x === '' || length(x) > 4) return false;
			ng += length(g);
		}
		// «::» обязано сжимать хотя бы одну группу.
		return ng <= 7;
	}
	let g = split(e, ':');
	if (length(g) != 8) return false;
	for (let x in g) if (x === '' || length(x) > 4) return false;
	return true;
}

// Отброшенная строка -- в файл bad. Наверху и с глобальным состоянием, не
// вложенной функцией: см. uc/keys.uc о ucode 22.03/23.05.
let LJ_BAD = null, LJ_BF = null;
// Регулярки: LJ_RE собирает встреченные (для поиска отвергнутых движком),
// LJ_RE_SKIP -- отвергнутые; ключ -- запись в виде конфига («regexp:…»).
let LJ_RE = null, LJ_RE_SKIP = null;
function lj_reject(s) {
	if (!LJ_BAD) return;
	LJ_BF ??= fs.open(LJ_BAD, 'a');
	if (LJ_BF) LJ_BF.write(s + '\n');
}

// Одна запись (уже обрезанная, не пустая, не комментарий) -> строка для
// массива; негодная -- null, сама строка -- в список отброшенных.
function lj_entry(l, dom, pfx) {
	if (length(l) > 253) { lj_reject(l); return null; }
	if (dom) {
		let v = l, pre = '';
		let c = index(v, ':');
		if (c > 0) {
			let p0 = substr(v, 0, c);
			if (p0 == 'geosite' || p0 == 'ext') { lj_reject(l); return null; }
			if (p0 == 'domain' || p0 == 'full' || p0 == 'keyword' || p0 == 'regexp') {
				pre = p0 + ':';
				v = substr(v, c + 1);
				if (!length(v)) { lj_reject(l); return null; }
			}
		}
		if (pre == 'regexp:') {
			// Управляющий знак JSON сырым не пускает: Xray отвергал весь
			// конфиг, reload молча оставлял прежний (Ф9, п1-22). Экранирует
			// по JSON вывод (lj_stream, %J): здесь -- запись как есть.
			if (match(v, /[\x01-\x1f\x7f]/)) { lj_reject(l); return null; }
			if (LJ_RE_SKIP && LJ_RE_SKIP[pre + v]) { lj_reject(l); return null; }
			if (LJ_RE) LJ_RE[pre + v] = true;
		} else if (pre == 'keyword:') {
			if (!_only(v, ALNUM + '._-')) { lj_reject(l); return null; }
		} else {
			if (!_domain_ok(v)) { lj_reject(l); return null; }
			if (pre == '') pre = pfx;
		}
		return pre + v;
	}
	// Подсети: та же мерка, что у наборов nft (pl_elements): что принято в
	// конфиг, принято и в перехват, и наоборот.
	if (!(index(l, ':') >= 0 ? lj_v6_ok(l) : lj_v4_ok(l, true))) { lj_reject(l); return null; }
	return pfx + l;
}

// Строка списка без пробелов по краям; пустая и комментарий -- null.
// Регулярки в ucode дороги (см. _domain_ok): обрезка -- trim с набором
// [[:space:]], комментарий -- сравнением начала.
function lj_line(l) {
	l = trim(l, WS);
	if (l === '' || substr(l, 0, 1) == '#' || substr(l, 0, 2) == '//') return null;
	return l;
}

// Записи файла -- в открытый файл out, по строке массива на запись: перед
// каждой ",\n" (перед первой -- "\n", если first). skip -- записи, которых в
// массиве быть не должно (домены направлений в общем правиле). Итог -- число
// записанных; нет файла -- 0.
function lj_stream(out, file, pfx, skip, ind, first) {
	let f = fs.open(file, 'r');
	if (!f) return 0;
	let dom = substr(pfx, 0, 7) == 'domain:';
	let n = 0, buf = [], l;
	while ((l = f.read('line')) != null && l !== '') {
		l = lj_line(l);
		if (l == null || (skip && skip[l])) continue;
		let e = lj_entry(l, dom, pfx);
		if (e == null) continue;
		// Кавычка и обратная косая законны только в regexp:, у прочих их нет.
		push(buf, ind + (substr(e, 0, 7) == 'regexp:' ? sprintf('%J', e) : '"' + e + '"'));
		if (length(buf) >= 2000) {
			out.write(((n || !first) ? ',\n' : '\n') + join(',\n', buf));
			n += length(buf);
			buf = [];
		}
	}
	if (length(buf)) {
		out.write(((n || !first) ? ',\n' : '\n') + join(',\n', buf));
		n += length(buf);
	}
	f.close();
	return n;
}

// Записи небольшого списка -- массивом строк (подсети, направления).
function lj_items(lines, pfx) {
	let dom = substr(pfx, 0, 7) == 'domain:';
	let r = [];
	for (let l in lines) {
		let e = lj_entry(l, dom, pfx);
		if (e != null) push(r, e);
	}
	return r;
}

// Строки файла без пустых и комментариев -- массивом (небольшие списки).
function lj_lines(file) {
	let f = fs.open(file, 'r');
	let r = [], l;
	if (!f) return r;
	while ((l = f.read('line')) != null && l !== '') {
		l = lj_line(l);
		if (l != null) push(r, l);
	}
	f.close();
	return r;
}

// Число записей, как count_list: непустые строки без комментариев.
function lj_count(file) {
	let f = fs.open(file, 'r');
	let n = 0, l;
	if (!f) return 0;
	while ((l = f.read('line')) != null && l !== '')
		if (lj_line(l) != null) n++;
	f.close();
	return n;
}

// Запись, которую можно спросить у резолвера:
// без regexp:/keyword:, префиксы domain:/full: сняты; иначе null.
function lj_plain(l) {
	l = trim(replace(l, '\r', ''), WS);
	if (l === '' || substr(l, 0, 1) == '#' || substr(l, 0, 2) == '//') return null;
	if (substr(l, 0, 7) == 'domain:') l = substr(l, 7);
	if (substr(l, 0, 5) == 'full:') l = substr(l, 5);
	return _domain_ok(l, true) ? l : null;
}
