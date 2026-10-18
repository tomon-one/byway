'use strict';
'require baseclass';
'require fs';
'require ui';
'require byway.lang as lang';

/* Общее для всех вкладок byway.

   Здесь НЕТ ни одной строки оформления, и это решение, а не упущение.
   Прежняя редакция держала свой <style> на полсотни правил: сдвигала
   подписи, перекладывала описания, гасила значок вопроса, ловила
   перерисовку секций наблюдателем. Каждое из этих правил боролось с темой
   LuCI, и на страницах, собранных не из полей формы, а из своих <div>,
   борьба заканчивалась вничью: элементы плавали, текст налезал друг на
   друга, и починка одной вкладки ничего не давала остальным.

   Причина была не в теме. Страницы собирались вручную -- <h3>, <pre>,
   <button> прямо в разметке, -- а тема расставляет по местам только то,
   что построено её же классами: form.Map, секции и опции. Отсюда правило,
   которому теперь следуют все пять вкладок:

     всё, что видно на странице, -- это опция формы.

   Кнопка -- form.Button, вывод -- form.DummyValue, заголовок с описанием --
   form.SectionValue с вложенной секцией. Так делают штатные страницы
   OpenWrt (система -> резервные копии, состояние -> nftables), и выглядят
   они одинаково с остальной панелью без единого своего правила CSS. */

/* Второе правило, к правилу про опции формы: ЧУЖОЙ ТЕКСТ ПЕРЕДАЁТСЯ В E()
   МАССИВОМ, а не отдельной строкой.

   E() с одиночной строкой-ребёнком вставляет её через innerHTML -- текстовым
   узлом строка становится только внутри массива. А чужого текста на страницах
   хватает: метка ключа из подписки (всё, что стоит после решётки в ссылке),
   вывод byway status и health, ответы gen. Подписка приходит от постороннего,
   и метка вида <img src=x onerror=...> выполнялась бы в ОТКРЫТОЙ сессии LuCI,
   то есть от root: сменить пароль, переписать firewall, забрать конфиг.

   Поэтому: E('pre', {...}, [ out ]), а не E('pre', {...}, out). Постоянные
   строки перевода можно и без массива, но проще не различать. */

var BYWAY = '/usr/local/bin/byway';
var _ = function (x) { return lang.tr(x); };

/* Номер версии, с которой поставлена панель: установщик вписывает его вместо
   метки. Браузер держит модули панели в кэше, LuCI сбрасывает его только со
   своей версией, и после `byway update` человек видел прежнюю панель над
   новым byway. Расхождение -- предупреждение с тем, как обновить страницу. */
var BUILT = '@@BYWAY_VERSION@@';
if (BUILT.indexOf('@@') < 0) {
	fs.exec(BYWAY, [ 'version' ]).then(function (r) {
		var v = ((r.stdout || '').split(' ')[1] || '').trim();
		if (v && v !== BUILT)
			ui.addNotification(null, E('p', {}, [
				_('Панель byway обновлена до %s, а браузер показывает прежнюю (%s) из кэша. Обновить страницу без кэша: Ctrl+Shift+R; на телефоне — очистить кэш браузера.').format(v, BUILT) ]), 'warning');
	}).catch(function () {});
}

return baseclass.extend({
	BYWAY: BYWAY,

	/* Цветовые последовательности из вывода byway: в консоли они нужны,
	   в браузере это мусор вида [1;32m. */
	plain: function (s) { return (s || '').replace(/\x1b\[[0-9;]*m/g, ''); },

	/* Вывод byway для человека (владелец 2026-10-18: «разбросано, выделить
	   итог цветом, компактнее»). Метки [ ok ] [ ?? ] [ !! ] (doctor) и [*] [!]
	   [x] -- цветным значком; «== конец» задачи и пустые строки подряд --
	   прочь; итог пробы -- цветом, проба по ключам -- таблицей. Текст тот же,
	   что в консоли: копируется как есть. mono -- колонки (сводка, журнал,
	   статистика): моноширинный и без переноса. */
	pretty: function (text, mono) {
		var self = this;
		var lines = this.plain(text).replace(/\s+$/, '').split('\n')
			.filter(function (l) { return !/^== \S+$/.test(l.trim()); });
		var keep = [], blank = false;
		lines.forEach(function (l) {
			if (!l.trim()) { if (!blank && keep.length) keep.push(''); blank = true; }
			else { keep.push(l); blank = false; }
		});
		var box = E('div', { 'style': 'font-size:90%;line-height:1.5;' +
			(mono ? 'font-family:monospace;white-space:pre' : 'white-space:pre-wrap') });
		var probe = this.probeTable(keep);
		if (probe) { box.appendChild(probe.table); keep = probe.rest; }
		keep.forEach(function (l) { box.appendChild(self.line(l, mono)); });
		return box;
	},

	/* Одна строка: значок вместо метки, слова итога -- цветом. */
	line: function (l, mono) {
		var C = { ok: '#2a2', warn: '#d80', bad: '#c00' };
		if (!l.trim()) return E('div', { 'style': 'height:.6em' });
		if (!mono) {
			/* Заголовок раздела (doctor): строка без отступа и без метки. */
			if (/^\S/.test(l) && !/^\[/.test(l))
				return E('div', { 'style': 'font-weight:bold;margin-top:.2em' }, l);
			/* Подсказка к неисправности -- глубокий отступ без метки. */
			if (/^ {5,}\S/.test(l))
				return E('div', { 'style': 'opacity:.75;padding-left:2.6em;font-size:95%' }, l.trim());
		}
		var m = l.match(/^(\s*)\[\s*(ok|\?\?|!!|\*|!|x)\s*\]\s?(.*)$/);
		var ind = '', body = l, mark = null;
		if (m) {
			ind = m[1]; body = m[3];
			mark = { 'ok': [ '✓', C.ok ], '??': [ '!', C.warn ], '!': [ '!', C.warn ],
			         '!!': [ '✗', C.bad ], 'x': [ '✗', C.bad ] }[m[2]] || null;
		}
		var row = E('div', {}, ind);
		if (mark)
			row.appendChild(E('span', { 'style': 'color:' + mark[1] + ';font-weight:bold;display:inline-block;width:1.3em' }, mark[0]));
		var sum = body.match(/(\d+)\D+?(\d+)/);
		if (/^(работают|\d+ of \d+ work)/.test(body) && sum) {
			var a = +sum[1], b = +sum[2];
			row.appendChild(E('span', { 'style': 'font-weight:bold;color:' +
				(a === b ? C.ok : a ? C.warn : C.bad) }, body));
		} else if (m && m[2] === '!!' || m && m[2] === 'x') {
			row.appendChild(E('span', { 'style': 'color:' + C.bad }, body));
		} else if (m && m[2] === '!') {
			row.appendChild(E('span', { 'style': 'color:' + C.warn }, body));
		} else if (/^(окружение в порядке|the environment is fine)$/.test(body)) {
			row.appendChild(E('span', { 'style': 'font-weight:bold;color:' + C.ok }, body));
		} else {
			row.appendChild(document.createTextNode(body));
		}
		return row;
	},

	/* Проба ключей (byway probe, --all): строки «  транспорт  сервер:порт
	   итог» под заголовками «[*] ключ N имя» -- таблицей. Нет таких строк --
	   null. rest -- что осталось для построчного вывода. */
	probeTable: function (lines) {
		var C = { ok: '#2a2', bad: '#c00' };
		var rows = [], rest = [], name = '', cur = null;
		var OK = /^(РАБОТАЕТ|WORKS)\s+(выход|exit)\s+(\S+)\s+([\d.]+)\s*(\S*)/;
		lines.forEach(function (l) {
			var h = l.match(/^\[\*\]\s+(ключ|key)\s+\d+\s*(.*)$/);
			if (h) { name = h[2]; return; }
			var d = l.match(/^  (\S+)\s+(\S+:\d+)\s+(\S.*)$/);
			if (d) {
				var ok = d[3].match(OK);
				cur = { name: name, tr: d[1], srv: d[2], ok: !!ok,
				        st: ok ? ok[1] : d[3].trim(), ip: ok ? ok[3] : '',
				        t: ok ? (+ok[4]).toFixed(2) + ' ' + ok[5] : '', more: [] };
				rows.push(cur); name = '';
				return;
			}
			if (cur && /^      \S/.test(l)) { cur.more.push(l.trim()); return; }
			if (l.trim() || rest.length) rest.push(l);
		});
		if (!rows.length) return null;
		var td = 'padding:.15em 1em .15em 0;vertical-align:top';
		var table = E('table', { 'style': 'border-collapse:collapse;margin-bottom:.4em' },
			rows.map(function (r) {
				return E('tr', {}, [
					E('td', { 'style': td + ';color:' + (r.ok ? C.ok : C.bad) + ';font-weight:bold' }, r.ok ? '✓' : '✗'),
					E('td', { 'style': td }, r.name || '—'),
					E('td', { 'style': td + ';opacity:.7' }, r.tr),
					E('td', { 'style': td + ';opacity:.7' }, r.srv),
					E('td', { 'style': td + ';color:' + (r.ok ? C.ok : C.bad), 'title': r.ip }, [
						r.st,
						r.more.length ? E('div', { 'style': 'color:inherit;opacity:.75;font-size:90%;white-space:pre-wrap' }, r.more.join('\n')) : ''
					]),
					E('td', { 'style': td + ';opacity:.7;white-space:nowrap' }, r.t)
				]);
			}));
		/* пустые строки между ключами больше не нужны */
		while (rest.length && !rest[0].trim()) rest.shift();
		return { table: table, rest: rest };
	},

	run: function (args) {
		var self = this;
		return fs.exec(BYWAY, args).then(function (r) {
			return self.plain((r.stdout || '') + (r.stderr || ''));
		}).catch(function () { return ''; });
	},

	/* Обработчик кнопки очистки: `byway clear <что>`. Спрашиваем, потому
	   что стирается накопленное за недели, а вернуть нечем. Отказ называем
	   вслух -- молчаливая перезагрузка выглядела как «стёрлось», даже когда
	   byway отказал. */
	clearAction: function (what, question) {
		var self = this;
		return function () {
			if (!confirm(question)) return;
			return fs.exec(BYWAY, [ 'clear', what ]).then(function (r) {
				if (r.code !== 0) {
					ui.addNotification(null, E('p', {}, [
						_('Очистить не удалось: ') +
						self.plain((r.stderr || '') + (r.stdout || '')) ]), 'error');
					return;
				}
				location.reload();
			});
		};
	},

	/* Живой блок вывода: <pre>, который держим по ссылке и переписываем из
	   обработчиков. Отдаётся из cfgvalue как есть -- dom.append принимает
	   узел наравне со строкой. Искать его потом по id нельзя: обещание
	   успевает раньше, чем LuCI вставит разметку в документ.

	   Пустой блок СПРЯТАН: тема рисует <pre> серой заливкой, и на чистой
	   странице появлялся прямоугольник ниоткуда -- под «Ответ» в импорте и
	   обновлении, где до первого нажатия сказать нечего. */
	output: function (text) {
		var box = E('div', {
			'class': 'byway-out', 'style': 'max-width:100%'
		}, [ this.pretty(text || '') ]);
		if (!text) box.style.display = 'none';
		return box;
	},

	/* То же, но для вывода с колонками: перенос выключен, вместо него
	   прокрутка. На телефоне таблица «чем пользуются» иначе переносилась по
	   пробелам, и колонки переставали быть колонками. */
	table: function (text) {
		var box = E('div', {
			'class': 'byway-out', 'data-mono': '1', 'style': 'overflow-x:auto;max-width:100%'
		}, [ this.pretty(text || '', true) ]);
		if (!text) box.style.display = 'none';
		return box;
	},

	/* Переписать блок, отданный output()/table(), и показать его, если было
	   что сказать.

	   Прячется не только блок, но и ВСЯ строка формы с ярлыком. Прятать один
	   блок мало: под «Ответ» оставалась подписанная пустая строка -- ярлык
	   есть, содержимого нет, и человек читает её как «здесь что-то должно
	   быть, но сломалось». Владелец показал это на приёмке 2026-09-07. */
	row: function (box) {
		return box && box.closest ? box.closest('.cbi-value') : null;
	},

	/* Долгая работа (обновление, замена ядра): `byway job` запускает её в
	   фоне и сразу отвечает, а ход читается `byway job log` раз в три
	   секунды, пока тот отвечает кодом 3 («ещё идёт»). Запрос панели живёт
	   секунды, установка -- минуты: напрямую она обрывалась бы посередине. */
	job: function (args, box) {
		var self = this;
		self.say(box, _('запуск…'));
		return fs.exec(self.BYWAY, [ 'job' ].concat(args)).then(function (r) {
			if (r.code !== 0) {
				self.say(box, self.plain((r.stdout || '') + (r.stderr || '')).trim());
				return;
			}
			return new Promise(function (done) {
				(function poll() {
					fs.exec(self.BYWAY, [ 'job', 'log' ]).then(function (l) {
						/* Предупреждения и сведения Xray (строки с датой) человеку
						   ничего не говорят: «WebSocket устарел» под итогом пробы
						   читается как поломка. Ошибки остаются. */
						var out = (l.stdout || '').split('\n').filter(function (x) {
							return !/^\s*\d{4}\/\d\d\/\d\d \d\d:\d\d:\d\d\S* \[(Warning|Info|Debug)\]/.test(x);
						}).join('\n');
						self.say(box, out.trim() || _('запуск…'));
						if (l.code === 3) setTimeout(poll, 3000);
						else done();
					}).catch(function () { setTimeout(poll, 3000); });
				})();
			});
		});
	},

	/* Итог сохранения -- ПОСЛЕ перезагрузки страницы. «Сохранить и применить»
	   LuCI ждёт подтверждения и перезагружает страницу через полторы секунды:
	   всё, что вкладка показывала до этого, стиралось, не успев прочитаться.
	   gen, запущенный панелью рядом, сталкивался с gen из reload службы (procd
	   зовёт его на тот же commit) и печатал «уже идёт -- ожидание», а свой
	   location.reload обрывал само применение (2026-10-16). Поэтому метку
	   ставит событие LuCI uci-applied, а вкладка при отрисовке забирает её и
	   один раз собирает конфиг. extra -- что сделать вместо сборки (язык). */
	markApplied: function (extra) {
		document.addEventListener('uci-applied', function () {
			try {
				var m = extra || {};
				m.t = Date.now();
				sessionStorage.setItem('byway-applied', JSON.stringify(m));
			} catch (e) { /* без хранилища итог просто не покажется */ }
		}, { once: true });
	},

	takeApplied: function () {
		var m = null;
		try {
			m = JSON.parse(sessionStorage.getItem('byway-applied') || 'null');
			sessionStorage.removeItem('byway-applied');
		} catch (e) { return null; }
		return (m && Date.now() - m.t < 120000) ? m : null;
	},

	/* Сборка и её итог. Строка ожидания замка -- не предупреждение: это
	   reload службы ещё собирает тот же конфиг. */
	genReport: function (failText) {
		var self = this;
		return fs.exec(BYWAY, [ 'gen' ]).then(function (r) {
			var out = self.plain((r.stdout || '') + (r.stderr || ''));
			if (r.code !== 0) {
				ui.addNotification(null, [
					E('p', {}, [ failText ]),
					self.pretty(out)
				], 'error');
				return;
			}
			/* Успешный gen тоже бывает не молчаливым: он предупреждает
			   о пересечении с zapret, о подозрительно широкой подсети, о
			   выключенном mux. */
			var warns = out.split('\n').filter(function (l) {
				return /\[!\]/.test(l) && !/ -- (ожидание|waiting)\s*$/.test(l);
			}).join('\n');
			if (warns.trim())
				ui.addNotification(null, [
					E('p', {}, _('Применено, но byway есть что сказать:')),
					self.pretty(warns.trim())
				], 'warning');
			else
				ui.addNotification(null, E('p', {}, _('Применено')), 'info');
		}).catch(function () {});
	},

	afterApply: function (failText) {
		return this.takeApplied() ? this.genReport(failText) : Promise.resolve();
	},

	say: function (box, text) {
		box.innerHTML = '';
		box.appendChild(this.pretty(text || '', box.getAttribute('data-mono') === '1'));
		box.style.display = text ? '' : 'none';
		var row = this.row(box);
		if (row) row.style.display = text ? '' : 'none';
	},

	/* Разовая уборка после отрисовки: строки, чей блок вывода пуст, убрать
	   целиком. Зовётся из вкладки, потому что до вставки в документ строки
	   ещё нет -- box.closest() в момент сборки формы возвращает null. */
	hideEmptyRows: function (node) {
		try {
			var boxes = node.querySelectorAll('.byway-out');
			for (var i = 0; i < boxes.length; i++) {
				if (boxes[i].style.display !== 'none') continue;
				var row = this.row(boxes[i]);
				if (row) row.style.display = 'none';
			}
		} catch (e) { /* строка просто останется видимой -- не поломка */ }
		return node;
	}
});
