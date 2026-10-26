// Ядро Xray (бывший update/engine.sh): byway engine ВЕРСИЯ|tested|newest|
// stable|restore|ФАЙЛ -- загрузка со сверкой sha256, замена рядом или через
// память, откат. Замок и уборку рабочего каталога держит shell-обёртка;
// фаза «через память» (служба стоит) идёт отдельным процессом с игнором INT и
// HUP: ucode сигналов не ловит, а оборванная там замена оставляла бы дом без
// туннеля.
//
// Два ядра по ~35 МБ на 43 МБ раздела не встают: при месте новое кладётся
// рядом, иначе служба стоит, а ядро проверяется в /tmp. Архив прежней версии
// берётся ДО остановки. SHA2-256 из .dgst -- от битой загрузки, не подпись.

// Ядро с GitHub на этом процессоре не запустилось: метка во флеше, чтобы
// восстановление не качало 14 МБ каждые четверть часа. Снимается удачей.
const EN_NOEXEC = '/etc/byway/.github-noexec';
const EN_LOCK = '/var/run/byway-engine.lock';
// Рабочий каталог (для обёртки) и метка фазы «через память»: с ней обёртка
// каталог не трогает -- там архив прежнего ядра, единственное средство отката.
const EN_DIRF = '/var/run/byway-engine.dir';
const EN_RAMF = '/var/run/byway-engine.ram';

// Состояние замены: asset, old, ov, nw (версия), new (путь), d (каталог),
// pkg, sz, free, tun0, orb.
let E = {};

function en_uname() { return trim(run([ 'uname', '-m' ]).out); }
function en_noexec_mark() { fs.writefile(EN_NOEXEC, en_uname() + '\n'); }

// Сборки XTLS на MIPS без сопроцессора не запускаются (только hardfloat) --
// та же проверка в install.sh, править парой.
function en_mips_nofpu() {
	if (substr(en_uname(), 0, 4) != 'mips') return false;
	let ci = fs.readfile('/proc/cpuinfo') ?? '';
	return ci !== '' && index(lc(ci), 'fpu') < 0;
}

// Имя файла выпуска под эту машину -- та же функция в install.sh, править
// парой. DISTRIB_ARCH первым: uname -m на MIPS не различает порядок байтов.
function en_asset() {
	let m = match(fs.readfile('/etc/openwrt_release') ?? '', /\nDISTRIB_ARCH='([^']*)'/), a = m ? m[1] : '';
	for (let p in [ [ 'aarch64', 'linux-arm64-v8a' ], [ 'mipsel_', 'linux-mips32le' ], [ 'mips64el_', 'linux-mips64le' ],
	                [ 'mips64_', 'linux-mips64' ], [ 'mips_', 'linux-mips32' ], [ 'x86_64', 'linux-64' ],
	                [ 'i386', 'linux-32' ], [ 'i486', 'linux-32' ], [ 'i686', 'linux-32' ], [ 'riscv64', 'linux-riscv64' ] ])
		if (substr(a, 0, length(p[0])) == p[0]) return p[1];
	let u = en_uname();
	let t = { aarch64: 'linux-arm64-v8a', armv7l: 'linux-arm32-v7a', armv7: 'linux-arm32-v7a', arm: 'linux-arm32-v7a',
	          armv6l: 'linux-arm32-v6', x86_64: 'linux-64', i386: 'linux-32', i486: 'linux-32', i686: 'linux-32',
	          mips: 'linux-mips32', mipsel: 'linux-mips32le', mips64: 'linux-mips64', mips64el: 'linux-mips64le',
	          riscv64: 'linux-riscv64' };
	return t[u];
}

// Версия ядра по пути: второе поле первой строки `version`, только цифры.
function en_ver(p) {
	if (!p || !(fs.stat(p)?.mode & 73)) return '';
	let w = pl_words(split(run([ p, 'version' ]).out, '\n')[0] ?? '');
	return replace(w[1] ?? '', /[^0-9.]/g, '');
}

// Номер выпуска XTLS: stable -- releases/latest, any -- самый свежий. У XTLS
// предвыпуском помечено всё новее 26.3.27, и «latest» отдаёт мартовский.
function en_top(kind) {
	let url = kind == 'stable' ? 'https://api.github.com/repos/XTLS/Xray-core/releases/latest'
	                          : 'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1';
	let f = '/var/run/byway-engine-top.json';
	fs.unlink(f);
	if (nt_get([ '--max-time', '25', '-o', f, url ]) != 0) { fs.unlink(f); return ''; }
	let t = fs.readfile(f) ?? '';
	fs.unlink(f);
	for (let l in split(t, '\n')) {
		let m = match(l, /.*"tag_name"[^"]*"v([^"]*)"/);
		if (m) return m[1];
	}
	return '';
}

// Архив версии в файл, со сверкой суммы: 0 -- лежит и сверен, 1 -- не
// скачался, 2 -- сумма не сошлась или её нет, 3 -- не сошлась с суммой,
// вшитой в подписанный byway для проверенной версии. Файла при отказе нет.
function en_fetch(ver, f) {
	let url = 'https://github.com/XTLS/Xray-core/releases/download/v' + ver + '/Xray-' + E.asset + '.zip';
	fs.unlink(f); fs.unlink(f + '.dgst');
	if (nt_get([ '--max-time', '300', '-o', f, url ]) != 0) { fs.unlink(f); return 1; }
	if (nt_get([ '--max-time', '30', '-o', f + '.dgst', url + '.dgst' ]) != 0) { fs.unlink(f); fs.unlink(f + '.dgst'); return 2; }
	let w = '';
	for (let l in split(fs.readfile(f + '.dgst') ?? '', '\n')) {
		let m = match(l, /^SHA2-256= *([0-9a-f]{64})/);
		if (m) { w = m[1]; break; }
	}
	fs.unlink(f + '.dgst');
	let g = up_sha256(f);
	if (w === '' || w != g) { fs.unlink(f); return 2; }
	// Подменивший архив подменил бы и .dgst рядом с ним.
	if (ver == getenv('BW_XTESTED')) {
		for (let l in split(getenv('BW_XSUMS') ?? '', '\n'))
			if (substr(l, 0, length(E.asset) + 1) == E.asset + '=' && substr(l, length(E.asset) + 1) != g) {
				fs.unlink(f);
				return 3;
			}
	}
	return 0;
}

// Бинарник xray из пакета -- в файл: .gz -- своя сборка, иначе архив XTLS.
function en_cat(pkg, out) {
	let c = substr(pkg, -3) == '.gz' ? 'gunzip -c "$1" > "$2"' : 'unzip -p "$1" xray > "$2"';
	return run([ 'sh', '-c', c, 'sh', pkg, out ]).code == 0;
}

// Размер ядра внутри архива, байты; пусто -- в архиве нет файла xray.
function en_size(pkg) {
	if (substr(pkg, -3) == '.gz') return trim(run([ 'sh', '-c', 'gunzip -c "$1" | wc -c', 'sh', pkg ]).out);
	for (let l in split(run([ 'unzip', '-l', pkg, 'xray' ]).out, '\n')) {
		let w = pl_words(l);
		if (length(w) && w[length(w) - 1] == 'xray') return w[0];
	}
	return '';
}

// Ядро из архива в путь: через временное имя, размер и запуск -- ДО замены
// (2026-10-04: недописанное на полный диск ядро заменило рабочее). 0 / 1 --
// не распаковалось / 2 -- распаковано, но не запускается.
function en_put(pkg, path, sz) {
	let n = path + '.new';
	fs.unlink(n);
	if (!en_cat(pkg, n) || !fs.stat(n)?.size || !fs.chmod(n, 0755) || (sz && '' + fs.stat(n).size != '' + sz)) {
		fs.unlink(n);
		return 1;
	}
	if (run([ n, 'version' ]).code != 0) { fs.unlink(n); return 2; }
	if (fs.rename(n, path)) return 0;
	fs.unlink(n);
	return 1;
}

function en_free_kb() { return int(pl_words(split(run([ 'df', '-k', '/usr/local/bin' ]).out, '\n')[1] ?? '')[3] ?? '0'); }
function en_mem_kb() {
	let m = match(fs.readfile('/proc/meminfo') ?? '', /MemAvailable:[ \t]+([0-9]+)/);
	return m ? int(m[1]) : 0;
}
function en_mb(kb) { return int(kb / 1024); }

// Конфиг под движок тем же gen: развилки по версии берутся от НОВОГО
// движка, он же проверяет итог. Вывод -- в журнал каталога.
function en_gen(x) {
	let r = run([ 'env', 'BW_GEN_XRAY=' + x, getenv('BW_SELF'), 'gen' ], true);
	fs.writefile(E.d + '/gen.log', r.out);
	return r.code == 0;
}
function en_gen_tail() {
	let l = pl_lines(fs.readfile(E.d + '/gen.log'));
	for (let x in slice(l, -6)) print('    ', x, '\n');
}

// Без выхода по отказу: на пути «через память» он случается при
// остановленной службе.
function en_bin_set(p) {
	if (run([ 'uci', 'set', 'byway.main.xray_bin=' + p ]).code != 0 || !uci_commit('byway'))
		warnf('путь к движку не записался в настройки: byway set xray_bin %s', p);
}

function en_svc(a) { run([ '/etc/init.d/byway', a ]); }
// Этап долгой замены -- выделенной строкой: видно, где сейчас идёт работа.
function en_stage(s) { print('\n\033[1m→ ', s, '\033[0m\n'); }

function en_done() { print('\n\033[1;32m', _f('готово: Xray %s, на флеше свободно %s МБ', E.nw, en_mb(en_free_kb())), '\033[0m\n'); }

// Путь «ядра нет» (после sysupgrade или снятого пакета): ставится без отката.
// 25 МБ, как у установщика: ubifs дожимает ядро примерно вдвое.
function en_fresh() {
	if (E.free < 25600) dief('на флеше свободно %s МБ, ядру нужно %s — ничего не тронуто', en_mb(E.free), 25);
	en_stage(_f('ядра нет — ставится Xray %s', E.nw));
	let r = en_put(E.pkg, E.new, E.sz);
	if (r == 2) { en_noexec_mark(); die('ядро не запускается на этом железе — удалено'); }
	if (r != 0) die('ядро не распаковалось на флеш — ничего не тронуто');
	fs.unlink(EN_NOEXEC);
	en_bin_set(E.new);
	logf('движок поставлен: %s (прежнего не было)', E.nw);
	if (u('enabled') == '1') {
		en_stage(_t('запуск службы'));
		en_svc('restart');
	}
	en_done();
}

// Путь «рядом». Прежнее ядро не трогается до успеха: откат -- вернуть путь.
function en_side() {
	en_stage(_t('места хватает — новое ядро кладётся рядом с прежним'));
	let r = en_put(E.pkg, E.new, E.sz);
	fs.unlink(E.pkg);
	if (r == 2) { en_noexec_mark(); die('новое ядро не запускается на этом железе — удалено, работает прежнее'); }
	if (r != 0) die('ядро не распаковалось на флеш — ничего не тронуто');
	let ours = substr(E.old, 0, 20) == '/usr/local/bin/xray-';
	if (up_idle()) {
		en_bin_set(E.new);
		if (ours) fs.unlink(E.old);
		sayf('служба не работает (выключена или нет ключа) — ядро заменено без проверки туннеля: Xray %s', E.nw);
		return;
	}
	if (!en_gen(E.new)) {
		en_gen_tail();
		fs.unlink(E.new);
		en_gen(E.old);
		die('новый движок не принял конфиг — удалён, работает прежний');
	}
	en_bin_set(E.new);
	warn('перезапуск службы: туннель пропадёт на несколько секунд');
	en_svc('restart');
	en_stage(_t('проверка туннеля на новом движке (до 2,5 минуты)'));
	if (up_wait(E.tun0)) {
		// Удаляется, только если ядро наше: /usr/bin/xray -- файл пакета.
		if (ours) {
			fs.unlink(E.old);
			sayf('прежний движок удалён: %s', E.old);
		} else {
			sayf('прежний движок %s — из пакета, оставлен; снять можно пакетным менеджером', E.old);
		}
		logf('движок заменён: %s -> %s', E.ov, E.nw);
		en_done();
		return;
	}
	warn('туннель на новом движке не поднялся — возврат прежнего');
	en_bin_set(E.old);
	en_gen(E.old);
	en_svc('restart');
	fs.unlink(E.new);
	logf('движок: %s не поднялся, возвращён %s', E.nw, E.ov);
	dief('возвращён %s; новое ядро удалено', E.ov);
}

// Путь «через память», подготовка (процесс обёртки): архив прежней версии --
// СЕЙЧАС, пока туннель жив; потом -- дочерний процесс без INT и HUP.
function en_ram() {
	// Ядро -- ссылка на флешку (как советует engine.md): удаление ссылки
	// места на флеше не освобождает, и замена оставляла без обоих ядер (Ф9, п3-59).
	if (fs.lstat(E.old)?.type == 'link')
		dief('места на второе ядро нет, а прежнее — ссылка на %s: ссылка места не занимает, ничего не тронуто. Положить новое ядро рядом с прежним (на флешку) и указать путь: byway set xray_bin', fs.readlink(E.old) ?? '?');
	if (substr(E.old, 0, 20) != '/usr/local/bin/xray-')
		dief('места на второе ядро нет, а прежнее (%s) — из пакета; снять пакет вручную и поставить заново: byway core %s', E.old, E.nw);
	en_stage(_f('места на второе ядро нет (свободно %s МБ) — замена через память', en_mb(E.free)));
	if (match(E.old, /^\/usr\/local\/bin\/xray-[^-]*-/)) {
		// Своя сборка: архив выпуска дал бы откат на ОФИЦИАЛЬНЫЙ бинарник под
		// именем своей сборки. Копия -- сам файл, сжатый в память.
		E.orb = E.d + '/old.gz';
		sayf('прежний движок — своя сборка (%s): копия для отката сжимается в память', E.old);
		if (run([ 'sh', '-c', 'gzip -c "$1" > "$2"', 'sh', E.old, E.orb ]).code != 0 || !fs.stat(E.orb)?.size)
			die('копию своей сборки для отката не сделать — замена не начата');
	} else {
		E.orb = E.d + '/old.zip';
		en_stage(_f('загрузка прежней версии %s — для отката', E.ov));
		if (en_fetch(E.ov, E.orb) != 0) {
			// Выпуск могли отозвать (26.10.17, 2026-10-21): копия -- сам файл, как у своей сборки.
			fs.unlink(E.orb);
			E.orb = E.d + '/old.gz';
			sayf('архив прежней версии %s не получен — копия для отката сжимается в память', E.ov);
			if (run([ 'sh', '-c', 'gzip -c "$1" > "$2"', 'sh', E.old, E.orb ]).code != 0 || !fs.stat(E.orb)?.size)
				dief('копию прежней версии %s для отката не сделать — замена не начата', E.ov);
		}
	}
	fs.writefile(E.d + '/ram.json', sprintf('%J', E));
	fs.writefile(EN_RAMF, '');
	let rc = sys([ 'sh', '-c', 'trap "" INT HUP; exec "$@"', 'sh', 'ucode', ...split(getenv('BW_UCRUN'), ' '), 'engine-ram', E.d ]);
	exit(rc);
}

// Конец фазы: замок и метка -- прочь; каталог -- если в нём не осталось
// единственной копии прежнего ядра.
function en_ram_end(rmdir) {
	// Каталог остаётся -- обёртке о нём не говорить, она бы его стёрла.
	if (rmdir) up_rmrf(E.d);
	else fs.unlink(EN_DIRF);
	fs.unlink(EN_RAMF);
	run([ 'rm', '-rf', EN_LOCK ]);
}

// Отказ ДО удаления прежнего ядра: оно на месте, достаточно запустить.
function en_ram_back() {
	en_svc('start');
	en_ram_end(true);
	die('служба запущена с прежним движком — ничего не заменено');
}

// Отказ ПОСЛЕ удаления: прежнее ядро -- из архива, скачанного до остановки.
function en_ram_restore() {
	en_stage(_f('возврат %s из архива', E.ov));
	if (en_put(E.orb, E.old) == 0) {
		en_bin_set(E.old);
		en_gen(E.old);
		en_svc('start');
		logf('движок: %s не встал, возвращён %s', E.nw, E.ov);
		en_ram_end(true);
		dief('возвращён %s', E.ov);
	}
	// Флеш не принял и прежнее ядро. Службу всё равно запускаем: без движка
	// она не встанет, но и dnsmasq не останется смотреть в мёртвый порт.
	en_svc('start');
	en_ram_end(false);
	logf('движок: НИ НОВОЕ, НИ ПРЕЖНЕЕ ядро не легло на флеш -- туннеля нет');
	let x = substr(E.orb, -3) == '.gz' ? 'gunzip -c ' + E.orb : 'unzip -p ' + E.orb + ' xray';
	dief('ни новое, ни прежнее ядро не легло на флеш — туннеля нет. Архив прежнего: %s (в памяти, до перезагрузки); поставить: %s > %s && chmod 755 %s && /etc/init.d/byway start',
	     E.orb, x, E.old, E.old);
}

// bw_uc engine-ram КАТАЛОГ: фаза «через память», служба остановлена здесь же.
// Любой отказ кончается запуском службы, иначе дом без туннеля.
function cmd_engine_ram(d) {
	E = json(fs.readfile(d + '/ram.json'));
	warn('остановка службы: туннель пропадёт примерно на минуту');
	// При «не пускать мимо VPN» запрет держится всю минуту (stop_service).
	run([ 'env', 'BYWAY_KEEP_BLOCK=1', '/etc/init.d/byway', 'stop' ]);
	// Сторож не «чинит» остановленную службу посреди замены; метку снимает
	// plumb on при запуске. Номер этого процесса: умрёт замена -- сторож
	// метку не признает.
	fs.writefile(PL_DOWN, fs.readlink('/proc/self') + '\n');
	en_stage(_t('идёт замена — прерывать нельзя'));
	sys([ 'sleep', '2' ]);
	let mk = en_mem_kb();
	if (mk * 1024 < int(E.sz) + 20971520) {
		warnf('памяти после остановки мало: %s МБ', en_mb(mk));
		en_ram_back();
	}
	let t = E.d + '/xray';
	if (!en_cat(E.pkg, t) || !fs.chmod(t, 0755) || run([ t, 'version' ]).code != 0) {
		warn('новое ядро не распаковалось или не запускается');
		en_ram_back();
	}
	fs.unlink(E.pkg);
	// Без ключа конфига нет, сверять нечего.
	if (!up_idle() && !en_gen(t)) {
		en_gen_tail();
		en_gen(E.old);
		warn('новый движок не принял конфиг');
		en_ram_back();
	}
	// Точка невозврата: прежнее ядро уступает место.
	fs.unlink(E.old);
	if (run([ 'cp', t, E.new + '.new' ]).code != 0 || !fs.chmod(E.new + '.new', 0755) || !fs.rename(E.new + '.new', E.new)) {
		fs.unlink(E.new + '.new'); fs.unlink(E.new);
		warn('новое ядро не легло на флеш');
		en_ram_restore();
	}
	fs.unlink(t);
	en_bin_set(E.new);
	en_svc('start');
	en_stage(_t('проверка туннеля на новом движке (до 2,5 минуты)'));
	if (up_wait(E.tun0)) {
		en_ram_end(true);
		logf('движок заменён: %s -> %s', E.ov, E.nw);
		en_done();
		return;
	}
	run([ 'env', 'BYWAY_KEEP_BLOCK=1', '/etc/init.d/byway', 'stop' ]);
	fs.unlink(E.new);
	warn('туннель на новом движке не поднялся');
	en_ram_restore();
}

// Переключение на ядро, которое уже лежит рядом: проверка конфига,
// перезапуск, проверка туннеля; не поднялось -- обратно. Оба файла остаются.
function en_switch() {
	en_stage(_f('Xray %s уже лежит рядом — переключение без загрузки', E.nw));
	E.tun0 = !up_idle() && up_tunnel_ok();
	if (up_idle()) {
		en_bin_set(E.new);
		sayf('служба не работает (выключена или нет ключа) — ядро заменено без проверки туннеля: Xray %s', E.nw);
		return;
	}
	if (!en_gen(E.new)) {
		en_gen_tail();
		en_gen(E.old);
		die('этот движок не принял конфиг — остался прежний');
	}
	en_bin_set(E.new);
	warn('перезапуск службы: туннель пропадёт на несколько секунд');
	en_svc('restart');
	en_stage(_t('проверка туннеля на новом движке (до 2,5 минуты)'));
	if (up_wait(E.tun0)) {
		logf('движок переключён: %s -> %s', E.ov, E.nw);
		print('\n\033[1;32m', _f('готово: Xray %s; прежнее ядро осталось рядом: %s', E.nw, E.old), '\033[0m\n');
		return;
	}
	warn('туннель на этом движке не поднялся — возврат прежнего');
	en_bin_set(E.old);
	en_gen(E.old);
	en_svc('restart');
	logf('движок: %s не поднялся, возвращён %s', E.nw, E.ov);
	dief('возвращён %s', E.ov);
}

// Рабочий каталог замены (путь -- обёртке, для уборки после Ctrl+C).
function en_workdir() {
	E.d = up_tmpdir('byway-engine');
	if (E.d === '') die('не создать рабочий каталог в /tmp');
	fs.writefile(EN_DIRF, E.d);
}

// Общий хвост: память, место и выбор пути.
function en_go() {
	E.free = en_free_kb();
	// Ядра нет вовсе: откатываться не на что -- просто ставим.
	if (E.ov === '') { en_fresh(); return; }
	E.tun0 = !up_idle() && up_tunnel_ok();
	// Рядом -- если на флеше есть весь размер ядра и 5 МБ сверху (сжатие
	// ubifs не угадать, меряется по несжатому).
	if (E.free * 1024 >= int(E.sz) + 5242880) en_side();
	else en_ram();
}

// Своя сборка ядра из /tmp (.gz с бинарником или .zip выпуска): та же замена
// с откатом, но без сверки с .dgst -- sha256 печатается, сверяет человек.
function en_local(f) {
	if (substr(f, 0, 5) != '/tmp/') die('своя сборка ядра — только из /tmp: на флеше рядом с ядром ей нет места');
	if (!fs.stat(f)) dief('нет файла %s', f);
	if (run([ 'sh', '-c', 'command -v unzip' ]).code != 0) dief('нет unzip — поставить: %s unzip', getenv('BW_PKGFIX'));
	E.asset = en_asset() ?? '';
	E.old = xray_bin();
	E.ov = en_ver(E.old);
	E.pkg = f;
	E.sz = en_size(f);
	if (int(E.sz || '0') <= 1048576) dief('в %s нет ядра xray — нужен .gz с бинарником или .zip выпуска', f);
	let sum = trim(split(run([ 'sh', '-c', (substr(f, -3) == '.gz' ? 'gunzip -c' : 'unzip -p') + ' "$1" ' +
	                         (substr(f, -3) == '.gz' ? '' : 'xray ') + '| sha256sum', 'sh', f ]).out, ' ')[0] ?? '');
	sayf('своя сборка: %s, sha256 ядра %s', f, sum);
	E.nw = _t('своя сборка');
	// С секундами: два вызова за минуту давали одно имя, и уборка прежнего
	// ядра удаляла только что поставленное (Ф9, п4-37).
	E.new = '/usr/local/bin/xray-local-' + trim(run([ 'date', '+%Y%m%d%H%M%S' ]).out);
	if (E.new == E.old) dief('ядро %s уже стоит — повторить через секунду', E.new);
	en_workdir();
	if (en_mem_kb() < 40960) dief('памяти доступно %s МБ, для замены нужно не меньше 40 — ничего не тронуто', en_mb(en_mem_kb()));
	en_go();
}

// bw_uc engine [ВЕРСИЯ|tested|newest|stable|restore|--check|/ФАЙЛ]
function cmd_engine(arg) {
	arg ??= '';
	if (substr(arg, 0, 1) == '/') { en_local(arg); return; }
	let pf = getenv('BW_PKGFIX'), tested = getenv('BW_XTESTED');
	let nofpu = en_mips_nofpu();
	// Вопрос «есть ли новее» не требует ни unzip, ни сборки под процессор:
	// на MIPS без FPU ядро стоит пакетом, unzip там нет, и проверка
	// отвечала «поставить unzip», а после него -- отказом (Ф9, п2-10).
	// Процессор -- раньше unzip: без FPU совет «поставить unzip» вёл к отказу
	// следующим шагом (прогон 5).
	if (nofpu && arg !== '' && arg != '--check')
		dief('на этом процессоре сборки Xray-core с GitHub не запускаются — движок ставится и обновляется пакетом OpenWrt: %s xray-core', pf);
	if (arg !== '' && arg != '--check') {
		if (run([ 'sh', '-c', 'command -v unzip' ]).code != 0) dief('нет unzip — поставить: %s unzip', pf);
		if (run([ 'sh', '-c', 'command -v sha256sum' ]).code != 0) die('нет sha256sum — сверить архив нечем, замена не начата');
	}
	E.asset = en_asset();
	if (!E.asset && arg !== '' && arg != '--check') dief('неизвестно, какой файл выпуска брать для %s', en_uname());
	E.old = xray_bin();
	E.ov = en_ver(E.old);

	if (arg === '' || arg == '--check') {
		if (nofpu) {
			if (E.ov !== '') sayf('стоит Xray %s', E.ov);
			sayf('на этом процессоре ядро ставится и обновляется пакетом OpenWrt: %s xray-core', pf);
			return;
		}
		// Первым -- ответ «есть ли новее». Подробности -- не в --check (его
		// зовёт панель).
		let nv = en_top('any'), sv = en_top('stable');
		if (E.ov === '') {
			warn('ядро Xray не указано или не запускается (byway.main.xray_bin)');
			say('  поставить: byway core restore');
		} else if (nv === '') {
			sayf('стоит Xray %s; есть ли новее — неизвестно: GitHub не ответил', E.ov);
			up_nonet();
		} else if (st_ver_gt(nv, E.ov)) {
			sayf('есть обновление ядра: Xray %s (стоит %s)', nv, E.ov);
		} else {
			sayf('обновлений ядра нет: стоит Xray %s', E.ov);
		}
		if (E.ov !== '' && tested != E.ov) {
			if (st_ver_gt(E.ov, tested)) sayf('  стоит новее проверенной с byway (%s)', tested);
			else sayf('  проверенная с byway: %s', tested);
		}
		if (nv !== '' && E.ov !== '' && st_ver_gt(nv, E.ov)) {
			sayf('  поставить: byway core %s', nv);
			if (tested != nv && st_ver_gt(tested, E.ov)) say('  или проверенную: byway core tested');
		}
		if (arg == '--check') return;
		say('подробно:');
		if (E.ov !== '') sayf('  файл: %s', E.old);
		if (nv !== '') sayf('  самая свежая у XTLS: %s, стабильная: %s', nv, sv || '?');
		sayf('  на флеше свободно %s МБ, памяти доступно %s МБ', en_mb(en_free_kb()), en_mb(en_mem_kb()));
		say('  варианты: byway core ВЕРСИЯ | tested | newest | stable | restore | /tmp/ФАЙЛ.gz');
		return;
	}
	if (arg == 'tested') {
		E.nw = tested;
	} else if (arg == 'restore') {
		// Ядра нет (sysupgrade его не сохраняет): версия из имени файла в
		// xray_bin (настройки sysupgrade переживают), иначе проверенная.
		if (E.ov !== '') { sayf('ядро на месте: Xray %s', E.ov); return; }
		if (trim(fs.readfile(EN_NOEXEC) ?? '') == en_uname())
			dief('сборка Xray-core с GitHub на этом процессоре не запускалась — ядро ставится пакетом: %s xray-core', pf);
		let rb = rtrim(run([ 'uci', '-q', 'get', 'byway.main.xray_bin' ]).out, '\n');
		let v = '';
		if (substr(rb, 0, 20) == '/usr/local/bin/xray-') v = split(substr(rb, 20), '-')[0];
		E.nw = (v !== '' && _only(v, '0123456789.')) ? v : tested;
	} else if (arg == 'newest' || arg == 'stable') {
		E.nw = en_top(arg == 'newest' ? 'any' : 'stable');
		if (E.nw === '') die('GitHub не ответил — номер свежей версии неизвестен, ничего не тронуто');
	} else {
		E.nw = arg;
	}
	if (!_only(E.nw, '0123456789.') || substr(E.nw, 0, 1) == '.' || substr(E.nw, -1) == '.')
		dief('непонятная версия «%s» — нужен номер вида 26.9.9 либо tested, newest, stable, restore', arg);
	// Своя сборка той же версии (xray-local-*, xray-26.9.30-h2l) -- не
	// «стоит уже»: официальная возвращается той же командой.
	if (!match(E.old, /^\/usr\/local\/bin\/xray-[^-]*-/) && E.nw == E.ov) {
		sayf('стоит уже %s — менять нечего', E.nw);
		return;
	}
	E.new = '/usr/local/bin/xray-' + E.nw;
	en_workdir();
	// Нужная версия уже лежит рядом -- переключение без загрузки.
	if (E.ov !== '' && E.new != E.old && x_ok(E.new)) { en_switch(); return; }
	// Архив в память: ~14 МБ. Меньше 40 МБ -- живой движок рядом с ним
	// рискует OOM, а он и есть туннель.
	if (en_mem_kb() < 40960) dief('памяти доступно %s МБ, для замены нужно не меньше 40 — ничего не тронуто', en_mb(en_mem_kb()));
	// Ядра нет -- место проверяем ДО загрузки: сторож повторяет раз в 15 мин.
	if (E.ov === '' && en_free_kb() < 25600)
		dief('на флеше свободно %s МБ, ядру нужно %s — ничего не тронуто', en_mb(en_free_kb()), 25);
	en_stage(_f('загрузка Xray-core %s (%s)', E.nw, E.asset));
	E.pkg = E.d + '/new.zip';
	let r = en_fetch(E.nw, E.pkg);
	if (r == 1) { up_nonet(); dief('архив %s не скачался — ничего не тронуто', E.nw); }
	if (r == 3) dief('архив %s не сошёлся с суммой, вшитой в byway для проверенной версии — отброшен, ничего не тронуто', E.nw);
	if (r != 0) dief('архив %s не сошёлся с суммой SHA2-256 из .dgst выпуска — отброшен, ничего не тронуто', E.nw);
	E.sz = en_size(E.pkg);
	if (E.sz === '') die('в архиве нет файла xray — ничего не тронуто');
	en_stage(_t('архив сверен с суммой из выпуска'));
	en_go();
}
