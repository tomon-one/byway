// Готовые наборы (presets) и подписка (бывшие lists/presets.sh и
// lists/sub.sh). Пресеты никто не проверяет, кроме их авторов (itdoginfo
// 2026-09-04: из 37 новых записей 4 уже в хостлисте zapret, 2 -- убранный
// сервис, 2 -- мусор), поэтому после загрузки byway говорит о пересечениях.

const PS_NAMES = [ 'byway', 'itdoginfo-geoblock', 'itdoginfo-block', 'itdoginfo-subnets' ];
const PS_IT = 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/';
const PS_URL = {
	'byway': 'https://raw.githubusercontent.com/tomon-one/byway-lists/main/domains.lst',
	'itdoginfo-geoblock': PS_IT + 'Categories/geoblock.lst',
	'itdoginfo-block': PS_IT + 'Categories/block.lst',
};
// Подсети -- отдельным файлом: другой фильтр и потолок, другие потребители
// (набор nft, а не fakedns). У itdoginfo -- по сервисам, весь набор: решает
// человек, byway измеряет (замер 2026-09-05: ~21 млн адресов).
const PS_SUBURL = {
	'byway': [ 'https://raw.githubusercontent.com/tomon-one/byway-lists/main/subnets.lst' ],
	'itdoginfo-subnets': map([ 'telegram', 'meta', 'twitter', 'roblox', 'discord', 'google_meet', 'cloudflare',
	                           'cloudfront', 'digitalocean', 'hetzner', 'ovh' ],
	                         (n) => PS_IT + 'Subnets/IPv4/' + n + '.lst'),
};
const PS_ZAPHOSTS = '/opt/zapret/ipset/zapret-hosts-user.txt';

function ps_about(n) {
	if (n == 'byway') return _t('курируемый список byway: сервисы, недоступные из РФ и блокирующие её');
	if (n == 'itdoginfo-geoblock') return _t('itdoginfo: сервисы, которые сами закрываются от российских адресов');
	if (n == 'itdoginfo-block') return _t('itdoginfo: заблокированное в РФ. Внимание: встречается мусор');
	if (n == 'itdoginfo-subnets') return _t('itdoginfo: подсети для сервисов, которые работают не по именам. Весь их набор: Telegram, Meta, Twitter, Roblox, Discord, Google Meet и диапазоны хостеров Cloudflare, CloudFront, DigitalOcean, Hetzner, OVH. Вместе около 21 миллиона адресов -- byway скажет точную цифру при загрузке');
	return _t('свой адрес');
}

// Скачать список и подменить им прежний: 0 -- подменили, 1 -- скачанное не
// похоже на список (прежнее на месте), 2 -- не скачалось. Через прокси byway:
// домен источника может лежать в списке. Запись -- в сторону: ответ 200 с
// заглушкой провайдера стёр бы прежнюю копию.
function ps_fetch(urls, target, kind, name) {
	let dir = trim(run([ 'mktemp', '-d', '/tmp/byway-preset.XXXXXX' ]).out);
	if (dir === '') return 2;
	let all = dir + '/all', part = dir + '/part';
	fs.writefile(all, '');
	// Не скачался хоть один адрес -- отказ целиком: половина набора молча
	// теряет сервис.
	for (let u1 in urls) {
		if (nt_get([ '--max-time', '40', '--max-filesize', '8000000', '-o', part, u1 ]) != 0) {
			run([ 'rm', '-rf', dir ]);
			return 2;
		}
		// Перевод строки между файлами: последняя строка бывает без него и
		// слипается со следующей (5.28.192.0 + 21... = 215.28.192.0).
		let f = fs.open(all, 'a');
		f.write((fs.readfile(part) ?? '') + '\n');
		f.close();
		// Потолок суммы: --max-filesize стоит на каждый адрес, а их до 11.
		if (fs.stat(all).size > 33554432) {
			warnf('%s: источники дали больше 32 МБ — загрузка отменена, прежний список на месте', name);
			run([ 'rm', '-rf', dir ]);
			return 1;
		}
	}
	// Пробелы снимаются только по краям: вырезание внутри склеивало
	// hosts-формат в домен. Форма подсети -- та же, что у set_elements.
	let cap = kind == 'net' ? 20000 : 200000;
	let form = kind == 'net' ?
		'grep -E "^[0-9]{1,3}(\\.[0-9]{1,3}){3}(/[0-9]{1,2})?$"' :
		'grep -E "^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$" | grep -E "\\.[a-zA-Z]{2,}$"';
	let r = run([ 'sh', '-c', 'grep -vE "^[[:space:]]*(//|#|$)" "$1" | tr -d "\\r" | ' +
	              'sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" | ' + form + ' | sort -u | ' +
	              'awk -v cap="$3" -v cf="$1.cnt" \'{ n++; if (n <= cap) print } END { print n+0 > cf }\' > "$2"',
	              'sh', all, target + '.new', '' + cap ]);
	if (r.code != 0) { run([ 'rm', '-rf', dir ]); fs.unlink(target + '.new'); return 2; }
	// Срез -- вслух; число -- от конвейера, в файле уже срезанное.
	let pre = trim(fs.readfile(all + '.cnt') ?? '0');
	pre = ltrim(pre, '0123456789') === '' && pre !== '' ? int(pre) : 0;
	run([ 'rm', '-rf', dir ]);
	if (pre > cap) {
		warnf('%s: записей %s, взяты первые %s — остальное отброшено', name, pre, cap);
		logf('пресет %s: %s записей, срез до %s', name, pre, cap);
	}
	// Порог -- четверть прежнего размера: усохший с полутора тысяч до трёх
	// список -- тоже заглушка.
	let nw = lj_count(target + '.new'), od = lj_count(target);
	if (nw == 0 || (od > 0 && nw * 4 < od)) {
		fs.unlink(target + '.new');
		warnf('%s: скачанное не похоже на список (%s записей, было %s) — прежняя копия оставлена', name, nw, od);
		logf('пресет %s: отказ, записей %s, было %s', name, nw, od);
		return 1;
	}
	fs.rename(target + '.new', target);
	return 0;
}

// Пересечение с хостлистом zapret (по суффиксу: оба движка матчат домен с
// поддоменами): число и первые найденные строки.
function ps_zap(file) {
	let st = fs.stat(file);
	if (!fs.stat(PS_ZAPHOSTS) || !st || !st.size) return [ 0, [] ];
	let r = run([ 'sh', '-c', 'd=$(mktemp -d /tmp/byway-zap.XXXXXX) || exit 1; ' +
	              'grep -vE "^[[:space:]]*(#|$)" "$1" | tr -d " \\t\\r" | sort -u > "$d/z"; sed "s/^/./" "$d/z" > "$d/s"; ' +
	              '{ grep -Fxf "$d/z" "$2"; grep -Ff "$d/s" "$2"; } | sort -u; rm -rf "$d"', 'sh', PS_ZAPHOSTS, file ]);
	let hit = [];
	for (let l in split(r.out, '\n')) if (l !== '') push(hit, l);
	return [ length(hit), slice(hit, 0, 8) ];
}

// Пины /etc/hosts внутри подсетей: пин ставят, чтобы адрес шёл мимо туннеля, а
// широкий диапазон набора делает обратное.
function ps_pins_in(file) {
	let st = fs.stat(file);
	if (!fs.stat('/etc/hosts') || !st || !st.size) return 0;
	let nets = [], f = fs.open(file, 'r'), l;
	while ((l = f.read('line')) != null && l !== '') {
		l = replace(l, /[ \t\n\r\x0b\x0c]/g, '');
		if (l === '' || substr(l, 0, 1) == '#' || substr(l, 0, 2) == '//') continue;
		let s = index(l, '/'), ip = s < 0 ? l : substr(l, 0, s);
		let n = st_ip_num(ip);
		if (n == null) continue;
		let pl = s < 0 ? 32 : g_lead_int(substr(l, s + 1));
		let span = 1 << (32 - (pl > 32 ? 32 : pl));
		push(nets, [ int(n / span), span ]);
	}
	f.close();
	let c = 0;
	for (let h in split(fs.readfile('/etc/hosts') ?? '', '\n')) {
		let x = split(trim(h), /[ \t]+/);
		if (substr(x[0] ?? '', 0, 1) == '#') continue;
		let v = st_ip_num(x[0] ?? '');
		if (v == null) continue;
		for (let n in nets) if (int(v / n[1]) == n[0]) { c++; break; }
	}
	return c;
}

function ps_hits(hits) { for (let h in hits) print('      ', h, '\n'); }

// bw_uc presets: обновить подключённые наборы.
function cmd_presets() {
	let dir = getenv('BW_PRESETS');
	if (!fs.stat(dir)) fs.mkdir(dir, 0755);
	let any = false;
	let names = split(trim(u('preset')), /[ \t\n]+/);
	if (names[0] == '') names = [];
	for (let n in names) {
		// Пресет может быть чисто подсетевым: ругаться, только если нет ни
		// доменной, ни подсетевой половины.
		let url = PS_URL[n], su = PS_SUBURL[n];
		if (url == null && su == null) { warnf('неизвестный пресет: %s', n); continue; }
		let pf = dir + '/' + n + '.lst';
		if (url != null) {
			let fr = ps_fetch([ url ], pf, 'dom', n);
			if (fr == 2) {
				let s = fs.stat(pf);
				if (s && s.size) warnf('%s: не скачался, остаётся прежняя копия', n);
				else warnf('%s: не скачался, и прежней копии нет — список пуст', n);
			}
			if (fr != 0) continue;
		}
		// Подсети -- вторым файлом; отказ не отменяет принятые домены.
		if (su != null && ps_fetch(su, dir + '/' + n + '.sub', 'net', n) == 0) {
			sayf('%s: подсетей %s', n, lj_count(dir + '/' + n + '.sub'));
			g_net_warn(dir + '/' + n + '.sub');
			any = true;
		}
		if (url == null) continue;
		sayf('%s: %s записей', n, lj_count(pf));
		say('  ' + ps_about(n));
		// Пересечение с хостлистом zapret нарушает «домен ровно в одном месте»;
		// снаружи это сбои при входе в аккаунт.
		let z = ps_zap(pf);
		if (z[0] > 0) {
			warnf('  %s записей ЛЕЖАТ И В ХОСТЛИСТЕ ZAPRET — домен должен быть в одном месте:', z[0]);
			ps_hits(z[1]);
			warn('  иначе одна сессия разъедется на два выхода: это видно не отказом, а сбоями при входе в аккаунт');
		}
		any = true;
	}
	// Свой список сверяется тоже: домены добавляют руками именно в него.
	let z2 = ps_zap(getenv('BW_LISTS') + '/domains.lst');
	if (z2[0] > 0) {
		warnf('  свой список: %s записей пересекаются с хостлистом zapret', z2[0]);
		ps_hits(z2[1]);
		warn('  домен должен быть в одном месте: иначе одна сессия разъедется на два выхода');
	}
	let pinf = ps_pins_in(mg_path('subnets'));
	if (pinf > 0) {
		warnf('  пинов из /etc/hosts внутри подсетей byway: %s', pinf);
		warn('  их адреса уйдут в туннель, хотя пин ставят затем, чтобы шли мимо');
	}
	let pind = dr_pins(mg_path('domains'));
	if (pind > 0) {
		warnf('  пинов в /etc/hosts перебивают записи списка: %s', pind);
		warn('  dnsmasq ответит по пину, подставного адреса не будет — в туннель они НЕ пойдут');
		warn('  и запрет «не пускать мимо VPN» их не закроет: пин старше address=/домен/');
	}
	// Три исхода: обновилось (молчим), ничего не подключено, не скачалось.
	if (any) return;
	if (!length(names)) {
		say('ни одного готового списка не подключено');
		say('  что бывает:');
		for (let k in PS_NAMES) print(sprintf('    %-20s %s\n', k, ps_about(k)));
		say('  подключить: byway list ready on ИМЯ');
	} else {
		warn('ни один из подключённых списков не обновился — прежние копии остались на месте');
	}
}

// bw_uc sub: подписка (адрес -- в BW_SUB_URL, не аргументом: аргументы видны
// всем в /proc/*/cmdline) -> ключи построчно. Подписки обычно base64:
// раскодирует ucode; не раскодированное отдаётся как есть -- панель
// раскодирует сама, если в ответе нет «://».
function cmd_sub() {
	let url = getenv('BW_SUB_URL') ?? '';
	if (url === '') die('byway sub <адрес подписки>');
	// Открытый HTTP правится на лету: подложенный ключ выиграл бы по задержке.
	if (substr(url, 0, 7) == 'http://')
		die('подписка по http:// не принимается: ключи в ней может подменить кто угодно на пути — нужен https://');
	if (substr(url, 0, 8) != 'https://') die('это не адрес подписки: ожидается https://');
	// Подкоманду может звать роль панели, а curl идёт от root: петля и
	// приватные диапазоны отсекаются до запроса. IPv6-литерал не разбирается.
	if (index(url, '://[') >= 0 || index(url, '@[') >= 0)
		die('адрес подписки с IPv6-литералом не поддерживается — нужно имя или IPv4');
	let h = pk_after(url, '://');
	h = pk_before(pk_before(h, '/'), '?');
	h = pk_lastafter(h, '@');
	h = pk_before(h, ':');
	if (h == 'localhost' || substr(h, 0, 10) == 'localhost.' || substr(h, -10) == '.localhost')
		die('адрес подписки указывает на сам роутер');
	let ip = match(h, /[a-zA-Z]/) ? g_a_of(h, '') : h;
	if (match(ip || '0.0.0.0', /^(127\.|0\.|10\.|192\.168\.|169\.254\.|198\.18\.|198\.19\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)/))
		dief('адрес подписки ведёт внутрь сети (%s) — byway туда не ходит', ip || '?');
	// Адрес -- в файл конфига curl (600), не в командную строку.
	let cfg = trim(run([ 'mktemp', '/tmp/byway-sub.XXXXXX' ]).out);
	if (cfg === '') die('подписка не скачалась: стоит проверить адрес и связь');
	fs.chmod(cfg, 0600);
	fs.writefile(cfg, 'url = "' + replace(url, /[\\"]/g, (c) => '\\' + c) + '"\n');
	let px = u('local_proxy_port') || '1603';
	let opts = [ 'curl', '-fsSL', '--max-time', '25', '--max-filesize', '4194304', '--max-redirs', '3', '-A', 'Mozilla/5.0' ];
	let raw = run([ ...opts, '--proxy', 'http://127.0.0.1:' + px, '--config', cfg ]).out;
	if (raw === '') raw = run([ ...opts, '--config', cfg ]).out;
	fs.unlink(cfg);
	// Как $(…) в shell: хвостовые переводы строки срезаны.
	raw = rtrim(raw, '\n');
	if (raw === '') die('подписка не скачалась: стоит проверить адрес и связь');
	if (index(raw, '://') < 0) {
		let s = replace(raw, /[\r\n\t ]/g, '');
		s = replace(replace(s, '_', '/'), '-', '+');
		if (length(s) % 4 == 2) s += '==';
		else if (length(s) % 4 == 3) s += '=';
		let d = rtrim(b64dec(s) ?? '', '\n');
		if (index(d, '://') >= 0) raw = d;
	}
	print(raw, '\n');
}
