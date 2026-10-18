// Обновление byway и выпуски (бывший update/*.sh): файлы проверки и
// автообновления, подпись выпуска, последний выпуск на GitHub, словари (lang).
// Номер, репозиторий и ключ подписи -- от shell (BW_NUM, BW_REPO, BW_PUBKEY).

const UP_MARK = '/tmp/byway-upcheck';         // когда спрашивали в прошлый раз
const UP_OK = '/tmp/byway-upcheck-ok';        // проверка, дошедшая до GitHub
const UP_FAIL = '/tmp/byway-upcheck-fail';    // код ответа неудачной проверки
const UP_NEWVER = '/tmp/byway-newver';        // найденная версия, если новее
const UP_RELNOTE = '/tmp/byway-relnote';      // первая строка описания выпуска
const UP_AULOG = '/tmp/byway-autoupdate';     // чем кончилось ночное обновление
const UP_PREVBIN = '/etc/byway/byway.prev';   // копия одного скрипта (до 0.3.0)
const UP_PREVSET = '/etc/byway/prev.tgz';     // прежняя версия целиком для отката
const UP_AUTRY = '/etc/byway/.au-try';        // когда пробовали обновиться; флеш
const UP_SEENF = '/etc/byway/.newver-seen';   // версия и когда увидели; флеш
const UP_BINSUM = '/etc/byway/.binmd5';       // сумма выложенной версии
const UP_AUFAIL = '/etc/byway/.au-failed';    // выпуск, который не поднялся
const UP_PANEL_LANG = '/www/luci-static/resources/byway/lang.js';

function up_read(f) { return rtrim(fs.readfile(f) ?? '', '\n'); }

// «Не скачалось» чаще из-за туннеля: GitHub в списке byway, и при мёртвом
// туннеле резолвер отдаёт подставной адрес.
function up_nonet() {
	warn('  GitHub не ответил ни через туннель, ни напрямую, ни по адресам из DoH — проверить связь роутера и повторить');
}

// Рабочий каталог: атомарно и с правами 700 (на имени с номером процесса
// каталог, заведённый заранее другим пользователем, принимался бы как свой).
function up_tmpdir(pfx) { return trim(run([ 'mktemp', '-d', '/tmp/' + pfx + '.XXXXXX' ]).out); }
function up_rmrf(d) { if (d) run([ 'rm', '-rf', d ]); }

// Подпись выпуска (с 0.3.0): SHA256SUMS -- суммы всех файлов архива тега -- и
// его подпись лежат вложениями выпуска, ключ -- BW_PUBKEY. Список -- в
// dir/SHA256SUMS. 0 -- сошлась; 1 -- проверить нечем (нет usign, подпись не
// скачалась); 2 -- не сошлась. Общая для update и lang.
function up_rel_sums(num, dir) {
	if (run([ 'sh', '-c', 'command -v usign' ]).code != 0) {
		warn('нет usign — подпись выпуска проверить нечем');
		return 1;
	}
	let rel = 'https://github.com/' + getenv('BW_REPO') + '/releases/download/v' + num;
	if (nt_get([ '--max-time', '30', '-o', dir + '/SHA256SUMS', rel + '/SHA256SUMS' ]) != 0 ||
	    nt_get([ '--max-time', '30', '-o', dir + '/SHA256SUMS.sig', rel + '/SHA256SUMS.sig' ]) != 0) {
		warnf('у выпуска %s нет подписи (SHA256SUMS.sig) либо она не скачалась', num);
		return 1;
	}
	fs.writefile(dir + '/key.pub', 'untrusted comment: byway release key public key\n' + getenv('BW_PUBKEY') + '\n');
	if (run([ 'usign', '-V', '-q', '-m', dir + '/SHA256SUMS', '-x', dir + '/SHA256SUMS.sig', '-p', dir + '/key.pub' ]).code != 0) {
		warn('подпись выпуска не сошлась с ключом byway');
		return 2;
	}
	return 0;
}

// Суммы из подписанного списка: путь в выпуске -> sha256 («*» перед путем --
// двоичный режим sha256sum).
function up_sums(file) {
	let r = {};
	for (let l in split(fs.readfile(file) ?? '', '\n')) {
		let w = split(trim(l), /[ \t]+/);
		if (length(w) < 2) continue;
		let p = w[1];
		if (substr(p, 0, 1) == '*') p = substr(p, 1);
		r[p] ??= w[0];
	}
	return r;
}

function up_sha256(f) { return split(run([ 'sha256sum', f ]).out, ' ')[0] ?? ''; }

// Файл совпал со своей строкой подписанного списка.
function up_sum_ok(file, path, sums) {
	let w = up_sums(sums)[path];
	return w != null && w !== '' && up_sha256(file) == w;
}

// Последний выпуск byway на GitHub: [код, версия]; первая строка описания --
// в RELNOTE. Прокси-вход, напрямую, потом адреса GitHub из DoH. Любой ответ,
// кроме «не дозвонились», окончателен (404 -- нет репозитория).
function up_latest() {
	let px = u('local_proxy_port') || '1603';
	let api = 'https://api.github.com/repos/' + getenv('BW_REPO') + '/releases/latest';
	let code = '000', body = '';
	for (let via in [ [ '--proxy', 'http://127.0.0.1:' + px ], [], null ]) {
		if (via == null) {
			via = nt_gh_resolve();
			if (!length(via)) break;
		}
		let r = run([ 'curl', '-sSL', '--max-time', '25', '-A', 'Mozilla/5.0', ...via, '-w', '\n%{http_code}', api ]).out;
		let i = rindex(r, '\n');
		code = i >= 0 ? substr(r, i + 1) : r;
		body = i >= 0 ? substr(r, 0, i) : '';
		if (code != '000') break;
	}
	// В JSON перевод строки -- «\n» из двух знаков: обратная косая и есть
	// граница первой строки описания.
	let note = '', ver = '';
	for (let l in split(body, '\n')) {
		let m = match(l, /.*"body"[^"]*"([^"\\]*)/);
		if (m && note === '') note = m[1];
		let t = match(l, /.*"tag_name"[^"]*"v*([0-9][^"]*)"/);
		if (t && ver === '') ver = t[1];
	}
	fs.writefile(UP_RELNOTE, note !== '' ? note + '\n' : '');
	return [ code, ver ];
}

// ── язык (byway lang) ─────────────────────────────────────────────────────
// Словари лежат только выбранного языка (у ru файлов нет, ключи и есть
// русский текст). Английский докачивается с ТЕГА текущей версии, не с main:
// иначе ключи разойдутся с кодом. Панель зовёт эту же команду.

// Полный ли словарь панели: у урезанного строк перевода нет вовсе.
function up_panel_full() { return index(fs.readfile(UP_PANEL_LANG) ?? '', '"Служба": "Service"') >= 0; }

// Не вышло переключить на английский: настройка, которую уже записала панель,
// возвращается на русский -- иначе панель показывала бы «язык остался
// прежним» при lang=en в настройках.
function up_lang_back(dir) {
	if (fs.stat(dir + '/en.tsv')?.size) return;
	if (u('lang') != 'en') return;
	if (run([ 'uci', 'set', 'byway.main.lang=ru' ]).code == 0) run([ 'uci', 'commit', 'byway' ]);
}

// Отказ переключения: каталог прочь, язык назад, сообщение и выход.
function up_lang_fail(tmp, dir, msg) {
	up_rmrf(tmp);
	up_lang_back(dir);
	die_raw(msg);
}

// Файл выпуска (rel -- путь в нём) в dst: загрузка, признак содержимого,
// подпись. Ложь -- отказ уже объяснён и всё прибрано (выход).
function up_lang_get(tmp, dir, base, rel, dst, mark, nv, what) {
	let f = tmp + '/' + split(rel, '/')[1];
	if (nt_get([ '--max-time', '30', '-o', f, base + '/' + rel ]) != 0 || index(fs.readfile(f) ?? '', mark) < 0) {
		up_nonet();
		up_lang_fail(tmp, dir, what);
	}
	if (nv && !up_sum_ok(f, rel, tmp + '/SHA256SUMS'))
		up_lang_fail(tmp, dir, _t('словарь не совпал с подписанным выпуском — язык не переключён'));
	// Копией рядом и переименованием: /tmp и флеш -- разные файловые системы,
	// rename между ними не работает.
	let t = fs.readfile(f);
	if (t == null || !fs.writefile(dst + '.new', t) || !fs.rename(dst + '.new', dst)) {
		fs.unlink(dst + '.new');
		up_lang_fail(tmp, dir, _f('не записан %s', dst));
	}
	fs.chmod(dst, 0644);
}

// bw_uc lang [ru|en]
function cmd_lang(lw) {
	if (lw == null || lw === '') {
		sayf('язык: %s', LANG);
		say('  сменить: byway lang ru | en');
		return;
	}
	if (lw != 'ru' && lw != 'en') dief('непонятный язык «%s» — нужен ru или en', lw);
	let dir = getenv('BW_LISTS') + '/lang';
	if (lw == 'en') {
		let tmp = up_tmpdir('byway-lang');
		if (tmp === '') die('не создать рабочий каталог в /tmp');
		fs.mkdir(dir);
		// refs/tags: ветка с тем же именем, что тег, иначе перебила бы его.
		let base = 'https://raw.githubusercontent.com/' + getenv('BW_REPO') + '/refs/tags/v' + getenv('BW_NUM');
		// Словари -- строки форматов, которые byway печатает от root: берутся
		// только сверенными с подписанным списком сумм выпуска.
		let nv = false;
		if (getenv('BYWAY_NO_VERIFY') == '1') {
			warn('BYWAY_NO_VERIFY=1: подпись выпуска не проверяется');
		} else {
			let r = up_rel_sums(getenv('BW_NUM'), tmp);
			if (r == 1) up_lang_fail(tmp, dir, _t('словарь не сверить с подписью выпуска — язык не переключён; без проверки: BYWAY_NO_VERIFY=1 byway lang en'));
			if (r != 0) up_lang_fail(tmp, dir, _t('подпись выпуска не сошлась — язык не переключён'));
			nv = true;
		}
		if (!fs.stat(dir + '/en.tsv')?.size) {
			say('загрузка английского словаря');
			up_lang_get(tmp, dir, base, 'lang/en.tsv', dir + '/en.tsv', '\t', nv, _t('словарь не скачался — язык не переключён'));
		}
		if (fs.stat(UP_PANEL_LANG) && !up_panel_full()) {
			say('загрузка английского словаря панели');
			up_lang_get(tmp, dir, base, 'luci/lang.js', UP_PANEL_LANG, '"Служба": "Service"', nv, _t('словарь панели не скачался — язык не переключён'));
		}
		up_rmrf(tmp);
	} else {
		fs.unlink(dir + '/en.tsv');
		// Строки перевода в lang.js -- ровно те, что с двух табов и кавычки.
		if (fs.stat(UP_PANEL_LANG) && up_panel_full()) {
			let keep = filter(split(fs.readfile(UP_PANEL_LANG), '\n'), (l) => substr(l, 0, 3) != '\t\t"');
			fs.writefile(UP_PANEL_LANG + '.new', join('\n', keep));
			fs.rename(UP_PANEL_LANG + '.new', UP_PANEL_LANG);
			fs.chmod(UP_PANEL_LANG, 0644);
		}
	}
	if (u('lang') != lw && run([ 'uci', 'set', 'byway.main.lang=' + lw ]).code == 0)
		run([ 'uci', 'commit', 'byway' ]);
	// Итог -- уже на новом языке.
	LANG = lw;
	_dict = null;
	sayf('язык: %s', lw);
}

// ── проверки связи (бывшие tunnel_ok, alive_ok, eng_idle, eng_wait) ───────
// Служба не работает (выключена или нет ключа): туннеля для проверки нет.
function up_idle() {
	if (u('enabled') != '1') return true;
	let m = u('conn_mode');
	if (m == 'urltest' || m == 'selector') return u('node_urls') === '';
	if (m == 'outbound') return u('outbound_json') === '';
	return u('node_url') === '';
}

// Связь через сервер: запрос через прокси-вход к пробному домену.
function up_tunnel_ok() {
	let lp = u('local_proxy_port') || '1603';
	let c = trim(run([ 'curl', '-s', '-o', '/dev/null', '--max-time', '8', '-w', '%{http_code}',
	                   '--proxy', 'http://127.0.0.1:' + lp, 'https://' + getenv('BW_PROBE') + '/' ]).out);
	return c !== '' && c != '000';
}

// Движок жив, перехват на месте, резолвер отдаёт fakeip. Пустой список -- не
// поломка, проверять нечем.
function up_alive_ok() {
	if (st_xray_pid() === '' || !pl_has_table(PL_TABLE)) return false;
	let d = st_plain_first(mg_path('domains'));
	return d === '' || st_fake_of(d, st_pool()) !== '';
}

// Дождаться туннеля, до 150 с: обвязку после старта поднимает фоновый цикл
// службы, ему нужно до ~65 с сверх запуска. Сервер -- только если он отвечал
// ДО замены (tun0): мёртвый сервер -- не вина новой версии.
function up_wait(tun0) {
	if (up_idle()) return true;
	for (let i = 0; i < 15; i++) {
		sys([ 'sleep', '10' ]);
		if (up_alive_ok() && (!tun0 || up_tunnel_ok())) return true;
	}
	return false;
}

// ── byway update ──────────────────────────────────────────────────────────
// Рабочий каталог запуска: путь -- в /var/run, чтобы shell-обёртка убрала его
// и после Ctrl+C (ucode сигналов не ловит).
const UP_DIRF = '/var/run/byway-update.dir';
let UP_DIR = null;
function up_exit(code) {
	up_rmrf(UP_DIR);
	fs.unlink(UP_DIRF);
	exit(code);
}
function up_die(msg) {
	up_rmrf(UP_DIR);
	fs.unlink(UP_DIRF);
	die_raw(msg);
}

// Прежняя версия целиком -- в архив на флеш: откат одного скрипта оставлял
// новые init, панель и словарь при старом byway. Только существующие пути.
function up_snapshot() {
	let p = [];
	for (let f in [ '/usr/local/bin/byway', '/etc/init.d/byway', '/usr/local/bin/byway-uninstall',
	                '/www/luci-static/resources/view/byway', '/www/luci-static/resources/byway',
	                '/usr/share/luci/menu.d/luci-app-byway.json',
	                '/usr/share/rpcd/acl.d/luci-app-byway.json', '/etc/byway/lang' ])
		if (fs.stat(f)) push(p, substr(f, 1));
	fs.unlink(UP_PREVBIN);
	if (run([ 'tar', 'czf', UP_PREVSET + '.new', '-C', '/', ...p ]).code == 0 && fs.stat(UP_PREVSET + '.new')?.size &&
	    fs.rename(UP_PREVSET + '.new', UP_PREVSET)) {
		fs.chmod(UP_PREVSET, 0600);
		return true;
	}
	fs.unlink(UP_PREVSET + '.new');
	return false;
}

// Вернуть архив прежней версии и перезапустить службу. Через каталог в памяти
// и mv на место: запись поверх файла, который сейчас исполняется, портила бы
// его чтение. Автозапуск -- заново по init прежней версии.
function up_restore() {
	if (!fs.stat(UP_PREVSET)?.size) { warn('копии прежней версии нет'); return false; }
	let r = up_tmpdir('byway-rollback');
	if (r === '' || run([ 'tar', 'xzf', UP_PREVSET, '-C', r ]).code != 0) {
		up_rmrf(r);
		warnf('откат не удался -- копия в %s', UP_PREVSET);
		return false;
	}
	let bad = false;
	for (let f in split(trim(run([ 'sh', '-c', 'cd "$1" && find . -type f', 'sh', r ]).out), '\n')) {
		if (f === '') continue;
		let d = substr(f, 1);
		run([ 'mkdir', '-p', substr(d, 0, rindex(d, '/')) ]);
		if (run([ 'cp', '-p', r + d, d + '.new' ]).code != 0 || !fs.rename(d + '.new', d)) bad = true;
	}
	up_rmrf(r);
	if (bad) { warnf('откат лёг не целиком -- копия в %s', UP_PREVSET); return false; }
	fs.writefile(UP_BINSUM, split(run([ 'md5sum', '/usr/local/bin/byway' ]).out, ' ')[0] + '\n');
	for (let a in [ [ '/etc/init.d/byway', 'disable' ], [ '/etc/init.d/byway', 'enable' ],
	                [ '/etc/init.d/rpcd', 'reload' ], [ '/etc/init.d/byway', 'restart' ] ])
		run(a);
	say('прежняя версия возвращена');
	return true;
}

// Распакованный архив против подписанного списка: каждый файл в списке и с
// той суммой, лишних нет, номер внутри -- тот же. 0 / 1 (проверить нечем) / 2.
function up_verify(num, root, dir) {
	let r = up_rel_sums(num, dir);
	if (r != 0) return r;
	if (run([ 'sh', '-c', 'cd "$1" && sha256sum -c "$2"', 'sh', root, dir + '/SHA256SUMS' ]).code != 0) {
		warn('файлы архива не совпали с подписанным списком');
		return 2;
	}
	let have = sort(filter(split(trim(run([ 'sh', '-c', 'cd "$1" && find . -type f', 'sh', root ]).out), '\n'),
	                       (x) => x !== ''));
	have = map(have, (x) => substr(x, 2));
	let want = sort(keys(up_sums(dir + '/SHA256SUMS')));
	if (join('\n', sort(have)) != join('\n', want)) {
		warn('в архиве есть файлы вне подписанного списка');
		return 2;
	}
	// Подпись не несёт номера выпуска: подписанный список старого выпуска
	// сошёлся бы и под новым тегом. Номер -- из подписанных файлов.
	let iv = index(split(fs.readfile(root + '/install.sh') ?? '', '\n'), 'VER=' + num) >= 0;
	let bv = index(split(fs.readfile(root + '/byway') ?? '', '\n'), 'BYWAY_NUM="' + num + '"') >= 0;
	if (!iv || !bv) {
		warnf('архив не того выпуска: внутри не v%s', num);
		return 2;
	}
	return 0;
}

// bw_uc update [--check|--force|--rollback|--no-verify|--to ВЕРСИЯ]. Код
// выхода для ночного обновления: 0 -- поставлено и туннель работает, 3 -- не
// поднялось и откачено, 4 -- откат не удался, 5 -- копия для отката не
// сделалась, 6 -- подпись не сошлась (оба -- ничего не тронуто), прочее -- не
// скачалось.
// Шаг долгой работы: человек видит, сколько осталось (владелец 2026-10-18).
function up_step(n, total, what) { print('\n'); sayf('шаг %s из %s: %s', n, total, what); }

function cmd_update(...args) {
	let num = getenv('BW_NUM'), uf = '', nov = false, uto = '';
	for (let i = 0; i < length(args); i++) {
		let a = args[i];
		if (a == '--rollback') {
			if (!fs.stat(UP_PREVSET)?.size) die('откатывать не на что: копия делается при byway update');
			if (!up_restore()) die('откат не завершён — освободить место на флеше и повторить: byway update --rollback');
			// Снятый вручную выпуск автообновление не вернёт.
			fs.writefile(UP_AUFAIL, num + '\n');
			sayf('автообновление выпуск %s больше не поставит', num);
			return;
		} else if (a == '--check' || a == '--force') {
			uf = a;
		} else if (a == '--no-verify') {
			nov = true;
		} else if (a == '--to') {
			// Ночное: ставится выдержавший три дня номер, а не свежий на 04:00.
			uto = args[++i] ?? '';
			if (uto === '' || !_only(uto, '0123456789.')) dief('непонятная версия «%s»', uto);
		} else {
			dief('непонятный ключ: %s — byway update [--check|--force|--rollback|--no-verify]', a);
		}
	}
	let lv = uto !== '' ? [ '200', uto ] : up_latest(), code = lv[0], nw = lv[1];
	if (nw === '' || nw == code) {
		if (code == '000') die('GitHub не ответил -- похоже, нет связи');
		if (code == '404') dief('на GitHub нет ни репозитория %s, ни его выпусков', getenv('BW_REPO'));
		if (code == '403') die('GitHub ответил «слишком часто спрашиваете» -- подождать час');
		dief('GitHub ответил %s, но версии в ответе нет', code);
	}
	// Метка «найдена новая» устаревает с самим обновлением.
	if (!st_ver_gt(nw, num)) {
		fs.unlink(UP_NEWVER);
		// Тег могут пересобрать на новом коммите под тем же номером: «новее
		// нет» верно про номер, но не про файлы. Отсюда --force.
		if (uf == '--force') {
			sayf('версия та же (%s), но ставится заново -- так велит --force', num);
		} else {
			sayf('версия %s -- новее нет', num);
			say('  переставить ту же: byway update --force');
			return;
		}
	} else {
		sayf('есть новая версия: %s (у вас %s)', nw, num);
	}
	if (uf == '--check') return;

	UP_DIR = up_tmpdir('byway-update');
	let total = (nov ? 4 : 5) - (up_idle() ? 1 : 0), st = 0;
	if (UP_DIR === '') die('не создать рабочий каталог в /tmp');
	fs.writefile(UP_DIRF, UP_DIR);
	let d = UP_DIR;
	up_step(++st, total, _t('загрузка'));
	if (nt_get([ '--max-time', '120', '-o', d + '/p.tar.gz',
	             'https://github.com/' + getenv('BW_REPO') + '/archive/refs/tags/v' + nw + '.tar.gz' ]) != 0) {
		up_die(_t('не скачалось -- ничего не тронуто'));
	}
	if (run([ 'tar', 'xzf', d + '/p.tar.gz', '-C', d ]).code != 0) { up_die(_t('не распаковалось -- ничего не тронуто')); }
	let src = split(trim(run([ 'find', d, '-maxdepth', '2', '-name', 'install.sh' ]).out), '\n')[0] ?? '';
	if (src === '') { up_die(_t('в пакете нет install.sh -- ничего не тронуто')); }
	let root = substr(src, 0, rindex(src, '/'));
	if (nov) {
		warn('--no-verify: подпись выпуска не проверяется');
	} else {
		// 1 -- проверить нечем (обход назвать можно), 2 -- подлинность
		// опровергнута (обход не советовать).
		up_step(++st, total, _t('проверка подписи выпуска'));
		let r = up_verify(nw, root, d);
		if (r == 0) say('подпись выпуска сошлась с ключом byway');
		else if (r == 1) { warn('выпуск не поставлен -- ничего не тронуто; поставить без проверки подписи: byway update --no-verify'); up_exit(6); }
		else { warn('архив не совпал с подписанным выпуском -- подменён или повреждён; ничего не тронуто, повторить позже'); up_exit(6); }
	}

	// Связь до установки: откатывать за мёртвый сервер нельзя.
	let tun0 = !up_idle() && up_tunnel_ok();
	up_step(++st, total, _t('копия прежней версии для отката'));
	if (!up_snapshot()) {
		warn('копия прежней версии для отката не сделалась (место на флеше?) -- ничего не тронуто');
		up_exit(5);
	}
	// Ставит install.sh: он один знает, что куда класть и что оставить.
	up_step(++st, total, _t('установка'));
	if (sys([ 'sh', '-c', 'cd "$1" && sh install.sh', 'sh', root ]) != 0) {
		warn('установка оборвалась -- возврат прежней версии');
		up_exit(up_restore() ? 3 : 4);
	}
	fs.unlink(UP_NEWVER);
	fs.unlink(UP_RELNOTE);
	// Поставленный вручную выпуск, который раньше не поднимался, больше не
	// «отвергнут»: doctor писал бы об этом вечно.
	if (up_read(UP_AUFAIL) == nw) fs.unlink(UP_AUFAIL);
	if (up_idle()) up_exit(0);
	up_step(++st, total, _t('проверка туннеля на новой версии (до 2,5 минуты)'));
	if (up_wait(tun0)) {
		print('\n\033[1;32m', _f('готово: byway %s, туннель работает', nw), '\033[0m\n');
		up_exit(0);
	}
	warn('на новой версии туннель не поднялся -- возврат прежней');
	up_exit(up_restore() ? 3 : 4);
}
