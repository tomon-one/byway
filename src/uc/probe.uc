// Проверки ключа без боевого конфига (бывший config/probe.sh): check -- разбор
// и `run -test`, probe -- одно соединение через ноду. Боевой конфиг, nft и
// dnsmasq не трогаются -- можно на работающем роутере.

const PR_CHECK = '/tmp/byway-check.json';
const PR_CFG = '/tmp/byway-probe.json';
const PR_LOG = '/tmp/byway-probe.log';
const PR_OUT = '/tmp/byway-probe.out';
// pid движка пробы: по нему shell-обёртка гасит движок, если probe прервали
// (Ctrl+C) -- сам ucode сигналы не ловит. Каталог root, не общий /tmp: иначе
// чужой процесс подложил бы номер, и root убил бы его.
const PR_PID = '/var/run/byway/probe.pid';

function pr_xray() {
	let x = xray_bin();
	if (run([ 'test', '-x', x ]).code != 0)
		dief('движка нет (%s) — ключ проверить нечем; сам ключ тут ни при чём', x);
	return x;
}

// Черновик с uuid: права 600 до записи; после проверки -- пустой файл.
function pr_write(file, o) {
	fs.unlink(file);
	let f = fs.open(file, 'w', 0600);
	if (!f) dief('черновик конфига %s не записан: %s', file, fs.error());
	f.write(sprintf('%.2J\n', o));
	f.close();
}

function pr_clear(files) { for (let f in files) if (fs.stat(f)) fs.writefile(f, ''); }

// Ключ -> { N, block }; сообщения разбора печатаются по порядку. Отказ: soft --
// null (probe --all идёт дальше), иначе выход, как die в shell.
function pr_key(url, soft) {
	OB_OUT = [];
	OB_FATAL = null;
	let k = null;
	try {
		k = ob_key(url, 'proxy', '', '');
	} catch (e) {
		if (e.message !== OB_STOP) raise(e.message);
	}
	if (!ob_emit(OB_OUT, soft)) return null;
	return k;
}

// Последние n строк текста.
function pr_tail(s, n) {
	let ls = split(rtrim(s, '\n'), '\n');
	return slice(ls, length(ls) > n ? length(ls) - n : 0);
}

// bw_uc check [ССЫЛКА]: принимает ли Xray этот ключ, без процесса и сокета.
// Без ссылки разбор сам берёт ключ из настроек или свой конфиг.
function cmd_check(url) {
	let x = pr_xray();
	let k = pr_key(url ?? '', false);
	let N = k.N;
	pr_write(PR_CHECK, { log: { loglevel: 'warning' }, outbounds: [ k.block ] });
	print(sprintf('  %-12s %-10s %s:%s  ', N.TYPE, N.SEC, N.HOST, N.PORT));
	let r = run([ x, 'run', '-test', '-c', PR_CHECK ], true);
	pr_clear([ PR_CHECK ]);
	if (r.code == 0) {
		print(_t('ПРИНЯТ\n'));
		return;
	}
	print(_t('ОТВЕРГНУТ\n'));
	let l = pr_tail(r.out, 1)[0] ?? '';
	let i = rindex(l, '> ');
	print(i < 0 ? l : '    ' + substr(l, i + 2), '\n');
	g_xray_hint(r.out);
	exit(1);
}

// Одна проба: true -- связь через ноду состоялась.
// В терминале (BW_TTY от shell) -- строка на ключ, цветом; панель читает
// прежний вид: заголовок «[*] ключ N имя» и строка под ним.
let PR_TTY = getenv('BW_TTY') == '1';

function pr_one(x, url, soft, name) {
	let k = pr_key(url, soft);
	if (!k) return false;
	let N = k.N;
	let port = int(getenv('PROBE_PORT') || '15080');
	pr_write(PR_CFG, {
		log: { loglevel: 'warning' },
		inbounds: [ { tag: 's', listen: '127.0.0.1', port: port, protocol: 'socks', settings: { udp: true } } ],
		outbounds: [ k.block ],
	});
	if (PR_TTY && name != null) print('  ', c_pad(name, 18), ' ');
	print(sprintf(PR_TTY ? '\033[2m%-16s %-22s\033[0m ' : '  %-12s %-22s ', N.TYPE + '/' + N.SEC, N.HOST + ':' + N.PORT));
	let t = run([ x, 'run', '-test', '-c', PR_CFG ], true);
	if (t.code != 0) {
		print(PR_TTY ? '\033[1;31m' + rtrim(_t('конфиг отвергнут ядром\n'), '\n') + '\033[0m\n' : _t('конфиг отвергнут ядром\n'));
		for (let l in pr_tail(t.out, 2)) print('      ', l, '\n');
		g_xray_hint(t.out);
		pr_clear([ PR_CFG ]);
		return false;
	}
	// Движок -- в фоне через sh: system() ждал бы его выхода.
	let pid = trim(run([ 'sh', '-c', '"$1" run -c "$2" > "$3" 2>&1 & echo $!', 'sh', x, PR_CFG, PR_LOG ]).out);
	if (!fs.stat('/var/run/byway')) fs.mkdir('/var/run/byway', 0755);
	fs.writefile(PR_PID, pid + '\n');
	system([ 'sleep', '3' ]);
	let c = run([ 'curl', '-s', '--max-time', '15', '--socks5-hostname', '127.0.0.1:' + port,
	              '-w', '%{http_code} %{time_total}', '-o', PR_OUT,
	              getenv('PROBE_URL') || 'https://api.ipify.org' ]);
	// Неудачный curl печатает «000 15.0» -- это не ответ.
	let R = c.code == 0 ? c.out : '';
	let ip = substr(fs.readfile(PR_OUT) ?? '', 0, 40);
	system([ 'kill', pid ]);
	// Ждать выхода: probe --all следом займёт тот же порт.
	for (let i = 0; i < 5 && fs.stat('/proc/' + pid); i++) system([ 'sleep', '1' ]);
	fs.unlink(PR_PID);
	let sp = index(R, ' ');
	let code = sp < 0 ? R : substr(R, 0, sp), time = substr(R, rindex(R, ' ') + 1);
	// Любой трёхзначный код -- связь состоялась (302, 403 Cloudflare).
	let ok = match(code, /^[1-5][0-9][0-9]$/) != null;
	if (ok && PR_TTY) {
		print('\033[1;32m', rtrim(_f('РАБОТАЕТ  выход %-16s %s с\n', ip, sprintf('%.2f', +time)), '\n'), '\033[0m\n');
	} else if (ok) {
		print(_f('РАБОТАЕТ  выход %-16s %s с\n', ip, time));
	} else {
		let nw = _f('НЕ РАБОТАЕТ (код %s)\n', code !== '' ? code : _t('нет ответа'));
		print(PR_TTY ? '\033[1;31m' + rtrim(nw, '\n') + '\033[0m\n' : nw);
		let bad = [];
		for (let l in split(fs.readfile(PR_LOG) ?? '', '\n'))
			// Предупреждения Xray («WebSocket устарел») -- не причина отказа.
			if (match(l, /fail|error|reject/i) && !match(l, /\[(Warning|Info|Debug)\]/)) push(bad, l);
		for (let l in slice(bad, length(bad) > 2 ? length(bad) - 2 : 0)) print('      ', l, '\n');
	}
	pr_clear([ PR_CFG, PR_LOG, PR_OUT ]);
	return ok;
}

// bw_uc probe [ССЫЛКА|--all]: соединение через ноду со своим socks-входом.
// PROBE_URL -- сайт вместо выхода; PROBE_PORT -- порт входа.
function cmd_probe(arg) {
	let x = pr_xray();
	if (arg == '--all') {
		// Каждый ключ автовыбора отдельно; негодный не обрывает остальных.
		let keys = split(trim(u('node_urls')), /[ \t\n]+/);
		if (keys[0] == '') die('ключей автовыбора нет (byway.main.node_urls) — проверять нечего');
		let i = 0, okn = 0;
		for (let k in keys) {
			i++;
			let h = rindex(k, '#'), nm = h < 0 ? '' : pk_pctd(substr(k, h + 1));
			if (PR_TTY) {
				fs.stdout?.flush();
				if (pr_one(x, k, true, nm !== '' ? nm : _f('ключ %s', i))) okn++;
				continue;
			}
			print('\n');
			sayf('ключ %s %s', i, nm);
			if (pr_one(x, k, true)) okn++;
		}
		if (PR_TTY) {
			let col = okn == i ? '\033[1;32m' : (okn ? '\033[1;33m' : '\033[1;31m');
			print('\n  ', col, _f('работают %s из %s', okn, i), '\033[0m\n');
			return;
		}
		print('\n');
		sayf('работают %s из %s', okn, i);
		return;
	}
	let url = arg ?? '';
	// Без аргумента в режиме «свой конфиг» проверяется он, как у check.
	if (url === '' && u('conn_mode') != 'outbound') {
		url = u('node_url');
		if (url === '') die('ссылка не задана: передать аргументом либо записать в byway.main.node_url');
	}
	if (!pr_one(x, url, false)) exit(1);
}

// bw_uc show: собранный конфиг без секретов. Счётчики -- по источнику
// (BW_MERGED, BW_SUBNETS от shell): в конфиге список дважды.
function cmd_show() {
	let out = getenv('BW_OUT');
	let st = fs.stat(out);
	if (!st) die('конфиг не собран, собрать: byway gen');
	sayf('%s — %s байт', out, st.size);
	print(_f('    доменов в правиле: %s\n', lj_count(getenv('BW_MERGED'))));
	print(_f('    подсетей:          %s\n', lj_count(getenv('BW_SUBNETS'))));
	let f = fs.open(out, 'r'), l, n = 0;
	while (n < 20 && (l = f.read('line')) != null && l !== '') {
		// Строки списков (без «": ») -- мимо регулярки: она дорогая.
		if (index(l, '": ') < 0) continue;
		for (let m in match(l, /"(tag|protocol|network|security|address|ipPool)": *"[^"]*"/g) ?? []) {
			let lm = lc(m[0]);
			if (index(lm, 'uuid') >= 0 || index(lm, 'id"') >= 0) continue;
			print('    ', m[0], '\n');
			if (++n >= 20) break;
		}
	}
	f.close();
}
