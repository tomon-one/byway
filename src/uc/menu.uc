// Текстовое меню (бывший ui/menu.sh) поверх тех же команд: команды --
// отдельным вызовом byway (BW_SELF), их вывод -- с отступом.

function m_self() { return getenv('BW_SELF') || '/usr/local/bin/byway'; }

// Строка ввода; конец ввода -- пусто (меню закрывается).
function m_read() {
	fs.stdout?.flush();
	let l = fs.stdin.read('line');
	return l == null ? '' : rtrim(l, '\r\n');
}

function m_line()     { print('  \033[2m──────────────────────────────────────────\033[0m\n'); }
function m_item(n, t) { print('   \033[1m', n, '\033[0m  ', _t(t), '\n'); }
function m_head(t) {
	if (sys([ 'sh', '-c', 'clear 2>/dev/null' ]) != 0) print('\n\n');
	print('\n  \033[1m', _t(t), '\033[0m\n\n');
}
function m_pause() { print(_t('\n  \033[2mEnter — назад\033[0m')); m_read(); print('\n'); }
function m_ask(t)  { print('  ', _t(t), ': '); return m_read(); }

// Подсказка [y/N] латиницей в обоих языках: терминал обычно на английской
// раскладке. Принимается и «д».
function m_yes(t) {
	print('  \033[1;33m', _t(t), '\033[0m [y/N]: ');
	let a = m_read();
	return index('yYдД', substr(a, 0, 1)) >= 0 && a !== '';
}

// Вывод команды byway с отступом.
function m_out(...a) {
	for (let l in pl_lines(run([ m_self(), ...a ], true).out)) print('    ', l, '\n');
}

function m_uci(...kv) {
	for (let x in kv) run([ 'uci', 'set', 'byway.main.' + x ]);
	run([ 'uci', 'commit', 'byway' ]);
	_cur = null;
}

// Пересборка и перезапуск после правки: без неё настройка сохранена, но не
// действует.
function m_apply() {
	print('\n');
	if (sys([ m_self(), 'gen' ]) == 0) {
		// restart на выключенной службе ничего не поднимает, а включить её
		// из меню нельзя (enabled только через uci): сказать об этом.
		if (u('enabled') != '1') {
			print(_t('\n  \033[1;33mсобрано, но byway ВЫКЛЮЧЕН\033[0m — туннеля не будет\n'));
			print(_t('  включить: uci set byway.main.enabled=1 && uci commit byway && /etc/init.d/byway restart\n'));
			return;
		}
		run([ '/etc/init.d/byway', 'restart' ]);
		print(_t('\n  \033[1;32mприменено\033[0m — движок стартует до 15 секунд\n'));
	} else {
		print(_t('\n  \033[1;31mне применилось\033[0m — работает прежняя настройка\n'));
	}
}

// Строка состояния в шапке: без обращений в сеть, меню открывается сразу.
function m_state() {
	let s = st_xray_pid() !== '' ? '\033[32m' + _t('работает') + '\033[0m' : '\033[31m' + _t('не запущена') + '\033[0m';
	let m = u('list_mode') == 'all' ? _t('всё через VPN') : _t('по спискам');
	print('  ', _f('служба: %s     режим: %s', s, m), '\n');
}

function m_connection() {
	while (true) {
		m_head('Подключение к VPN');
		m_item(1, 'Показать текущее');
		m_item(2, 'Вписать ключ');
		m_item(3, 'Загрузить из подписки');
		m_item(4, 'Проверить ключ отдельно, не трогая работающий туннель');
		m_line();
		m_item(0, 'Назад');
		print('\n');
		let r = m_ask('Выбор');
		if (r == '1') {
			print('\n');
			// По переведённым словам: status печатает через словарь.
			let w = [ _t('подключение'), _t('транспорт'), _t('ключ') ], n = 0;
			for (let l in pl_lines(run([ m_self(), 'status' ], true).out))
				if (length(filter(w, (x) => index(l, x) >= 0))) { print('    ', l, '\n'); n++; }
			if (!n) print('    ', _t('подключение не настроено\n'));
			m_pause();
		} else if (r == '2') {
			print('\n');
			print(_t('  Ссылка целиком: vless://… trojan://… ss://… vmess://… hy2://… wireguard://…\n'));
			print(_t('  Ключ никуда не отправляется и в журнал не пишется.\n\n'));
			let k = m_ask('Ключ');
			if (k !== '') {
				print('\n');
				// Проверка до записи: неразобранный ключ в настройках оставит
				// без туннеля и без понятной причины.
				if (run([ m_self(), 'check', k ]).code == 0) {
					m_uci('node_url=' + k, 'conn_mode=key');
					print(_t('  \033[1;32mключ принят\033[0m\n'));
					m_apply();
				} else {
					print(_t('  \033[1;31mключ не разобран\033[0m, вот что говорит проверка:\n\n'));
					for (let l in slice(pl_lines(run([ m_self(), 'check', k ], true).out), -6)) print('    ', l, '\n');
				}
			}
			m_pause();
		} else if (r == '3') {
			print('\n');
			let a = m_ask('Адрес подписки');
			if (a !== '') {
				m_uci('sub_url=' + a);
				print('\n');
				m_out('sub', a);
				print(_t('\n  Ключи выше. Вписать нужный — пункт 2.\n'));
			}
			m_pause();
		} else if (r == '4') {
			print('\n');
			m_out('probe');
			m_pause();
		} else if (r == '0' || r === '') {
			return;
		}
	}
}

function m_mode() {
	while (true) {
		m_head('Режим работы');
		printf(_t('  Сейчас: \033[1m%s\033[0m\n\n'), u('list_mode') == 'all' ? _t('всё через VPN') : _t('по спискам'));
		m_item(1, 'По спискам — через VPN только перечисленное');
		m_item(2, 'Всё через VPN');
		m_item(3, _f('Русские сайты мимо VPN: %s', u('ru_direct') == '1' ? _t('включено') : _t('выключено')));
		m_line();
		m_item(0, 'Назад');
		print('\n');
		let r = m_ask('Выбор');
		if (r == '1') {
			m_uci('list_mode=lists');
			m_apply();
			m_pause();
		} else if (r == '2') {
			print('\n');
			print(_t('  Через VPN пойдёт весь трафик, включая загрузки и обновления.\n'));
			if (m_yes('Включить?')) {
				m_uci('list_mode=all');
				m_apply();
			}
			m_pause();
		} else if (r == '3') {
			m_uci('ru_direct=' + (u('ru_direct') == '1' ? '0' : '1'));
			m_apply();
			m_pause();
		} else if (r == '0' || r === '') {
			return;
		}
	}
}

function m_lists() {
	let own = getenv('BW_LISTS') + '/domains.lst', sl = getenv('BW_LISTS') + '/subnets.lst';
	while (true) {
		// Объединённый список, не только свой: в режиме «всё через VPN» своего
		// нет по построению. Пересобирается при каждом обращении: после
		// добавления домена проверка «уже есть» судила бы по прежнему.
		let dl = mg_path('domains');
		m_head('Списки');
		printf(_t('  доменов %s, подсетей %s\n\n'), lj_count(dl), lj_count(sl));
		m_item(1, 'Показать домены');
		m_item(2, 'Добавить домен');
		m_item(3, 'Убрать домен');
		m_item(4, 'Обновить готовые списки');
		m_line();
		m_item(0, 'Назад');
		print('\n');
		let r = m_ask('Выбор');
		if (r == '1') {
			print('\n');
			sys([ 'sh', '-c', 'grep -vE "^[[:space:]]*$" "$1" 2>/dev/null | more', 'sh', dl ]);
			m_pause();
		} else if (r == '2') {
			print('\n');
			let d = m_ask('Домен');
			if (d !== '') {
				// Проверка -- по объединённому, запись -- в свой файл:
				// объединённый пересобирается, и дописанное туда пропадало.
				if (index(pl_lines(fs.readfile(dl)), d) >= 0) {
					print(_t('\n  уже есть\n'));
				} else {
					let t = fs.readfile(own) ?? '';
					if (t !== '' && substr(t, -1) != '\n') t += '\n';
					fs.writefile(own, t + d + '\n');
					print(_t('\n  добавлено\n'));
					m_apply();
				}
			}
			m_pause();
		} else if (r == '3') {
			print('\n');
			let d = m_ask('Домен');
			if (d !== '') {
				let l = split(fs.readfile(own) ?? '', '\n');
				if (index(l, d) >= 0) {
					fs.writefile(own + '.new', join('\n', filter(l, (x) => x != d)));
					fs.rename(own + '.new', own);
					print(_t('\n  убрано\n'));
					m_apply();
				} else {
					print(_t('\n  такой записи нет\n'));
				}
			}
			m_pause();
		} else if (r == '4') {
			print('\n');
			m_out('presets');
			m_apply();
			m_pause();
		} else if (r == '0' || r === '') {
			return;
		}
	}
}

// Итог после запуска службы: движок ждём (до 12 с) и судим по нему, а не по
// коду init -- он при procd всегда 0.
function m_svc_done(what) {
	if (u('enabled') != '1') {
		print(_t('\n  byway ВЫКЛЮЧЕН настройкой — служба не запускается\n'));
		print(_t('  включить: uci set byway.main.enabled=1 && uci commit byway && /etc/init.d/byway restart\n'));
		return;
	}
	for (let i = 0; i < 12 && st_xray_pid() === ''; i++) sys([ 'sleep', '1' ]);
	if (st_xray_pid() !== '') print('\n  ', what, '\n');
	else print(_t('\n  движок не поднялся — смотреть: logread -e byway\n'));
}

function m_autostart() { return length(filter(fs.lsdir('/etc/rc.d') ?? [], (f) => substr(f, 0, 1) == 'S' && substr(f, -5) == 'byway')) > 0; }

function m_service() {
	while (true) {
		m_head('Служба');
		m_state();
		print('\n');
		m_item(1, 'Перезапустить');
		m_item(2, 'Остановить');
		m_item(3, 'Запустить');
		m_item(4, _f('Автозапуск: %s', m_autostart() ? _t('включён') : _t('выключен')));
		m_line();
		m_item(0, 'Назад');
		print('\n');
		let r = m_ask('Выбор');
		if (r == '1') {
			print('\n');
			sys([ '/etc/init.d/byway', 'restart' ]);
			m_svc_done(_t('перезапущена'));
			m_pause();
		} else if (r == '2') {
			print('\n');
			print(_t('  Туннеля не станет, интернет продолжит работать напрямую.\n'));
			if (m_yes('Остановить?')) {
				sys([ '/etc/init.d/byway', 'stop' ]);
				print(_t('\n  остановлена\n'));
			}
			m_pause();
		} else if (r == '3') {
			print('\n');
			sys([ '/etc/init.d/byway', 'start' ]);
			m_svc_done(_t('запущена'));
			m_pause();
		} else if (r == '4') {
			if (m_autostart()) {
				sys([ '/etc/init.d/byway', 'disable' ]);
				print(_t('\n  автозапуск выключен\n'));
			} else {
				sys([ '/etc/init.d/byway', 'enable' ]);
				print(_t('\n  автозапуск включён\n'));
			}
			m_pause();
		} else if (r == '0' || r === '') {
			return;
		}
	}
}

function m_indent(lines, empty) {
	if (!length(lines)) print('    ', empty);
	for (let l in lines) print('    ', l, '\n');
}

function m_logs() {
	while (true) {
		m_head('Журнал и статистика');
		m_item(1, 'Журнал состояния — что и когда менялось');
		m_item(2, 'Чем пользуются');
		m_item(3, 'Журнал движка');
		m_line();
		m_item(0, 'Назад');
		print('\n');
		let r = m_ask('Выбор');
		if (r == '1') {
			print('\n');
			m_indent(slice(pl_lines(fs.readfile(getenv('BW_LISTS') + '/health.log')), -30), _t('пока пусто\n'));
			m_pause();
		} else if (r == '2') {
			print('\n');
			m_out('top', '25');
			m_pause();
		} else if (r == '3') {
			print('\n');
			m_indent(slice(pl_lines(run([ 'logread', '-e', 'xray' ]).out), -30), _t('пусто\n'));
			m_pause();
		} else if (r == '0' || r === '') {
			return;
		}
	}
}

function m_transfer() {
	while (true) {
		m_head('Экспорт и импорт настроек');
		print(_t('  Все настройки и списки одним текстом: перенести на другой\n'));
		print(_t('  роутер, сохранить перед опытами, приложить к вопросу.\n\n'));
		m_item(1, 'Выгрузить без ключа — такой файл можно показывать');
		m_item(2, 'Выгрузить вместе с ключом');
		m_item(3, 'Принять из файла');
		m_line();
		m_item(4, 'Собрать отчёт для обращения — без ключа, но с диагностикой');
		m_line();
		m_item(0, 'Назад');
		print('\n');
		let r = m_ask('Выбор');
		if (r == '1' || r == '2') {
			print('\n');
			let f = m_ask('Куда сохранить [/tmp/settings-byway.txt]');
			print('\n');
			sys([ m_self(), 'export', f || '/tmp/settings-byway.txt', r == '1' ? '--no-key' : '--with-key' ]);
			m_pause();
		} else if (r == '3') {
			print('\n');
			let f = m_ask('Файл');
			if (f !== '') {
				print('\n');
				print(_t('  Настройки и списки будут заменены содержимым файла.\n'));
				printf(_t('  Прежние сохраняются в %s/before-import/\n\n'), getenv('BW_LISTS'));
				if (m_yes('Принять?')) {
					print('\n');
					if (sys([ m_self(), 'import', f ]) == 0) run([ '/etc/init.d/byway', 'restart' ]);
				}
			}
			m_pause();
		} else if (r == '4') {
			print('\n');
			let f = m_ask('Куда сохранить [/tmp/report-byway.txt]');
			print('\n');
			sys([ m_self(), 'report', f || '/tmp/report-byway.txt' ]);
			m_pause();
		} else if (r == '0' || r === '') {
			return;
		}
	}
}

// bw_uc menu
function cmd_menu() {
	if (sys([ 'sh', '-c', '[ -t 0 ]' ]) != 0) die('меню работает только с терминала: byway menu');
	while (true) {
		m_head('byway ' + getenv('BW_VERSION'));
		m_state();
		print('\n');
		m_item(1, 'Что сейчас происходит');
		m_item(2, 'Проверка связи');
		m_item(3, 'Проверка окружения');
		m_line();
		m_item(4, 'Подключение к VPN');
		m_item(5, 'Режим работы');
		m_item(6, 'Списки');
		m_line();
		m_item(7, 'Служба');
		m_item(8, 'Журнал и статистика');
		m_item(9, 'Экспорт и импорт настроек');
		m_line();
		m_item(0, 'Выход');
		print('\n');
		let r = m_ask('Выбор');
		if (r == '1') { print('\n'); m_out('status'); m_pause(); }
		else if (r == '2') {
			print('\n');
			print(_t('    проверка занимает несколько секунд…\n\n'));
			for (let l in pl_lines(run([ m_self(), 'health' ], true).out)) print('    ', replace(l, '\t', ' '), '\n');
			m_pause();
		}
		else if (r == '3') { print('\n'); m_out('doctor'); m_pause(); }
		else if (r == '4') m_connection();
		else if (r == '5') m_mode();
		else if (r == '6') m_lists();
		else if (r == '7') m_service();
		else if (r == '8') m_logs();
		else if (r == '9') m_transfer();
		else if (r == '0' || r === '') { sys([ 'sh', '-c', 'clear 2>/dev/null' ]); return; }
	}
}
