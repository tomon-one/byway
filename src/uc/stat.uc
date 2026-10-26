// Учёт обращений по журналу Xray (stat из cron) и top -- чем пользуются
// (бывший data/stat.sh).
//
// Xray пишет строку в момент приёма, до сниффинга: в ней адрес из пула, не
// имя (`accepted tcp:198.19.14.63:443 [tproxy-in -> proxy]`). FakeDNS отдаёт
// домену один адрес до рестарта Xray -- раз за PID строится таблица адрес ->
// имя. Подсети идут по настоящим адресам -- строка «(подсети)», поддомены
// записей списка (в карте их нет) -- «(поддомены)».
//
// Рабочие файлы -- в каталоге root (/var/run/byway, 755), а не в общем /tmp:
// движок от пользователя byway мог подложить туда карту или метку.

const SA_DIR = '/var/run/byway';
const SA_MAP = SA_DIR + '/fakemap';        // адрес -> домен, живёт как и сам Xray
const SA_MARK = SA_DIR + '/statmark';      // PID и метка последней учтённой строки
const SA_POS = SA_DIR + '/fakemap.pos';    // докуда дошли, строя карту порциями
// Доменов за прогон: nslookup на домен, при 200 000 доменов полный обход
// длиннее часа, и следующий cron стартовал бы поверх.
const SA_STEP = 200;

function sa_file() { return getenv('BW_LISTS') + '/usage.tsv'; }

// Журнал обращений движок пишет только при show_usage=1 (или info/debug), в
// режиме «всё через VPN» -- никогда.
function sa_all() { return u('list_mode') == 'all'; }
function sa_off() {
	if (sa_all()) return true;
	if (u('show_usage') == '1') return false;
	let l = u('log_level');
	return l != 'info' && l != 'debug';
}

function sa_lines(s) {
	let r = [];
	for (let l in split(s ?? '', '\n')) if (l !== '') push(r, l);
	return r;
}

function sa_date(fmt, utc) {
	return rtrim(run(utc ? [ 'date', '-u', fmt ] : [ 'date', fmt ]).out, '\n');
}

// Домены для карты: общий список и списки включённых направлений (их
// соединения идут в учёт наравне с основными) -- те, что можно спросить.
function sa_domains() {
	let r = [], f = fs.open(getenv('BW_MERGED') ?? '', 'r'), l;
	if (f) {
		while ((l = f.read('line')) != null && l !== '') {
			l = lj_plain(l);
			if (l != null) push(r, l);
		}
		f.close();
	}
	let all = cursor().get_all('byway') ?? {}, secs = [];
	for (let n in all) if (all[n]['.type'] == 'route' && all[n].enabled != '0') push(secs, all[n]);
	secs = sort(secs, (a, b) => a['.index'] - b['.index']);
	for (let s in secs)
		for (let x in lj_lines(getenv('BW_ROUTES') + '/' + s['.name'] + '.lst')) {
			// Как route_list dom: без строк с пробелом и без подсетей.
			if (match(x, /[ \t]/) || match(x, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/)) continue;
			x = lj_plain(x);
			if (x != null) push(r, x);
		}
	return r;
}

// Карта адрес -> домен через FakeDNS, порциями; привязана к PID.
function sa_map(pid, oldpid) {
	let fresh = oldpid != pid;
	if (fresh) { fs.writefile(SA_MAP, ''); fs.writefile(SA_POS, ''); }
	let pos = trim(fs.readfile(SA_POS) ?? '');
	pos = (pos === '' || ltrim(pos, '0123456789') !== '') ? 0 : int(pos);
	let doms = sa_domains(), n = length(doms);
	if (!fresh && pos >= n) return;
	let pool = st_pool(), dns = g_dns_listen(false), add = '';
	for (let i = pos; i < n && i < pos + SA_STEP; i++)
		for (let l in split(run([ 'nslookup', doms[i], dns ]).out, '\n'))
			if (substr(l, 0, 8) == 'Address:') {
				let a = ltrim(substr(l, 8), ' ');
				if (st_in_pool(a, pool)) { add += a + '\t' + doms[i] + '\n'; break; }
			}
	if (add !== '') { let f = fs.open(SA_MAP, 'a'); if (f) { f.write(add); f.close(); } }
	pos += SA_STEP;
	if (pos > n) pos = n;
	fs.writefile(SA_POS, '' + pos);
	// Отсечка -- по сборке таблицы: в журнале строки прежних запусков Xray, их
	// адреса недействительны. Только при смене pid. Время -- UTC, как у Xray.
	if (fresh) fs.writefile(SA_MARK, pid + '\n' + sa_date('+%Y/%m/%d %H:%M:%S', true) + '\n');
	sayf('карта: %s из %s доменов, адресов %s', pos, n, length(sa_lines(fs.readfile(SA_MAP))));
}

// Строки журнала после последней учтённой; журнал обрезается до 50 строк (из
// хвоста status берёт имя работающего ключа).
function sa_collect(since) {
	let acc = getenv('BW_ACCESS'), r = [];
	let f = fs.open(acc, 'r'), l;
	if (!f) return r;
	while ((l = f.read('line')) != null && l !== '') {
		if (index(l, 'tproxy-in -> proxy') < 0 && index(l, 'tproxy-in -> route-') < 0) continue;
		l = rtrim(l, '\n');
		// Метка -- время Xray той же длины, что в ней: после учёта -- с
		// долями секунды (последняя учтённая строка), после карты -- 19 знаков.
		// Срез строки ровно 19 знаков был меньше метки с долями, и строки той
		// же секунды после отметки терялись (Ф9, п4-6).
		if (since !== '' && !(substr(l, 0, length(since)) > since)) continue;
		push(r, l);
	}
	f.close();
	// Перезапись на месте, не mv: движок держит файл открытым.
	let t = run([ 'tail', '-50', acc ]);
	if (t.code == 0) fs.writefile(acc, t.out);
	return r;
}

// Доменов в учёте: строки «(поддомены)», «(подсети)», «(по IP)» -- не домены.
function sa_ndom(rows) {
	let n = 0;
	for (let r in rows) if (substr(r, 0, 1) != '(') n++;
	return n;
}

// Подсчёт по таблице и запись итога; во флеш -- только если итог изменился.
function sa_count(lines, pid) {
	let file = sa_file();
	if (!length(lines)) { say('новых соединений в журнале нет'); return; }
	let name = {}, cnt = {}, seen = {}, today = sa_date('+%Y-%m-%d', false);
	for (let l in sa_lines(fs.readfile(SA_MAP))) {
		let t = split(l, '\t');
		name[t[0]] = t[1];
	}
	for (let l in sa_lines(fs.readfile(file))) {
		let t = split(l, '\t');
		cnt[t[0]] = int(t[1] ?? '0');
		seen[t[0]] = t[2] ?? '';
	}
	// Без имени: адрес из пула -- поддомен записи списка (карта знает только
	// точные имена), вне пула -- подсеть. Прежде оба шли в «(по IP)» и
	// считались доменом (Ф9, п3-22).
	// Карта строится порциями (SA_STEP): пока она не дошла до конца списка,
	// адрес без имени может быть и доменом списка -- тогда «(по IP)» (н1-3).
	let pool = st_pool(), pos = trim(fs.readfile(SA_POS) ?? '');
	let sub = (pos !== '' && ltrim(pos, '0123456789') === '' && int(pos) >= length(sa_domains())) ? '(поддомены)' : '(по IP)';
	for (let l in lines) {
		let m = match(l, /tcp:([0-9.]+):/) ?? match(l, /udp:([0-9.]+):/);
		if (!m) continue;
		let d = name[m[1]] ?? (st_in_pool(m[1], pool) ? sub : '(подсети)');
		cnt[d] = (cnt[d] ?? 0) + 1;
		seen[d] = today;
	}
	let out = [];
	for (let d in cnt) push(out, d + '\t' + cnt[d] + '\t' + seen[d]);
	let s = join('\n', sort(out)) + '\n';
	if (s != (fs.readfile(file) ?? '')) {
		// Учёт не записан (нет места) -- отметка стоит на месте: эти
		// соединения посчитаются в следующий раз, а не пропадут (Ф9, п4-34).
		// Рядом с учётом, не в /var/run: mv между tmpfs и флешем копирует, и
		// оборванная нехваткой места копия вставала на место учёта (прогон 5).
		if (!put_file(file, s, 0600))
			die('на флеше нет места: учёт не записан, посчитается в следующий раз');
	}
	let last = split(lines[length(lines) - 1], ' ');
	fs.writefile(SA_MARK, pid + '\n' + last[0] + ' ' + (last[1] ?? '') + '\n');
	sayf('учтено соединений: %s, всего доменов в учёте: %s', length(lines), sa_ndom(out));
}

// bw_uc stat: учёт за прошедшее (cron раз в час).
function cmd_stat() {
	if (!fs.stat(SA_DIR)) fs.mkdir(SA_DIR, 0755);
	if (sa_all()) { warn('в режиме «всё через VPN» журнал обращений не ведётся — статистики нет'); return; }
	if (sa_off())
		warn('сбор статистики выключен — включить: byway set show_usage on (в панели: Обслуживание → Сбор статистики)');
	let pid = st_xray_pid();
	if (pid === '') { warn('xray не запущен, считать нечего'); return; }
	let mk = split(fs.readfile(SA_MARK) ?? '', '\n');
	sa_map(pid, mk[0] ?? '');
	// Метка -- после карты: новая карта ставит новую отсечку.
	mk = split(fs.readfile(SA_MARK) ?? '', '\n');
	sa_count(sa_collect(mk[1] ?? ''), pid);
}

// Ширина в символах, не байтах: кириллица сдвигала бы колонку.
function sa_width(s) { return length(replace(s, /[\x80-\xbf]/g, '')); }

function sa_row(a, b, c) {
	let pad = '';
	for (let i = sa_width(a); i < 42; i++) pad += ' ';
	print(sprintf('  %s%s%8s  %s\n', a, pad, b, c));
}

// Служебные строки учёта -- на языке интерфейса; в файле -- как записаны.
// Явными _t: lang-sync сверяет словарь с кодом по ним.
function sa_tags() { return { '(поддомены)': _t('(поддомены)'), '(подсети)': _t('(подсети)'), '(по IP)': _t('(по IP)') }; }

// bw_uc top [N]: накопленное, N самых частых (по умолчанию 20).
function cmd_top(n) {
	let st = fs.stat(sa_file());
	if (!st || !st.size) {
		if (sa_all()) die('в режиме «всё через VPN» журнал обращений не ведётся — статистики нет');
		if (sa_off()) die('сбор статистики выключен — включить: byway set show_usage on (в панели: Обслуживание → Сбор статистики)');
		die('учёт пуст. Собирается задачей cron; вручную: byway stat');
	}
	let rows = [];
	for (let l in sa_lines(fs.readfile(sa_file()))) push(rows, [ l, split(l, '\t') ]);
	// Как sort -k2 -rn: по числу обращений, равные -- по всей строке, обратно.
	rows = sort(rows, (x, y) => {
		let a = int(x[1][1] ?? '0'), b = int(y[1][1] ?? '0');
		if (a != b) return b - a;
		return x[0] < y[0] ? 1 : (x[0] > y[0] ? -1 : 0);
	});
	n = (n && ltrim(n, '0123456789') === '') ? int(n) : 20;
	sa_row(_t('домен'), _t('обращений'), _t('последний раз'));
	let names = [], SA_TAGS = sa_tags();
	for (let i = 0; i < length(rows) && i < n; i++) {
		let d = rows[i][1][0] ?? '';
		sa_row(SA_TAGS[d] ?? d, rows[i][1][1] ?? '', rows[i][1][2] ?? '');
	}
	for (let r in rows) push(names, r[0]);
	print(_f('\n  всего в учёте %s доменов из %s в списке\n', sa_ndom(names), lj_count(getenv('BW_MERGED'))));
}
