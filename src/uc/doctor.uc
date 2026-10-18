// byway doctor -- проверка окружения по разделам, и byway report -- отчёт для
// обращения (бывшие diag/doctor.sh и diag/report.sh). Пути и номера от shell
// -- в BW_*.

let DR_BAD = 0;

function dr_line(tag, m, hint) {
	print('  [ ', tag, ' ] ', m, '\n');
	if (hint) print('         ', hint, '\n');
}
function dok(m)        { dr_line('ok', m); }
function dbad(m, hint) { dr_line('!!', m, hint); DR_BAD++; }
function dwarn(m, hint) { dr_line('??', m, hint); }

// Есть ли программа в PATH.
function dr_have(c) { return run([ 'sh', '-c', 'command -v "$1"', 'sh', c ]).code == 0; }

function dr_head(s) { print(s); }

// Первая строка вывода, без перевода строки.
function dr_first(argv) { return split(run(argv).out, '\n')[0] ?? ''; }

function dr_uci(path) { return rtrim(run([ 'uci', '-q', 'get', path ]).out, '\n'); }

// Число в арифметике shell: 0x… -- шестнадцатеричное, 0… -- восьмеричное.
function dr_num(s) {
	if (match(s, /^0[xX][0-9a-fA-F]+$/)) return hex(substr(s, 2));
	if (match(s, /^0[0-7]+$/)) {
		let n = 0;
		for (let i = 1; i < length(s); i++) n = n * 8 + int(substr(s, i, 1));
		return n;
	}
	return match(s, /^[0-9]+$/) ? int(s) : 0;
}

// Время правки файла; нет файла -- null.
function dr_mtime(f) { let s = fs.stat(f); return s ? s.mtime : null; }

// Пины /etc/hosts против списка доменов (hosts_vs_domains): пин накрывает
// запись, если запись -- он сам или его хвост по меткам.
function dr_pins(file) {
	let st = fs.stat(file);
	if (!st || !st.size || !fs.stat('/etc/hosts')) return 0;
	let d = {}, f = fs.open(file, 'r'), l;
	while ((l = f.read('line')) != null && l !== '') {
		l = replace(l, /[ \t\n\r\x0b\x0c]/g, '');
		if (l === '' || substr(l, 0, 1) == '#' || substr(l, 0, 2) == '//') continue;
		d[lc(l)] = true;
	}
	f.close();
	let hosts = {};
	for (let h in split(fs.readfile('/etc/hosts') ?? '', '\n')) {
		let x = split(trim(replace(h, '\r', '')), /[ \t]+/);
		if (length(x) < 2 || substr(x[0], 0, 1) == '#') continue;
		for (let i = 1; i < length(x); i++) if (substr(x[i], 0, 1) != '#') hosts[x[i]] = true;
	}
	let c = 0;
	for (let h in hosts) {
		let s = lc(h);
		if (d[s]) { c++; continue; }
		let p;
		while ((p = index(s, '.')) >= 0) {
			s = substr(s, p + 1);
			if (d[s]) { c++; break; }
		}
	}
	return c;
}

// Час автообновления (au_hour).
function dr_au_hour() {
	let h = u('auto_update_hour') || '04';
	if (!match(h, /^([0-9]|[01][0-9]|2[0-3])$/)) {
		warnf('час автообновления «%s» не годится, взято 04', h);
		h = '04';
	}
	return length(h) == 2 ? h : '0' + h;
}

function dr_rule_count() {
	let mk = st_mark(), n = 0;
	let re = regexp('fwmark ' + mk + '(/' + mk + ')?[ \t]+lookup ' + ST_RT + '([ \t]|$)');
	for (let l in split(run([ 'ip', 'rule', 'show' ]).out, '\n')) if (match(l, re)) n++;
	return n;
}

// ── разделы ───────────────────────────────────────────────────────────────
function dr_system() {
	dr_head(_t('Система\n'));
	let rel = fs.readfile('/etc/openwrt_release');
	if (rel != null) {
		let m = match(rel, /(^|\n)DISTRIB_RELEASE='([^\n]*)'/);
		dok(_f('OpenWrt: %s', m ? m[2] : ''));
	} else {
		dwarn(_t('не OpenWrt'), _t('byway рассчитан на OpenWrt, на другом может не работать'));
	}
	dok(_f('архитектура: %s', trim(run([ 'uname', '-m' ]).out)));
	// Отдельного /overlay может не быть (ram-профили, чистый ext4).
	let mnt = fs.stat('/overlay') ? '/overlay' : '/';
	let df = split(split(run([ 'df', '-k', mnt ]).out, '\n')[1] ?? '', /[ \t]+/);
	if (df[3] == null) df = split(split(run([ 'df', '-k', '/' ]).out, '\n')[1] ?? '', /[ \t]+/);
	let free = df[3] != null ? int(int(df[3]) / 1024) : '';
	if ((free === '' ? 0 : free) < 2)
		dbad(_f('свободно на флеше: %s МБ', free), _t('меньше двух мегабайт: списки и конфиг могут не записаться'));
	else
		dok(_f('свободно на флеше: %s МБ', free));
}

function dr_needs() {
	dr_head(_t('\nЧего требует byway\n'));
	let pid = st_xray_pid();
	// Включён ли byway и работает ли движок: без этого отчёт на выключенном
	// byway выходил зелёным.
	if (u('enabled') == '1') {
		if (pid !== '') dok(_t('byway включён, движок работает'));
		else dbad(_t('byway включён, но движок не работает'),
		          _t('движок не запущен или упал: /etc/init.d/byway restart, затем byway status и logread -e xray'));
	} else {
		dwarn(_t('byway выключен настройкой'),
		      _t('включить: byway on'));
	}
	// Автозапуск отдельно от enabled; `enabled` не отличает «выключено» от
	// «нет файла» -- файл проверяется сам.
	if (run([ 'test', '-x', '/etc/init.d/byway' ]).code != 0)
		dbad(_t('файла службы нет'), _t('byway не поднимется ни сейчас, ни после перезагрузки: поставить заново'));
	else if (run([ '/etc/init.d/byway', 'enabled' ]).code == 0)
		dok(_t('служба в автозапуске'));
	else
		dbad(_t('служба НЕ в автозапуске'), _t('сейчас работает, но после перезагрузки туннеля не будет: /etc/init.d/byway enable'));
	// Задачи cron: сторож, учёт, обрезка журналов.
	let cw = 0, cs = 0, cp = false;
	for (let l in split(run([ 'crontab', '-l' ]).out, '\n')) {
		if (index(l, 'byway watch') >= 0) cw++;
		if (index(l, 'byway stat') >= 0) cs++;
		if (index(l, 'byway pulse') >= 0) cp = true;
	}
	if (cw > 0 && cs > 0) {
		if (run([ 'pidof', 'crond' ]).code == 0)
			dok(_t('задачи cron на месте, crond работает'));
		else
			dbad(_t('задачи cron есть, но crond не работает'),
			     _t('без него не работают ни проверка перехвата раз в 5 минут (byway watch), ни учёт трафика (byway stat), ни обрезка журналов: /etc/init.d/cron enable && /etc/init.d/cron start'));
	} else {
		dbad(_f('в cron не хватает задач byway (watch: %s, stat: %s)', cw, cs),
		     _t('переустановить byway либо завести вручную: */5 * * * * /usr/local/bin/byway watch и 7 * * * * /usr/local/bin/byway stat'));
	}
	if (!cp)
		dwarn(_t('нет задачи cron byway pulse'),
		      _t('без неё при отказе движка дом остаётся без DNS до 10 минут вместо 1–2: byway update --force либо завести вручную: * * * * * /usr/local/bin/byway pulse'));
	// lsmod не показывает встроенные в ядро модули: ещё /sys/module.
	let lsm = run([ 'lsmod' ]).out;
	for (let m in [ 'nft_tproxy', 'nft_socket' ]) {
		if (match(lsm, regexp('(^|\n)' + m + ' ')) || fs.stat('/sys/module/' + m))
			dok(_f('модуль %s', m));
		else
			dbad(_f('нет модуля %s', m), getenv('BW_PKG_FIX') + ' kmod-nft-tproxy kmod-nft-socket');
	}
	if (dr_have('fw4'))
		dok(_t('файрвол firewall4'));
	else
		dbad(_t('firewall4 не найден — вероятно firewall3, 21.02 и старше'),
		     _t('byway работает только на firewall4, это OpenWrt 22.03 и новее — на firewall3 правило по метке не встанет'));
	let x = xray_bin();
	if (run([ 'test', '-x', x ]).code == 0) {
		dok(_f('движок: %s (%s)', join(' ', slice(split(dr_first([ x, 'version' ]), ' '), 0, 2)), x));
		if (pid !== '') {
			let uid = match(fs.readfile('/proc/' + pid + '/status') ?? '', /\nUid:[ \t]*([0-9]+)/);
			if (uid && uid[1] == '0')
				dwarn(_t('движок работает от root'), _t('права не урезаны: нет /sbin/ujail (пакет procd-ujail) либо задано byway.main.xray_root=1'));
			else
				dok(_t('движок работает не от root (пользователь byway)'));
		}
		let out = getenv('BW_OUT');
		if (fs.stat(out) && run([ 'grep', '-q', '"network": "xhttp"', out ]).code == 0 && st_dial_bug(x))
			dwarn(_t('xmux не ограничивает соединения: ядро собрано на Go 1.27'),
			      _t('при сбое сервера xhttp открывает сотни соединений: память роутера, риск блокировки адреса. Ядро с -tags http2legacy либо на x/net v0.60.0+: docs/engine.md, «Ядро на Go 1.27»'));
	} else {
		dbad(_f('не найден Xray-core (%s)', x), _f('%s xray-core либо задать byway.main.xray_bin', getenv('BW_PKG_FIX')));
	}
	for (let c in [ 'curl', 'nft', 'ip', 'uci' ]) {
		if (dr_have(c)) dok(_f('есть %s', c));
		else dbad(_f('нет %s', c), getenv('BW_PKG_FIX') + ' ' + c);
	}
	// Сама проверка идёт на ucode -- он есть.
	dok(_t('есть ucode (разбор ключей)'));
}

function dr_updates() {
	dr_head(_t('\nОбновления\n'));
	let nvf = getenv('BW_NEWVER'), rnf = getenv('BW_RELNOTE'), num = getenv('BW_NUM');
	let nv = trim(fs.readfile(nvf) ?? '');
	// Раздел не выходит пустым заголовком: пустота читается как «не прошла».
	if (nv === '') {
		let fl = dr_mtime(getenv('BW_UPFAIL')), okm = dr_mtime(getenv('BW_UPOK'));
		if (u('update_check') == '0')
			dok(_t('проверка новых версий выключена'));
		else if (fl != null && (okm == null || fl > okm))
			// Последняя проверка не дошла до GitHub: «новее не найдено» было бы ложью.
			dwarn(_f('проверка новых версий не удалась (ответ GitHub: %s)', rtrim(fs.readfile(getenv('BW_UPFAIL')) ?? '', '\n')),
			      _t('новые выпуски не видны: нет связи с GitHub либо он отвечает отказом. Проверить вручную: byway update --check'));
		else
			dok(_f('новее %s не найдено', num));
	}
	if (nv !== '' && st_ver_gt(nv, num)) {
		// Важность выпуска -- первым словом описания.
		let rn = rtrim(fs.readfile(rnf) ?? '', '\n');
		let hint = rn + ' -- ' + _t('поставить: byway update');
		if (substr(rn, 0, length('ВАЖНО')) == 'ВАЖНО' || substr(rn, 0, 8) == 'CRITICAL' || substr(rn, 0, 1) == '!')
			dbad(_f('важное обновление: %s', nv), hint);
		else
			dwarn(_f('есть новая версия: %s', nv), hint);
	}
	// Автообновление -- только при сумме от установщика: ручную правку
	// архив не перетирает.
	if (u('auto_update') == '1') {
		let bs = getenv('BW_BINSUM');
		if (!fs.stat(bs))
			dwarn(_t('автообновление включено, но происхождение файла неизвестно'),
			      _t('byway положен не установщиком -- обновление пропускается. Лечится запуском install.sh из файлов byway'));
		else if (split(run([ 'md5sum', '/usr/local/bin/byway' ]).out, ' ')[0] != trim(fs.readfile(bs) ?? ''))
			dwarn(_t('автообновление включено, но byway правлен руками'),
			      _t('своя правка не будет перетёрта: обновление пропускается намеренно'));
		else
			dok(_t('автообновление включено'));
		if (u('update_check') == '0')
			dwarn(_t('автообновление включено, но суточная проверка версий выключена'),
			      _t('без проверки версий автообновлению нечего ставить — включить: byway set update_check on'));
		// Окно -- по местному времени, а OpenWrt по умолчанию в UTC. Судим по
		// timezone: часы двигает только он, zonename без zoneinfo -- нет.
		let tzn = dr_uci('system.@system[0].zonename'), tzo = dr_uci('system.@system[0].timezone');
		let h = dr_au_hour();
		if (tzo === '' || tzo == 'UTC' || tzo == 'GMT0' || tzo == 'GMT')
			dwarn(_f('часы роутера идут по UTC (timezone=%s) — окно обновления придётся на %s:00 UTC', tzo || _t('не задан'), h),
			      _t('у вас это не ночь: в Москве это на три часа позже, во Владивостоке на десять — перезапуск службы среди дня. Лечится в LuCI (Система → Общие настройки → Часовой пояс) либо uci set system.@system[0].timezone=... && uci commit system && /etc/init.d/system reload (именно timezone: zonename часы не двигает)'));
		else
			dok(_f('часы %s (%s, смещение %s), обновление в %s:00 по часам роутера — сейчас %s',
			       tzn || _t('без ярлыка'), tzo, trim(run([ 'date', '+%z' ]).out) || '?', h, trim(run([ 'date', '+%H:%M' ]).out)));
		// Провалившийся выпуск больше не ставится сам -- человек должен знать.
		let af = trim(fs.readfile(getenv('BW_AUFAIL')) ?? '');
		if (af !== '')
			dwarn(_f('выпуск %s не поднялся и больше не ставится сам', af),
			      _t('если причина устранена — поставить вручную: byway update --force'));
	}
}

function dr_config() {
	dr_head(_t('\nНастройка\n'));
	let conf = getenv('BW_CONF');
	if (fs.stat(conf)) dok(_f('конфигурация %s', conf));
	else dbad(_f('нет %s', conf), _t('переустановить byway'));
	// По режиму, не по node_url: автовыбор читает node_urls.
	let mode = u('conn_mode');
	if (mode == 'urltest') {
		let k = trim(u('node_urls'));
		let n = k === '' ? 0 : length(split(k, /[ \t\n]+/));
		if (n > 0) dok(_f('ключей для автовыбора: %s', n));
		else dbad(_t('ключи для автовыбора не заданы'), _t('добавить на вкладке «Основное» либо: byway key sub АДРЕС'));
	} else if (mode == 'outbound') {
		if (u('outbound_json') !== '') dok(_t('свой конфиг аутбаунда задан'));
		else dbad(_t('выбран свой конфиг, но он пуст'), _t('вписать кусок JSON на вкладке «Основное»'));
	} else {
		let url = u('node_url');
		if (url === '') dbad(_t('ключ не задан'), _t("вписать на вкладке «Основное» или: byway key 'ССЫЛКА'"));
		else if (substr(url, 0, length('ЗАПОЛНИТЬ')) == 'ЗАПОЛНИТЬ') dbad(_t('ключ не заполнен'), _t('вписать настоящий ключ вместо заглушки'));
		else dok(_f('ключ задан, режим: %s', mode));
	}
	// По объединённому списку: по своему файлу пустым объявлялся и список
	// того, у кого работает пресет.
	let mf = getenv('BW_MERGED'), ms = fs.stat(mf);
	if (ms && ms.size)
		dok(_f('список доменов: %s записей (своих %s)', lj_count(mf), lj_count(getenv('BW_LISTS') + '/domains.lst')));
	else if (u('list_mode') == 'all')
		dok(_t('списки не нужны: режим «всё через VPN»'));
	else
		dwarn(_t('список доменов пуст'), _t('через VPN не пойдёт ничего: наполнить или включить пресет'));
	// Ширина подсетей: одна 0.0.0.0/0 делает «по спискам» полным туннелем.
	let w = g_net_width(getenv('BW_SUBNETS'));
	if (w[0] > 1000000 || w[1] <= 12)
		dwarn(_f('подсети списка: %s адресов, крупнейший блок /%s', w[0], w[1]),
		      _t('в туннель уйдёт и чужой трафик, и скорость упадёт: проверить subnets.lst'));
	let pin = dr_pins(mf);
	if (pin > 0)
		dwarn(_f('пинов в /etc/hosts перебивают записи списка: %s', pin),
		      _t('dnsmasq отвечает по пину сам, подставного адреса не будет — эти домены в туннель не пойдут, и запрет «не пускать мимо VPN» их тоже не закроет'));
	// Перехват держит IPv4; клиент по RFC 6724 предпочитает AAAA.
	if (trim(run([ 'ip', '-6', 'route', 'show', 'default' ]).out) !== '') {
		if (u('ipv6') == '1') {
			let mk = st_mark(), ok = false;
			let re = regexp('fwmark ' + mk + '(/' + mk + ')?[ \t]+lookup ' + ST_RT + '([ \t]|$)');
			for (let l in split(run([ 'ip', '-6', 'rule', 'show' ]).out, '\n')) if (match(l, re)) ok = true;
			if (ok) dok(_t('IPv6 поднят и заворачивается наравне с IPv4'));
			else dbad(_t('IPv6 включён в настройках, но правила для него в ядре нет'), _t('переложить правила: byway plumb on'));
		} else if (u('list_mode') == 'all') {
			dwarn(_t('IPv6 поднят, а перехват только по IPv4'), _t('в режиме «всё через VPN» соединения по IPv6 идут мимо туннеля: выключить IPv6 на WAN либо вернуться к режиму по спискам'));
		} else {
			dwarn(_t('IPv6 поднят, а перехват только по IPv4'), _t('и домены, и подсети закрывают только IPv4: клиент, получивший AAAA, предпочтёт его и уйдёт напрямую. Выключить IPv6 на WAN -- либо помнить, что подсети сервиса его не покрывают'));
		}
	}
	// Биты self_mark и mark не должны пересекаться: пакеты движка ушли бы на
	// петлю при зелёных проверках.
	if (u('router_via_vpn') == '1') {
		let sm = u('self_mark') || '0x400000', mk = u('mark') || '0x100000';
		if (ltrim(sm + mk, '0123456789abcdefABCDEFxX') === '' && (dr_num(sm) & dr_num(mk)) != 0)
			dwarn(_f('self_mark %s пересекается битами с mark %s', sm, mk),
			      _t('byway возьмёт другое значение сам (его видно в byway nft, строка «meta mark … return»); закрепить: byway set self_mark ЗНАЧЕНИЕ'));
	}
}

function dr_dns() {
	dr_head(_t('\nПерехват и соседние службы\n'));
	let pid = st_xray_pid();
	let own = u('dns_listen') || '127.0.0.42';
	if (index(dm_servers(), own) >= 0)
		dok(_t('dnsmasq направлен на byway'));
	else if (u('enabled') != '1' || pid === '')
		dok(_t('dnsmasq не тронут — byway ещё не запущен, так и должно быть'));
	else
		dwarn(_t('dnsmasq не направлен на byway'), _t('правила перехвата сняты: byway plumb on'));
	// Свои апстримы в UCI файлом не отключить: dnsmasq шлёт им часть запросов.
	let fo = dm_foreign(own);
	if (length(fo))
		dwarn(_f('у dnsmasq в настройках свои серверы: %s', join(' ', fo)),
		      _t('часть запросов уходит мимо byway, и сайты из списка открываются через раз — убрать: Сеть → DHCP и DNS → Перенаправления'));
	// dnsmasq один на все мосты, перехват -- только на перечисленных: сеть
	// вне списка получает fakeip и умирает на WAN.
	let bwif = ' ' + u('interface') + ' ', lost = '', outside = '';
	let dh = uci.cursor().get_all('dhcp') ?? {}, net = uci.cursor().get_all('network') ?? {}, secs = [];
	for (let n in dh) if (dh[n]['.type'] == 'dhcp') push(secs, dh[n]);
	secs = sort(secs, (a, b) => a['.index'] - b['.index']);
	for (let s in secs) {
		let ifn = s.interface ?? '';
		if (ifn === '' || s.ignore == '1') continue;
		let br = (net[ifn] ?? {}).device ?? ('br-' + ifn);
		if (index(bwif, ' ' + br + ' ') >= 0) continue;
		outside += ' ' + br;
		// Свой резолвер сети задан через DHCP -- наш ей и не достаётся.
		let opt = s.dhcp_option;
		if (index(type(opt) == 'array' ? join(' ', opt) : (opt ?? ''), '6,') >= 0) continue;
		lost += ' ' + br;
	}
	if (u('list_mode') == 'all' && outside !== '')
		dbad(_f('режим «всё через VPN», а эти сети идут мимо него целиком:%s', outside),
		     _t('в этом режиме byway.main.interface -- граница ВСЕЙ защиты, а не только списков: что вне его, то мимо туннеля и мимо запрета «не пускать мимо VPN». Добавить устройства в byway.main.interface'));
	else if (lost !== '')
		dwarn(_f('сети с резолвером byway, но без перехвата:%s', lost),
		      _t("их клиенты получат подставной адрес, до туннеля не дойдут и потеряют ВЕСЬ список. Лечится одним из двух: добавить сеть в byway.main.interface либо выдать ей свой DNS через dhcp_option '6,…'"));
	else
		dok(_t('перехват и резолвер согласованы по сетям'));
	// Маршрут решает DNS: клиент со своим резолвером идёт мимо туннеля.
	if (u('list_mode') != 'all')
		dwarn(_t('клиент со своим DNS проходит мимо туннеля'),
		      _t('маршрут решает DNS: устройство с «Приватным DNS», DoH в браузере или чужим резолвером в настройках уйдёт напрямую, и byway этого не увидит. Лечится либо выключением шифрованного DNS на устройствах, либо перехватом 53-го порта в firewall, либо добавлением к доменам ПОДСЕТЕЙ сервиса: подсеть работает по адресу, а значит и для того, кто спросил адрес не у роутера. Третий способ проще двух первых, но покрывает ТОЛЬКО IPv4: клиент, получивший AAAA, уйдёт мимо подсетей'));
}

function dr_marks() {
	// Чужое правило по той же метке -- дыра: удаление нашего её не закроет.
	let mk = u('mark') || '0x100000', n = 0;
	for (let l in split(run([ 'uci', 'show', 'firewall' ]).out, '\n'))
		if (index(l, "mark='" + mk) >= 0) n++;
	if (n > 1)
		dwarn(_f('правил firewall с меткой %s: %s', mk, n), _t('лишнее оставит дыру после удаления byway — проверить: uci show firewall | grep mark'));
	else if (n == 0)
		dwarn(_t('правила firewall для помеченного трафика нет'), _t('гостевые и другие зоны с input REJECT остаются без туннеля; byway заводит правило заново при подъёме перехвата: /etc/init.d/byway restart'));
	else
		dok(_f('правил firewall с меткой byway: %s', n));
}

// Файлы каталога по окончанию, по алфавиту (как glob).
function dr_ls(dir, ext) {
	let r = [];
	for (let f in fs.lsdir(dir) ?? [])
		if (substr(f, -length(ext)) == ext && fs.stat(dir + '/' + f)?.type == 'file') push(r, f);
	return sort(r);
}

function dr_files() {
	let routes = getenv('BW_ROUTES'), all = cursor().get_all('byway') ?? {}, secs = [];
	let urls = split(trim(u('node_urls')), /[ \t\n]+/);
	for (let n in all) if (all[n]['.type'] == 'route') push(secs, all[n]);
	secs = sort(secs, (a, b) => a['.index'] - b['.index']);
	for (let s in secs) {
		if (s.enabled == '0') continue;
		let rn = s['.name'], lb = s.label ?? '', has = false;
		for (let k in urls) {
			if (k === '') continue;
			let h = index(k, '#');
			if ((h < 0 ? '' : pk_pctd(substr(k, h + 1))) == lb) { has = true; break; }
		}
		let st = fs.stat(routes + '/' + rn + '.lst');
		if (!has)
			dbad(_f('направление «%s»: ключа с меткой «%s» нет', rn, lb), _t('выбрать существующий ключ либо убрать направление'));
		else if (!st || !st.size)
			dwarn(_f('направление «%s»: список пуст', rn), _t('наполнить список либо убрать направление'));
		else
			dok(_f('направление «%s» ведёт в «%s»', rn, lb));
	}
	// Файл удалённого направления byway не читает, но и не убирает.
	for (let f in dr_ls(routes, '.lst')) {
		let n = substr(f, 0, length(f) - 4);
		if (all[n] != null) continue;
		dwarn(_f('список «%s» лежит без направления и не читается', n), _t('убрать файл, если направление удалено'));
	}
	// Снятая галочка пресета оставляет копию во флеше; включённый -- не
	// обновлялся больше месяца.
	let pd = getenv('BW_PRESETS'), pre = ' ' + u('preset') + ' ';
	for (let f in [ ...dr_ls(pd, '.lst'), ...dr_ls(pd, '.sub') ]) {
		let n = substr(f, 0, length(f) - 4);
		if (index(pre, ' ' + n + ' ') >= 0) {
			if (dr_mtime(pd + '/' + f) < time() - 30 * 86400)
				dwarn(_f('готовый список «%s» не обновлялся больше месяца', n), _t('обновить и заодно свериться с zapret: byway presets'));
		} else {
			dwarn(_f('готовый список «%s» отключён, а копия лежит во флеше', n), _t('включить обратно или убрать файл из /etc/byway/presets'));
		}
	}
}

function dr_rivals() {
	let pid = st_xray_pid();
	let mk = st_mark(), re = regexp('fwmark ' + mk + '(/' + mk + ')?[ \t]+lookup ' + ST_RT + '([ \t]|$)');
	for (let nb in [ [ 'podkop', 'podkop' ], [ 'passwall', 'passwall' ], [ 'passwall2', 'passwall2' ],
	                 [ 'openclash', 'openclash' ], [ 'nikki', 'nikki' ], [ 'homeproxy', 'homeproxy' ],
	                 [ 'shadowsocks-libev', 'shadowsocks' ] ]) {
		let ni = nb[0], nn = nb[1], init = '/etc/init.d/' + ni;
		if (run([ 'test', '-x', init ]).code != 0) continue;
		// Живой процесс важнее автозапуска; след в ядре -- своя таблица nft
		// либо правило на таблицу 100 (свои правила byway не считаются).
		let trace = false;
		for (let l in split(run([ 'nft', 'list', 'tables' ]).out, '\n'))
			if (lc(substr(l, -length(ni) - 1)) == ' ' + lc(ni)) trace = true;
		if (pid === '')
			for (let l in split(run([ 'ip', 'rule', 'show' ]).out, '\n'))
				if (index(l, 'lookup ' + ST_RT) >= 0 && !match(l, re)) trace = true;
		if (trace)
			dbad(_f('рядом РАБОТАЕТ %s', nn), _f('след виден в ядре: своя таблица nft либо правило на таблицу маршрутизации %s. Оставить что-то одно: /etc/init.d/%s stop && /etc/init.d/%s disable', ST_RT, ni, ni));
		else if (run([ init, 'running' ]).code == 0)
			dbad(_f('рядом РАБОТАЕТ %s', nn), _f('он метит трафик и перехватывает те же порты — оставить что-то одно: /etc/init.d/%s stop && /etc/init.d/%s disable', ni, ni));
		else if (run([ init, 'enabled' ]).code == 0)
			dwarn(_f('рядом включён %s', nn), _t('он метит трафик и перехватывает те же порты — оставить что-то одно'));
		else
			dok(_f('%s установлен, но выключен', nn));
	}
	// pbr уживается, если метки и таблицы не пересекаются.
	if (run([ 'test', '-x', '/etc/init.d/pbr' ]).code == 0 && run([ '/etc/init.d/pbr', 'enabled' ]).code == 0)
		dwarn(_t('рядом включён pbr'), _f('он тоже метит трафик и правит ip rule: его метки и таблицы не должны совпадать с меткой byway %s и таблицей %s', u('mark') || '0x100000', ST_RT));
}

function dr_ports() {
	let tp = u('tproxy_port') || '1602', lp = u('local_proxy_port') || '1603';
	let pairs = [ [ tp, _t('вход tproxy') ], [ lp, _t('прокси роутера') ] ];
	let ns = split(run([ 'netstat', '-lnp' ]).out, '\n');
	for (let pp in pairs) {
		let who = {}, wl = [];
		let re = regexp('[:.]' + pp[0] + '[ \t]');
		for (let l in ns) {
			if (!match(l, re)) continue;
			let f = split(trim(l), /[ \t]+/), w = f[length(f) - 1];
			if (w != '-' && !who[w]) { who[w] = true; push(wl, w); }
		}
		let ws = length(wl) ? join(' ', sort(wl)) + ' ' : '';
		if (ws === '' || index(ws, 'xray') >= 0)
			dok(_f('%s (порт %s) свободен или занят byway', pp[1], pp[0]));
		else
			dwarn(_f('%s (порт %s) занят: %s', pp[1], pp[0], ws), _t('сменить порт в настройках byway либо убрать чужую службу'));
	}
	let tbl = run([ 'nft', 'list', 'table', 'inet', ST_TABLE ]).code == 0;
	// Заворот включён настройкой, работает цепочкой в ядре: спрашивать только
	// при стоящем перехвате.
	if (u('router_via_vpn') == '1' && tbl) {
		if (run([ 'nft', 'list', 'chain', 'inet', ST_TABLE, 'output' ]).code == 0) {
			if (st_plain_first(getenv('BW_MERGED')) !== '')
				dok(_t('роутер ходит к сайтам из списка сам'));
			else
				dwarn(_t('VPN для программ на роутере (router_via_vpn) включён, но список пуст — ловить нечего'),
				      _t('VPN для программ на роутере работает по доменам списка: наполнить список либо подключить готовый'));
		} else {
			dwarn(_t('VPN для программ на роутере (router_via_vpn) включён, но цепочки в ядре нет'), _t('переложить правила: byway plumb on'));
		}
	} else if (u('router_via_vpn') != '1') {
		dwarn(_t('роутер сам до сайтов из списка не достаёт'),
		      _t('VPN для программ на роутере (router_via_vpn) выключен: программы на роутере — обновления zapret, свои скрипты — виснут на подставном адресе до таймаута. Включить: byway set router_via_vpn on'));
	}
	// Правило и маршрут снимают разные руки: сосед уносит маршрут, а
	// перехват выглядит исправным.
	if (tbl) {
		let route = false;
		for (let l in split(run([ 'ip', 'route', 'show', 'table', ST_RT ]).out, '\n'))
			if (substr(l, 0, 13) == 'local default') route = true;
		if (!route)
			dbad(_f('в таблице маршрутизации %s нет маршрута local default', ST_RT), _t('переложить правила: byway plumb on'));
	}
	let rc = dr_rule_count();
	if (rc > 1)
		dwarn(_f('правил ip rule на таблицу %s: %s', ST_RT, rc), _t('лишние копятся при перезапусках — снять: byway plumb on'));
}

// Все разделы; итог -- число неисправностей.
function dr_run() {
	DR_BAD = 0;
	print(_f('byway %s — проверка окружения\n\n', getenv('BW_VERSION')));
	dr_system();
	dr_needs();
	dr_updates();
	dr_config();
	dr_dns();
	dr_marks();
	dr_files();
	dr_rivals();
	dr_ports();
	print('\n');
	if (DR_BAD == 0) say('окружение в порядке');
	else warnf('неисправностей: %s — способ лечения указан у каждой', DR_BAD);
	return DR_BAD;
}

function cmd_doctor() { if (dr_run() > 0) exit(1); }

// ── отчёт ─────────────────────────────────────────────────────────────────
// Ключи настроек -- по белому списку: новая настройка с секретом закрыта.
const RP_KEYS = [ 'enabled', 'conn_mode', 'list_mode', 'ru_direct', 'preset', 'interface',
	'fakeip_pool', 'dns_upstream', 'dns_upstream2', 'dns_bootstrap', 'dns_listen', 'tproxy_port',
	'local_proxy_port', 'router_via_vpn', 'mark', 'self_mark', 'log_level', 'ipv6',
	'fakeip6_pool', 'show_usage', 'mux_concurrency', 'probe_interval', 'guard', 'block_quic',
	'allow_insecure', 'lang', 'xray_bin', 'conn_label' ];

function rp_r(s) { print(s, '\n'); }

// Подпись и значение; колонка -- в символах, не байтах.
function rp_v(label, v) {
	let p = 16 - sa_width(label);
	if (p < 1) p = 1;
	let pad = '';
	for (let i = 0; i < p; i++) pad += ' ';
	print(label, pad, v, '\n');
}

// Вымарка адресов и имён: отчёт уходит постороннему.
function rp_mask(s) {
	s = replace(s, /[0-9]{1,3}(\.[0-9]{1,3}){3}/g, 'x.x.x.x');
	s = replace(s, /\[[0-9a-fA-F]*:[0-9a-fA-F:]*\]|[0-9a-fA-F]*::[0-9a-fA-F:]+/g, 'x::x');
	return replace(s, /([A-Za-z0-9-]+\.)+[A-Za-z]{2,}/g, _t('ИМЯ'));
}

function rp_tail(lines, n) { return slice(lines, length(lines) > n ? length(lines) - n : 0); }

// bw_uc report: отчёт целиком в stdout; файл и права -- у shell.
function cmd_report() {
	PLAIN = true;
	rp_r(_t('# byway report 1'));
	print('# ', _t('снято'), ': ', trim(run([ 'date', '+%Y-%m-%d %H:%M' ]).out), '\n');
	rp_r(_t('# ключ от VPN, адрес сервера и адрес подписки сюда НЕ попадают'));
	print('\n');
	rp_r(_t('== устройство =='));
	rp_v(_t('byway'), getenv('BW_VERSION'));
	let fw = match(fs.readfile('/etc/openwrt_release') ?? '', /(^|\n)DISTRIB_DESCRIPTION=([^\n]*)/);
	rp_v(_t('прошивка'), fw ? replace(fw[2], "'", '') : '?');
	let model = trim(fs.readfile('/tmp/sysinfo/model') ?? '');
	if (model === '') model = replace(fs.readfile('/proc/device-tree/model') ?? '', '\0', '');
	rp_v(_t('железо'), (model || '?') + ' (' + trim(run([ 'uname', '-m' ]).out) + ')');
	rp_v(_t('ядро'), trim(run([ 'uname', '-r' ]).out));
	let df = split(split(run([ 'df', '-h', '/overlay' ]).out, '\n')[1] ?? '', /[ \t]+/);
	rp_v(_t('флеш'), df[3] != null ? df[3] + ' / ' + df[1] : '');
	let fr = '';
	for (let l in split(run([ 'free' ]).out, '\n'))
		if (substr(l, 0, 4) == 'Mem:') {
			let f = split(trim(l), /[ \t]+/);
			fr = int(int(f[3]) / 1024) + ' / ' + int(int(f[1]) / 1024) + ' MB';
		}
	rp_v(_t('память'), fr);
	print('\n');
	rp_r(_t('== окружение =='));
	dr_run();
	print('\n');
	rp_r(_t('== состояние =='));
	cmd_status();
	print('\n');
	rp_r(_t('== проверка =='));
	cmd_health();
	print('\n');
	rp_r(_t('== подключение (без значений) =='));
	// В автовыборе разбирается первый ключ списка (node_url там нет).
	let rk = '', mode = u('conn_mode');
	if (mode == 'urltest' || mode == 'selector') rk = split(trim(u('node_urls')), /[ \t\n]+/)[0] ?? '';
	let N = hl_key(rk);
	if (N) {
		rp_v(_t('протокол'), N.PROTO);
		rp_v(_t('транспорт'), N.TYPE);
		rp_v(_t('защита'), N.SEC);
		if ((N.FLOW ?? '') !== '') rp_v(_t('flow'), N.FLOW);
		rp_v(_t('порт'), N.PORT);
	} else {
		rp_r(_t('ключ не разбирается -- это и есть повод для обращения'));
	}
	print('\n');
	rp_r(_t('== настройки =='));
	for (let l in split(rtrim(run([ 'uci', '-q', 'show', 'byway' ]).out, '\n'), '\n')) {
		if (l === '') continue;
		if (l == 'byway.main=byway') { rp_r(l); continue; }
		let e = index(l, '='), k = substr(l, 0, e < 0 ? length(l) : e);
		let kk = substr(k, rindex(k, '.') + 1);
		if (index(RP_KEYS, kk) >= 0) rp_r(l);
		else print(_f('%s=<скрыто>\n', k));
	}
	print('\n');
	rp_r(_t('== списки =='));
	let lists = getenv('BW_LISTS');
	rp_v(_t('своих доменов'), lj_count(lists + '/domains.lst'));
	rp_v(_t('всего доменов'), lj_count(getenv('BW_MERGED')));
	rp_v(_t('своих подсетей'), lj_count(lists + '/subnets.lst'));
	rp_v(_t('всего подсетей'), lj_count(getenv('BW_SUBNETS')));
	rp_v(_t('пресеты'), u('preset'));
	let bad = {}, nb = 0;
	for (let l in split(fs.readfile(getenv('BW_BADLIST')) ?? '', '\n')) if (l !== '' && !bad[l]) { bad[l] = true; nb++; }
	rp_v(_t('отброшено строк'), nb);
	print('\n');
	rp_r(_t('== перехват =='));
	// Элементы наборов не печатаем: сотни строк подсетей.
	let nt = run([ 'nft', 'list', 'table', 'inet', ST_TABLE ]);
	if (nt.code != 0) rp_r(_t('таблицы нет'));
	else
		for (let l in split(rtrim(nt.out, '\n'), '\n'))
			if (!match(l, /^[ \t]*(elements|[0-9]+\.[0-9]+)/)) rp_r(l);
	print('\n');
	let mk = st_mark(), re = regexp('fwmark ' + mk + '(/' + mk + ')?[ \t]+lookup ' + ST_RT + '([ \t]|$)'), any = false;
	for (let l in split(run([ 'ip', 'rule', 'show' ]).out, '\n')) if (match(l, re)) { rp_r(l); any = true; }
	if (!any) rp_r(_t('правила ip rule нет'));
	print(run([ 'ip', 'route', 'show', 'table', ST_RT ]).out);
	print('\n');
	rp_r(_t('== журнал состояния (последние 20) =='));
	let wl = run([ 'tail', '-20', getenv('BW_WATCH_LOG') ]);
	if (wl.code != 0) rp_r(_t('пусто')); else print(wl.out);
	print('\n');
	rp_r(_t('== системный журнал byway (последние 30) =='));
	// watch пишет сюда имя и адрес сервера; строки crond о задачах byway
	// вытесняли бы сообщения самой программы.
	let bl = [];
	for (let l in split(run([ 'logread', '-e', 'byway' ]).out, '\n'))
		if (l !== '' && !match(l, / cron\.[a-z]* crond\[/)) push(bl, l);
	for (let l in rp_tail(bl, 30))
		print(replace(replace(l, /[0-9]{1,3}(\.[0-9]{1,3}){3}/g, 'x.x.x.x'), /([A-Za-z0-9-]+\.)+[A-Za-z]{2,}/g, _t('ИМЯ')), '\n');
	print('\n');
	rp_r(_t('== системный журнал движка (последние 20) =='));
	// Только жалобы движка: в строках обращений адрес каждого сайта.
	let xl = [];
	for (let l in split(run([ 'logread', '-e', 'xray' ]).out, '\n'))
		if (match(l, /error|warn|fail|reject/i) && index(l, 'tproxy-in') < 0) push(xl, l);
	for (let l in rp_tail(xl, 20)) {
		l = replace(l, /^([A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]+ [0-9:]+ [0-9]{4}) [^:]*: /, (m, a) => a + ' ');
		print(rp_mask(l), '\n');
	}
}
