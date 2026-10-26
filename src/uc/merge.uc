// Общие списки доменов и подсетей: свои + включённые направления + подключённые
// пресеты, одним файлом без повторов (бывшие merged_domains, merged_subnets).
// Читают сборка конфига, набор nft, запрет и проверки -- все обязаны видеть одно
// и то же. Склейка кэшируется: потребителей много (сторож раз в 5 минут), а на
// 200 000 записях это 12 МБ в tmpfs.

// Подпись кэша: что склеено (пресеты, направления), каждый источник и сама
// склейка -- путём, временем и размером. Годен, только если подпись та же и все
// источники СТРОГО старше сборки: время -- в секундах, и правка в ту же
// секунду, что прошлая склейка, иначе не была бы видна (2026-10-18).
function mg_stat(f) {
	let s = fs.stat(f);
	return s ? f + ' ' + s.mtime + ' ' + s.size : null;
}

function mg_routes() {
	let all = cursor().get_all('byway') ?? {}, r = [];
	for (let n in all) if (all[n]['.type'] == 'route' && all[n].enabled != '0') push(r, all[n]);
	r = sort(r, (a, b) => a['.index'] - b['.index']);
	return map(r, (s) => s['.name']);
}

// Строки направления, разложенные надвое (route_list): dom или net. Строка с
// пробелом внутри -- формат hosts («0.0.0.0 example.com»), не запись: в
// отброшенные, не склеивать.
function mg_route_part(file, want) {
	let r = [];
	for (let l in lj_lines(file)) {
		if (match(l, /[ \t\x0b\x0c]/)) { lj_reject(l); continue; }
		let net = match(l, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) != null;
		if ((want == 'net') == net) push(r, l);
	}
	return r;
}

// Путь к склейке domains|subnets (собрать, если кэш негоден).
// Склейка не собралась: soft -- null (перехват уходит в свой отказ), иначе
// выход словами.
function mg_bad(soft) {
	if (!soft) die('склейка списков не собралась: в /tmp нет места? Рабочий конфиг не тронут');
	return null;
}

function mg_path(kind, soft) {
	let dom = kind != 'subnets';
	let lists = getenv('BW_LISTS'), routes = getenv('BW_ROUTES'), presets = getenv('BW_PRESETS');
	let out = dom ? '/var/run/byway-domains-all.lst' : '/var/run/byway-subnets-all.lst';
	// Имя готового списка -- только буквы, цифры, «_» и «-»: из настроек оно
	// становилось путём, и склейка читала *.lst вне каталога пресетов (Ф9,
	// п1-20). Чужое имя молча пропускается: так делает и cmd_presets.
	let pre = filter(ul('preset'), (p) => _only(p, 'abcdefghijklmnopqrstuvwxyz0123456789_-'));
	let rts = mg_routes();
	let src = [ lists + (dom ? '/domains.lst' : '/subnets.lst') ];
	for (let r in rts) push(src, routes + '/' + r + '.lst');
	for (let p in pre) push(src, presets + '/' + p + (dom ? '.lst' : '.sub'));

	let sig = [ join(' ', pre) + '|' + join(' ', rts) ], newest = 0;
	for (let f in src) {
		let s = fs.stat(f);
		if (!s) continue;
		push(sig, f + ' ' + s.mtime + ' ' + s.size);
		if (s.mtime > newest) newest = s.mtime;
	}
	let old = split(fs.readfile(out + '.sig') ?? '', '\n');
	let cur = mg_stat(out);
	// Строка 1 -- время сборки, последняя -- сама склейка (её правка чужими
	// руками -- тоже повод пересобрать: /tmp общий).
	if (cur != null && length(old) == length(sig) + 2 && old[length(old) - 1] == cur &&
	    join('\n', slice(old, 1, length(old) - 1)) == join('\n', sig) && newest < int(old[0]))
		return out;

	// Сборка: текст -- в черновик, чистка и sort -u -- busybox (на роутере
	// быстрее, и список не держится в памяти ucode).
	let now = time();
	// Склейка, не дописанная нехваткой места в /tmp, -- отказ сборки: прежде
	// gen брал пустую или старую и затирал рабочий конфиг (Ф9, п2-6).
	let tmp = trim(run([ 'mktemp', '/tmp/byway-merge.XXXXXX' ]).out);
	let f = tmp !== '' ? fs.open(tmp, 'w') : null;
	if (!f) { if (tmp !== '') fs.unlink(tmp); return mg_bad(soft); }
	// Без вложенной функции: захват переменных на ucode 22.03 ненадёжен.
	let want = 0, got = 0, t;
	let own = fs.readfile(src[0]);
	if (own != null) { t = own + '\n'; want += length(t); got += f.write(t) ?? 0; }
	LJ_BAD = getenv('BW_BADLIST');
	LJ_BF = null;
	for (let r in rts) {
		let part = mg_route_part(routes + '/' + r + '.lst', dom ? 'dom' : 'net');
		if (length(part)) { t = join('\n', part) + '\n'; want += length(t); got += f.write(t) ?? 0; }
	}
	if (LJ_BF) { LJ_BF.close(); LJ_BF = null; }
	for (let p in pre) {
		let pt = fs.readfile(presets + '/' + p + (dom ? '.lst' : '.sub'));
		if (pt != null) { t = pt + '\n'; want += length(t); got += f.write(t) ?? 0; }
	}
	f.close();
	// Запись буферизована: f.write отвечает полной длиной и при полном /tmp,
	// ошибка видна только по размеру файла. И место под итог sort -- до него:
	// sort с перенаправлением о нехватке места молчит, и склейка выходила
	// пустой, а при «Не пускать» -- «закрывать нечего» (Ф9, прогон 5).
	let df = split(split(run([ 'df', '-k', '/var/run' ]).out, '\n')[1] ?? '', /[ \t]+/);
	if (got != want || (fs.stat(tmp)?.size ?? -1) != want ||
	    (df[3] != null && match(df[3], /^[0-9]+$/) && int(df[3]) * 1024 < want + 65536)) {
		fs.unlink(tmp);
		return mg_bad(soft);
	}
	let r = run([ 'sh', '-c', 'grep -vE "^[[:space:]]*(//|#|$)" "$1" | tr -d "\\r" | ' +
	              'sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" | sort -u > "$1.s" && mv "$1.s" "$2"',
	              'sh', tmp, out ], true);
	fs.unlink(tmp);
	if (r.code != 0) { fs.unlink(tmp + '.s'); return mg_bad(soft); }
	fs.writefile(out + '.sig', now + '\n' + join('\n', sig) + '\n' + mg_stat(out));
	return out;
}

// bw_uc merged domains|subnets: путь к склейке.
function cmd_merged(kind) { print(mg_path(kind)); }
