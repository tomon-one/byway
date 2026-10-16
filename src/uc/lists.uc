// Записи списков -> строки JSON-массива. Перенос list_to_json (config/gen.sh)
// один в один: та же форма записи и тот же вывод до байта. Файл читается по
// строке и печатается сразу: на потолке пресета (200 000 доменов) список в
// памяти занял бы десятки МБ рядом с движком.

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

function list_json(file, pfx, bad) {
	let f = fs.open(file, 'r');
	// Нет файла -- как busybox awk: жалоба в stderr, код 1, в вывод ничего (вывод --
	// сам JSON, вызывающий решает, что делать).
	if (!f) {
		fs.stderr.write(sprintf('list_json: %s: %s\n', file, fs.error()));
		exit(1);
	}
	let bf = null;
	let reject = function (s) {
		if (!bad) return;
		bf ??= fs.open(bad, 'a');
		if (bf) bf.write(s + '\n');
	};
	let dom = substr(pfx, 0, 7) == 'domain:';
	let n = 0;
	let buf = [];
	let l;
	// Регулярки в ucode дороги (см. _domain_ok): обрезка -- trim с набором
	// [[:space:]], комментарий -- сравнением начала, домен -- без регулярок.
	while ((l = f.read('line')) != null && l !== '') {
		l = trim(l, WS);
		if (l === '' || substr(l, 0, 1) == '#' || substr(l, 0, 2) == '//')
			continue;
		if (length(l) > 253) { reject(l); continue; }
		let out;
		if (dom) {
			let v = l, pre = '';
			let c = index(v, ':');
			if (c > 0) {
				let p0 = substr(v, 0, c);
				if (p0 == 'geosite' || p0 == 'ext') { reject(l); continue; }
				if (p0 == 'domain' || p0 == 'full' || p0 == 'keyword' || p0 == 'regexp') {
					pre = p0 + ':';
					v = substr(v, c + 1);
					if (!length(v)) { reject(l); continue; }
				}
			}
			if (pre == 'regexp:') {
				v = replace(replace(v, '\\', '\\\\'), '"', '\\"');
			} else if (pre == 'keyword:') {
				if (!_only(v, ALNUM + '._-')) { reject(l); continue; }
			} else {
				if (!_domain_ok(v)) { reject(l); continue; }
				if (pre == '') pre = pfx;
			}
			out = pre + v;
		} else {
			// Подсети: та же форма, что у set_elements для nft, с проверкой
			// чисел -- одна регулярка пропускает и 999.1.2.3, и /33. IPv6 --
			// грубо: строгую форму проверяет set_elements6, дальше строку
			// разбирает сам Xray.
			if (index(l, ':') >= 0) {
				if (!match(l, /^[0-9a-fA-F:]+(\/[0-9]{1,3})?$/)) { reject(l); continue; }
			} else {
				let ok = match(l, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) != null;
				if (ok) {
					let oc = split(l, /[.\/]/);
					for (let i = 0; i < 4; i++)
						if (_numgt(oc[i], 255)) ok = false;
					if (length(oc) == 5 && _numgt(oc[4], 32)) ok = false;
				}
				if (!ok) { reject(l); continue; }
			}
			out = pfx + l;
		}
		push(buf, '        "' + out + '"');
		if (length(buf) >= 2000) {
			print((n ? ',\n' : '') + join(',\n', buf));
			n += length(buf);
			buf = [];
		}
	}
	if (length(buf))
		print((n ? ',\n' : '') + join(',\n', buf));
	f.close();
	if (bf) bf.close();
}
