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
// плюс отказ на «..».
function _domain_ok(v) {
	let n = length(v);
	if (!n || !_only(v, ALNUM + '.-') || index(ALNUM, substr(v, 0, 1)) < 0 ||
	    index(ALNUM, substr(v, n - 1, 1)) < 0 || index(v, '..') >= 0)
		return false;
	let d = rindex(v, '.');
	if (d < 0) return false;
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

// Отброшенная строка -- в файл bad. Наверху и с глобальным состоянием, не
// вложенной функцией: см. uc/keys.uc о ucode 22.03/23.05.
let LJ_BAD = null, LJ_BF = null;
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
			v = replace(replace(v, '\\', '\\\\'), '"', '\\"');
		} else if (pre == 'keyword:') {
			if (!_only(v, ALNUM + '._-')) { lj_reject(l); return null; }
		} else {
			if (!_domain_ok(v)) { lj_reject(l); return null; }
			if (pre == '') pre = pfx;
		}
		return pre + v;
	}
	// Подсети: та же форма, что у set_elements для nft, с проверкой чисел --
	// одна регулярка пропускает и 999.1.2.3, и /33. IPv6 -- грубо: строгую
	// форму проверяет set_elements6, дальше строку разбирает сам Xray.
	if (index(l, ':') >= 0) {
		if (!match(l, /^[0-9a-fA-F:]+(\/[0-9]{1,3})?$/)) { lj_reject(l); return null; }
	} else {
		let ok = match(l, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) != null;
		if (ok) {
			let oc = split(l, /[.\/]/);
			for (let i = 0; i < 4; i++)
				if (_numgt(oc[i], 255)) ok = false;
			if (length(oc) == 5 && _numgt(oc[4], 32)) ok = false;
		}
		if (!ok) { lj_reject(l); return null; }
	}
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
		push(buf, ind + '"' + e + '"');
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
