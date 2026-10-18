// Сторож из cron (бывший service/watch.sh): возврат ядра, починка перехвата,
// обновление списков и byway по расписанию, журнал состояния; pulse раз в
// минуту. Не перенесённое (update, engine, gen) и перехват (у него замок) --
// отдельным вызовом byway (BW_SELF).

const WT_LAST = '/tmp/byway-watch.last';
// Сколько проверок подряд не нашлось движка; в tmpfs, после перезагрузки с 0.
const WT_NOPID = '/tmp/byway-nopid';
// Файлы проверки обновлений (update/update.sh -- те же, править парой до Ф7).
const WT_UPMARK = '/tmp/byway-upcheck';
const WT_UPOK = '/tmp/byway-upcheck-ok';
const WT_UPFAIL = '/tmp/byway-upcheck-fail';
const WT_NEWVER = '/tmp/byway-newver';
const WT_RELNOTE = '/tmp/byway-relnote';
const WT_AULOG = '/tmp/byway-autoupdate';
const WT_PREVBIN = '/etc/byway/byway.prev';
const WT_PREVSET = '/etc/byway/prev.tgz';
const WT_AUTRY = '/etc/byway/.au-try';
const WT_SEENF = '/etc/byway/.newver-seen';
const WT_BINSUM = '/etc/byway/.binmd5';
const WT_AUFAIL = '/etc/byway/.au-failed';

// Состояние прогона: pid, tab, rul, rt, dm, fk, healed.
let W = {};

function wt_self() { return getenv('BW_SELF') || '/usr/local/bin/byway'; }
// Команда byway отдельным процессом; итог -- { code, out }.
function wt_byway(...a) { return run([ wt_self(), ...a ], true); }
function wt_reload() { run([ '/etc/init.d/byway', 'reload' ]); }

// Файл свежее n минут (как `find -mmin -n`).
function wt_fresh(f, n) {
	let s = fs.stat(f);
	return s != null && time() - s.mtime < n * 60;
}
function wt_touch(f) { run([ 'touch', f ]); }
function wt_read(f) { return rtrim(fs.readfile(f) ?? '', '\n'); }

// Метка «перехват сняли намеренно» держит сторожа и pulse. Пустая -- сняли
// руками (`byway plumb off`), держит до plumb on. С номером -- службу
// остановила замена ядра: умер её процесс (обрыв ssh посреди замены) -- метка
// снимается, служба запускается, иначе её не поднял бы никто.
function wt_down_held() {
	if (!fs.stat(PL_DOWN)) return false;
	let p = trim(fs.readfile(PL_DOWN) ?? '');
	if (p === '') return true;
	if (index(fs.readfile('/proc/' + p + '/cmdline') ?? '', 'byway') >= 0) return true;
	fs.unlink(PL_DOWN);
	if (u('enabled') == '1' && st_xray_pid() === '') {
		logf('метка остановки от умершего процесса %s снята -- служба запускается', p);
		run([ '/etc/init.d/byway', 'start' ]);
		// Этот прогон пропускаем: снятый до старта pid пуст, и следом шёл бы
		// engine_gone поверх идущего подъёма (П3, 2026-10-04).
		return true;
	}
	return false;
}

// Перехват настраивается живым процессом: замок cmd_plumb с pid, который есть.
function wt_plumb_busy() {
	let p = trim(fs.readfile('/var/run/byway-plumb.lock/pid') ?? '');
	return p !== '' && fs.stat('/proc/' + p) != null;
}

// Служба зарегистрирована в procd: `/etc/init.d/byway stop` снимает её оттуда,
// упавший движок -- нет. Без проверки сторож принимал остановку руками за
// падение и при закрытой модели запирал дом (Ф-1, 2026-10-04). Нет ответа
// ubus -- считаем зарегистрированной: лишний запрет лучше дыры.
function wt_registered() {
	let r = run([ 'ubus', 'call', 'service', 'list', '{"name":"byway"}' ]);
	return r.code != 0 || index(r.out, '"byway"') >= 0;
}

// Промежуток словами: 90m, 3h, 2h37m, 1d, 1d6h. Минуты, при мусоре -1.
function wt_mins(s) {
	s = replace(lc(s), ' ', '');
	if (s === '' || s == '0') return 0;
	if (_only(s, '0123456789')) return int(s);
	let n = 0, v = 0;
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		if (index('0123456789', c) >= 0) { v = v * 10 + int(c); continue; }
		if (c == 'd') n += v * 1440;
		else if (c == 'h') n += v * 60;
		else if (c == 'm') n += v;
		else return -1;
		v = 0;
	}
	return n + v;
}

// Путь к движку годен для запуска от root (xray_ok в core/head.sh): каталог,
// куда пишет только root, имя xray*, ELF, отвечает как Xray.
function wt_xray_ok(f) {
	if (!match(f, /^\/(usr\/bin|usr\/sbin|usr\/local\/bin|bin|sbin)\//) || index(f, '..') >= 0) return false;
	let s = fs.stat(f);
	if (!s || s.type != 'file' || !(s.mode & 73)) return false;
	if (substr(rindex(f, '/') >= 0 ? substr(f, rindex(f, '/') + 1) : f, 0, 4) != 'xray') return false;
	let h = fs.open(f, 'r'), b = h ? h.read(4) : '';
	if (h) h.close();
	if (index(b ?? '', 'ELF') < 0) return false;
	return match(split(run([ f, 'version' ]).out, '\n')[0] ?? '', /^Xray /i) != null;
}

// ── прогон ────────────────────────────────────────────────────────────────
// Копия одного скрипта от автообновления 0.2.4: нужна ей полчаса, потом лишняя.
function wt_prevbin() {
	if (fs.stat(WT_PREVBIN) && !wt_fresh(WT_PREVBIN, 60)) fs.unlink(WT_PREVBIN);
}

// Возврат ядра, если файла движка нет. Повтор раз в 15 мин, в фоне: загрузка
// идёт минуты. Запускаемое xray-* рядом -- не повод: его указывают руками.
function wt_restore() {
	wt_prevbin();
	let alt = false;
	for (let f in fs.lsdir('/usr/local/bin') ?? [])
		if (substr(f, 0, 5) == 'xray-' && (fs.stat('/usr/local/bin/' + f)?.mode & 73)) alt = true;
	if (u('enabled') == '1' && !alt && !wt_xray_ok(getenv('BW_XRAY') || '/nonexistent') &&
	    !wt_fresh('/tmp/byway-engine-restore', 15)) {
		fs.writefile('/tmp/byway-engine-restore', '');
		logt('byway watch: ядра нет -- byway engine restore в фоне');
		system([ 'sh', '-c', '( "$1" engine restore 2>&1 | sed "s/$(printf "\\033")\\[[0-9;]*m//g" | logger -t byway ) </dev/null >/dev/null 2>&1 &',
		         'sh', wt_self() ]);
	}
}

// Дешёвый снимок: pid, перехват, резолвер. Таблицу -- по ТОЧНОМУ имени:
// подстрока совпала бы и с `inet byway_block`.
function wt_tab() { return length(filter(pl_lines(run([ 'nft', 'list', 'tables' ]).out), (l) => l == 'table inet ' + PL_TABLE)); }
function wt_rul() {
	let re = pl_rule_re(pl_mark(false));
	return length(filter(pl_lines(run([ 'ip', 'rule', 'show' ]).out), (l) => match(l, re) != null));
}
// Маршрут -- третья опора: без него помеченный пакет молча гибнет.
function wt_rt() { return length(filter(pl_lines(run([ 'ip', 'route', 'show', 'table', PL_RT ]).out), (l) => substr(l, 0, 13) == 'local default')); }
function wt_dm() { let s = dm_servers(); return length(s) ? join(' ', s) : 'none'; }
function wt_parts() { W.tab = wt_tab(); W.rul = wt_rul(); W.rt = wt_rt(); W.dm = wt_dm(); }

function wt_snapshot() {
	W.pid = st_xray_pid();
	wt_parts();
	W.fk = 'no';
	let d = st_plain_first(mg_path('domains'));
	// Ответ из пула не доказывает, что жив наш движок (умолчания совпадают с
	// podkop'овскими): спрашиваем и свою таблицу -- её ставит только byway.
	if (d !== '' && pl_has_table(PL_TABLE) && st_fake_of(d, st_pool()) !== '') W.fk = 'yes';
}

function wt_dns_ours() { return index(split(W.dm, ' '), pl_dns_addr()) >= 0; }

// Движка нет при включённой службе -- упал, а не выключен. Запрет -- сразу;
// перехват DNS снимается на втором промахе подряд (иначе dnsmasq шлёт весь
// резолв дома в мёртвый вход). procd поднимает упавший движок за секунды --
// на каждый перезапуск не снимаем. Зовут сторож и pulse.
function wt_engine_gone() {
	// Под замком перехвата: занят -- запрет поставит сам идущий подъём (П3).
	wt_byway('plumb', 'close');
	let mv = trim(fs.readfile(WT_NOPID) ?? '');
	let miss = (mv !== '' && _only(mv, '0123456789') ? int(mv) : 0) + 1;
	fs.writefile(WT_NOPID, '' + miss);
	if (!wt_dns_ours() || miss < 2) return;
	// Текст зависит от модели: при закрытой перехват снимаем, запрет остаётся.
	if (u('on_failure') != 'open') {
		let b = wt_read(PL_BLOCK);
		if (b == 'all') logt('движок не поднимается -- перехват снят, запрет «не пускать мимо VPN» ОСТАЁТСЯ: трафик сетей byway закрыт');
		else if (b == 'lists') logt('движок не поднимается -- перехват снят, запрет «не пускать мимо VPN» ОСТАЁТСЯ: сайты и подсети списка закрыты');
		else logt('движок не поднимается -- перехват снят, запрет «не пускать мимо VPN» включён, но закрывать нечего');
	} else {
		logt('движок не поднимается -- перехват снят, дом остаётся с интернетом и без туннеля');
	}
	// --service: метку «сняли руками» не ставим. --keep-block (только при
	// закрытой модели): безусловное снятие запрета открывало окно.
	if (u('on_failure') != 'open') wt_byway('plumb', 'off', '--service', '--keep-block');
	else wt_byway('plumb', 'off', '--service');
	W.healed = '(nodns)';
}

// Движок вернулся при стоящем запрете: respawn procd не зовёт service_started,
// перехват цел -- без этого список вечно отвечал бы 0.0.0.0. Удачный plumb on
// снимает запрет. `u guard` не спрашиваем: это возврат, не починка.
function wt_engine_back() {
	// Подъём уже идёт (старт службы снимает метку в начале plumb on, запрет --
	// в конце): второй ждал бы замка и писал ложное «не поднялся».
	if (wt_plumb_busy()) return;
	if (u('enabled') != '1') {
		wt_byway('plumb', 'unblock');
	} else if (!fs.stat(PL_BLOCK) && wt_byway('plumb', 'on').code == 0) {
		logt('движок вернулся -- перехват поднят');
		W.healed = '(healed)';
	} else if (wt_byway('plumb', 'on').code == 0) {
		logt('движок вернулся -- перехват поднят, запрет «не пускать мимо VPN» снят');
		W.healed = '(healed)';
	} else {
		logt('движок вернулся, но перехват не поднялся -- запрет «не пускать мимо VPN» остаётся');
		W.healed = '(failed)';
	}
}

// Починка перехвата: его сносят и чужие скрипты (`nft flush ruleset`,
// firewall4, сосед по таблице 100). Чиним только при живом движке и
// включённой службе и не после `plumb off`: иначе сторож дрался бы с
// человеком, снявшим туннель.
function wt_heal() {
	W.healed = '';
	if (W.pid === '' && u('enabled') == '1' && !wt_down_held() && wt_registered()) {
		wt_engine_gone();
		if (W.healed == '(nodns)') wt_parts();
	} else {
		fs.unlink(WT_NOPID);
	}
	if (W.pid !== '' && fs.stat(PL_BLOCK)) wt_engine_back();
	if (W.pid !== '' && u('enabled') == '1' && u('guard') != '0' && !wt_down_held()) {
		// Пропавший маршрут чинится тем же plumb on: иначе помеченный пакет
		// уходит в WAN с настоящим адресом, а проверки зелёные.
		if (!W.tab || !W.rul || !W.rt || !wt_dns_ours()) {
			logt('byway watch: правил перехвата нет при работающем движке -- восстановление');
			W.healed = wt_byway('plumb', 'on').code == 0 ? '(healed)' : '(failed)';
			wt_parts();
		}
	}
}

// Готовые списки по промежутку из настройки: cron «каждые N» умеет, только
// когда N делит час. Прошлая загрузка -- mtime каталога; touch ДО загрузки,
// чтобы неудачная попытка не повторялась каждые пять минут.
function wt_lists() {
	let iv = wt_mins(u('lists_update'));
	if (iv <= 0 || u('preset') === '') return;
	if (iv < 30) iv = 30;                  // ниже -- долбёж чужого сервера
	let d = getenv('BW_PRESETS');
	if (!fs.stat(d)) fs.mkdir(d);
	if (wt_fresh(d, iv)) return;
	wt_touch(d);
	logf('обновление готовых списков (промежуток %s мин)', iv);
	// Предупреждения проверки из cron никто не видит -- в системный журнал.
	for (let l in pl_lines(replace(wt_byway('presets').out, /\x1b\[[0-9;]*m/g, '')))
		if (substr(l, 0, 3) == '[!]' || substr(l, 0, 3) == '[x]') run([ 'logger', '-t', 'byway', l ]);
	wt_reload();
}

// Последний выпуск на GitHub: [код, версия]; первая строка описания -- в
// RELNOTE. Прокси-вход, напрямую, потом адреса GitHub из DoH. Любой ответ,
// кроме «не дозвонились», окончателен (404 -- нет репозитория).
function wt_latest() {
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
	fs.writefile(WT_RELNOTE, note !== '' ? note + '\n' : '');
	return [ code, ver ];
}

// Проверка новой версии, без установки: установка рвёт туннель в
// невыбранный момент. Промежуток случайный, 12-36 ч: запрос к GitHub в одно
// время суток выделялся бы в трафике. В UPMARK -- минуты до следующей
// проверки, mtime -- время прошлой.
function wt_upcheck() {
	if (u('update_check') == '0') return;
	let m = wt_read(WT_UPMARK);
	if (m === '' || !_only(m, '0123456789')) m = '1440';
	if (wt_fresh(WT_UPMARK, int(m))) return;
	// Случайность из uuid ядра: od и hexdump есть не в каждом busybox.
	let r = substr(trim(fs.readfile('/proc/sys/kernel/random/uuid') ?? ''), 0, 4);
	if (r === '' || !_only(r, '0123456789abcdef')) r = '0';
	fs.writefile(WT_UPMARK, (720 + hex(r) % 1441) + '\n');
	let lv = wt_latest(), uc = lv[0], un = lv[1], num = getenv('BW_NUM');
	// Дошла ли проверка до GitHub: doctor иначе писал бы «новее не найдено» и
	// про сутки без связи, и про отказ 403.
	if (un !== '' && un != uc) {
		fs.writefile(WT_UPOK, '');
		fs.unlink(WT_UPFAIL);
	} else {
		fs.writefile(WT_UPFAIL, uc + '\n');
		// Нет связи -- повтор через час, а не через 12-36 ч.
		if (uc == '000') fs.writefile(WT_UPMARK, '60\n');
	}
	if (un !== '' && un != uc && st_ver_gt(un, num)) {
		if (wt_read(WT_NEWVER) != un) {
			fs.writefile(WT_NEWVER, un + '\n');
			// Дата первого обнаружения -- во флеш и один раз на номер: NEWVER
			// после перезагрузки стёрт, и выдержка (3 суток) не копилась бы.
			// Только при разумных часах: без батарейки роутер в 1970-м.
			let y = int(trim(run([ 'date', '+%Y' ]).out));
			if (substr(wt_read(WT_SEENF), 0, length(un) + 1) != un + ' ' && y >= 2020)
				fs.writefile(WT_SEENF, un + ' ' + time() + '\n');
			logf('новая версия byway %s (у вас %s): %s', un, num, wt_read(WT_RELNOTE));
		}
	} else if (un !== '') {
		// Стираем, только когда ответ получен и новой версии нет: отказ связи
		// не доказывает, что выпуска нет, и сбросил бы выдержку.
		fs.unlink(WT_NEWVER);
	}
}

// Установка с проверкой туннеля и откатом на копию -- cmd_update; здесь итог
// по коду. Час -- не отметка «пробовали сегодня»: внутри часа условие истинно
// 12 раз. Повторы гасят AUTRY (раз в сутки) и AUFAIL (проваливавшийся номер
// второй раз не ставим).
function wt_au_install(au, y, h) {
	if (au === '' || y < 2020 || h != dr_au_hour() || wt_read(WT_AUFAIL) == au || wt_fresh(WT_AUTRY, 1440)) return;
	let num = getenv('BW_NUM'), when = trim(run([ 'date', '+%Y-%m-%d %H:%M' ]).out);
	fs.writefile(WT_AUTRY, '');
	logf('автообновление: установка %s (было %s)', au, num);
	let rc = wt_byway('update', '--to', au).code;
	if (rc == 0) {
		fs.writefile(WT_AULOG, _f('обновлено до %s, %s\n', au, when));
		logf('автообновление: %s поднялось', au);
		fs.unlink(WT_NEWVER);
	} else if (rc == 3) {
		fs.writefile(WT_AUFAIL, au + '\n');
		fs.writefile(WT_AULOG, _f('ОТКАТ с %s на %s, %s\n', au, num, when));
		logf('автообновление: %s не поднялось -- откат на %s', au, num);
	} else if (rc == 4) {
		fs.writefile(WT_AUFAIL, au + '\n');
		fs.writefile(WT_AULOG, _f('ОТКАТ НЕ УДАЛСЯ: на диске %s, копия в %s\n', au, WT_PREVSET));
		logf('автообновление: ОТКАТ НЕ УДАЛСЯ -- копия в %s, вернуть: byway update --rollback', WT_PREVSET);
	} else if (rc == 5) {
		logf('автообновление: копия для отката не сделалась -- установка ОТМЕНЕНА (место на /overlay?)');
	} else if (rc == 6) {
		logf('автообновление: подпись выпуска %s не сошлась -- не ставится', au);
	} else {
		logf('автообновление: %s не скачалось, работает прежняя', au);
	}
}

// Ночная установка по настройке auto_update (выключено по умолчанию).
function wt_autoupdate() {
	let num = getenv('BW_NUM'), au = wt_read(WT_NEWVER);
	if (u('auto_update') != '1' || au === '' || !st_ver_gt(au, num)) return;
	let note = wt_read(WT_RELNOTE);
	let y = int(trim(run([ 'date', '+%Y' ]).out)), h = trim(run([ 'date', '+%H' ]).out);
	// Выдержка: не раньше трёх суток после первого обнаружения; метка
	// важности снимает. Возраст -- по записанной дате, не по mtime: ntpd
	// переводит часы скачком после старта.
	let bake = !(substr(note, 0, 5) == 'ВАЖНО' || substr(note, 0, 8) == 'CRITICAL' || substr(note, 0, 1) == '!');
	let age = 0, sv = wt_read(WT_SEENF);
	if (substr(sv, 0, length(au) + 1) == au + ' ') {
		let st = substr(sv, length(au) + 1);
		st = (st !== '' && _only(st, '0123456789')) ? int(st) : 0;
		if (st > 0 && time() > st) age = time() - st;
	}
	if (bake && age < 259200) au = '';
	// Только внутри минорной версии: 0.1.x -> 0.1.y само, 0.1 -> 0.2 нет.
	let minor = (v) => rindex(v, '.') < 0 ? v : substr(v, 0, rindex(v, '.'));
	if (au !== '' && minor(au) != minor(num)) au = '';
	// Правленое руками не трогаем; суммы нет -- версия неизвестна.
	if (au !== '') {
		if (fs.stat(WT_BINSUM)) {
			if (split(run([ 'md5sum', '/usr/local/bin/byway' ]).out, ' ')[0] != wt_read(WT_BINSUM)) {
				logt('автообновление: byway правлен руками -- не трогается');
				au = '';
			}
		} else {
			logt('автообновление: сумма выложенной версии неизвестна -- не трогается');
			au = '';
		}
	}
	wt_au_install(au, y, h);
}

// Потолок журнала обращений 4 МБ: обычно обрезает stat, но учёт можно
// выключить, а cron потерять; ~18 МБ в сутки при 240 МБ памяти.
function wt_access() {
	let a = getenv('BW_ACCESS'), s = fs.stat(a);
	if (s && s.size > 4194304) {
		fs.writefile(a, '');
		logt('журнал обращений превысил 4 МБ и обрезан -- похоже, не запускается учёт трафика (byway stat в cron)');
	}
}

// Все адреса имени: у имени с несколькими A-записями порядок меняется.
function wt_a_all(name, res) {
	let on = false, r = [];
	for (let l in split(run([ 'nslookup', name, res ]).out, '\n')) {
		if (substr(l, 0, 5) == 'Name:') on = true;
		if (!on || substr(l, 0, 7) != 'Address') continue;
		let f = pl_words(l), a = f[length(f) - 1];
		if (pl_v4_ok(a)) push(r, a);
	}
	return r;
}

// DNS через туннель: адрес сервера вписан в конфиг при сборке. Раз в час
// сверяем с внешним резолвером; сменился -- пересборка и reload.
function wt_hosts() {
	if (u('dns_route') != 'tunnel' || wt_fresh('/tmp/byway-hostcheck', 60)) return;
	fs.writefile('/tmp/byway-hostcheck', '');
	let c = null;
	try { c = json(fs.readfile(getenv('BW_OUT')) ?? 'null'); } catch (e) { c = null; }
	let ch = '';
	for (let n, o in c?.dns?.hosts ?? {}) {
		if (type(o) != 'string' || !pl_v4_ok(o)) continue;
		let a = g_server_addr(n);
		if (a === '' || a == o) continue;
		// Прежний адрес среди ответов -- чередование записей, не смена.
		if (index(wt_a_all(n, '8.8.8.8'), o) >= 0) continue;
		ch += ' ' + n + ':' + o + '->' + a;
	}
	if (ch === '') return;
	logf('адрес сервера сменился (%s) -- пересборка конфига', ltrim(ch));
	if (wt_byway('gen').code == 0) wt_reload();
}

// bw_uc watch: раз в 5 минут из cron. Журнал состояния -- только при
// изменении: при исправной работе во флеш не уходит ни байта.
function cmd_watch() {
	wt_restore();
	wt_snapshot();
	wt_heal();
	wt_lists();
	wt_upcheck();
	wt_autoupdate();
	wt_access();
	wt_hosts();

	let cur = sprintf('pid=%s nft=%d rule=%d route=%d dns=%s fakeip=%s', W.pid || 'none', W.tab, W.rul, W.rt, W.dm, W.fk);
	let prev = fs.readfile(WT_LAST) ?? '';
	if (cur == prev && W.healed === '') return;
	// Пометки и значения полей одинаковы на всех языках: строку читают
	// глазами, grep-ом и в отчёте человеку, который русского не знает.
	let why = '';
	if (prev === '') {
		why = '(start)';
	} else {
		let op = split(substr(prev, 4), ' ')[0];
		if (op != (W.pid || 'none')) {
			why = '(restart)';
			// Респавн procd не зовёт plumb on, кэш dnsmasq не сбрасывает
			// никто, а таблица fakedns живёт в памяти Xray. HUP не рвёт резолв.
			if (W.pid !== '' && W.fk == 'yes') {
				pl_dns_flush();
				logt('движок перезапустился — кэш dnsmasq сброшен: прежние подставные адреса недействительны');
			}
		}
	}
	if (W.healed !== '') why = W.healed;
	let lf = getenv('BW_WATCH_LOG'), stamp = trim(run([ 'date', '+%Y-%m-%d %H:%M' ]).out);
	let f = fs.open(lf, 'a');
	if (f) { f.write(stamp + '  ' + cur + (why !== '' ? '  ' + why : '') + '\n'); f.close(); }
	fs.writefile(WT_LAST, cur);
	let all = pl_lines(fs.readfile(lf));
	if (length(filter(all, (l) => l !== '')) > 200) {
		fs.writefile(lf + '.n', join('\n', slice(all, -200)) + '\n');
		fs.rename(lf + '.n', lf);
	}
}

// bw_uc pulse: раз в минуту из cron -- только «движок упал» и «движок
// вернулся». В минуты, кратные пяти, ходит сторож: двойной счёт промахов снял
// бы DNS за полминуты.
function cmd_pulse() {
	let m = int(trim(run([ 'date', '+%M' ]).out));
	if (m % 5 == 0 || u('enabled') != '1' || wt_down_held()) return;
	W.pid = st_xray_pid();
	W.healed = '';
	if (W.pid === '') {
		if (!wt_registered()) return;
		W.dm = wt_dm();
		wt_engine_gone();
	} else if (fs.stat(PL_BLOCK)) {
		fs.unlink(WT_NOPID);
		wt_engine_back();
	} else if (fs.stat(WT_NOPID)) {
		// Движок пропадал, и при открытой модели engine_gone снял перехват без
		// запрета: вернуть его -- дело pulse, а не сторожа через пять минут.
		fs.unlink(WT_NOPID);
		if (!pl_has_table(PL_TABLE)) wt_engine_back();
	}
}
