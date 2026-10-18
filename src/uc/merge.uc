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
function mg_path(kind) {
	let dom = kind != 'subnets';
	let lists = getenv('BW_LISTS'), routes = getenv('BW_ROUTES'), presets = getenv('BW_PRESETS');
	let out = dom ? '/tmp/byway-domains-all.lst' : '/tmp/byway-subnets-all.lst';
	let pre = split(trim(u('preset')), /[ \t\n]+/);
	if (pre[0] == '') pre = [];
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
	let tmp = trim(run([ 'mktemp', '/tmp/byway-merge.XXXXXX' ]).out);
	if (tmp === '') return out;
	let f = fs.open(tmp, 'w');
	let own = fs.readfile(src[0]);
	if (own != null) f.write(own + '\n');
	LJ_BAD = getenv('BW_BADLIST');
	LJ_BF = null;
	for (let r in rts) {
		let part = mg_route_part(routes + '/' + r + '.lst', dom ? 'dom' : 'net');
		if (length(part)) f.write(join('\n', part) + '\n');
	}
	if (LJ_BF) { LJ_BF.close(); LJ_BF = null; }
	for (let p in pre) {
		let t = fs.readfile(presets + '/' + p + (dom ? '.lst' : '.sub'));
		if (t != null) f.write(t + '\n');
	}
	f.close();
	let r = run([ 'sh', '-c', 'grep -vE "^[[:space:]]*(//|#|$)" "$1" | tr -d "\\r" | ' +
	              'sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" | sort -u > "$1.s" && mv "$1.s" "$2"',
	              'sh', tmp, out ], true);
	fs.unlink(tmp);
	if (r.code != 0) { fs.unlink(tmp + '.s'); return out; }
	fs.writefile(out + '.sig', now + '\n' + join('\n', sig) + '\n' + mg_stat(out));
	return out;
}

// bw_uc merged domains|subnets: путь к склейке.
function cmd_merged(kind) { print(mg_path(kind)); }
