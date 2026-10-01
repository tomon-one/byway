'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require byway.lang as lang';
'require byway.ui as bwui';

/* Обслуживание: то, на что смотрят, и то, чем управляют руками. Настроек
   здесь почти нет -- только состояние, журналы и действия.

   Разделение с «Дополнительным» простое: там значения, которые меняют раз в
   жизни, здесь -- то, куда заглядывают, когда что-то пошло не так.

   Страница собрана ТОЛЬКО из опций формы: заголовок с пояснением --
   form.SectionValue, кнопка -- form.Button, вывод -- form.DummyValue.
   Прежняя редакция рисовала всё это своими <h3>, <pre> и <button> внутри
   .cbi-section, и тема раскладывала их как придётся: подписи стояли по
   одному краю, поля по другому, кнопки уезжали к чужому блоку. Ничего из
   этого не чинится своим CSS -- чинится тем, что страница перестаёт спорить
   с формой. */

var _ = function (s) { return lang.tr(s); };

var HOSTNAME = null;
function setTitle() {
	if (HOSTNAME === null)
		HOSTNAME = (document.title.split(/\s[-|—]\s/)[0] || '').trim();
	document.title = (HOSTNAME ? HOSTNAME + ' | ' : '') + 'byway';
	lang.tabs();
}

var IMPORT_TMP = '/tmp/byway-import.txt';

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('byway'),
			bwui.run([ 'status' ]),
			fs.read('/etc/byway/health.log').catch(function () { return ''; })
		]);
	},

	render: function (data) {
		var impBtn = null;   /* кнопка приёма -- нужна после отрисовки */
		setTitle();

		var m = new form.Map('byway', _('Обслуживание'));
		var s = m.section(form.NamedSection, 'main', 'byway');
		s.addremove = false;
		s.anonymous = true;

		/* Блок с заголовком и пояснением. Внутри -- обычные опции, поэтому
		   подписи, поля и кнопки стоят по тем же колонкам, что и везде. */
		function block(name, title, descr) {
			return s.option(form.SectionValue, name, form.NamedSection,
				'main', 'byway', title, descr).subsection;
		}

		/* Поле, за которым не стоит запись UCI: живёт только на странице. */
		function scratch(o) {
			o.load = function () { return ''; };
			o.write = function () {};
			o.remove = function () {};
			o.optional = true;
			return o;
		}

		var ss, o;

		/* ── Полное состояние ─────────────────────────────────────────── */

		ss = block('_full', _('Полное состояние'));

		o = ss.option(form.DummyValue, '_status', _('Сводка'));
		o.cfgvalue = function () { return bwui.table(data[1] || ''); };

		/* ── Журнал состояния ─────────────────────────────────────────── */

		ss = block('_log', _('Журнал состояния'),
			_('Пишется раз в пять минут и только когда что-то изменилось. Смена pid — это перезапуск службы.'));

		o = ss.option(form.DummyValue, '_hlog', _('Записи'));
		o.cfgvalue = function () {
			return bwui.table((data[2] || '').trim() ||
				_('пока пусто — значит ничего не менялось'));
		};

		o = ss.option(form.Button, '_logclear', _('Очистить'));
		o.inputstyle = 'negative';
		o.inputtitle = _('Очистить журнал');
		o.onclick = bwui.clearAction('log',
			_('Записи об отвалах и перезапусках будут стёрты без возможности вернуть. Продолжить?'));

		/* ── Обновление ───────────────────────────────────────────────── */

		/* Кнопка только СПРАШИВАЕТ, ставить предлагается из консоли, и это не
		   половинчатость: скачивание с распаковкой и установкой не
		   укладывается в двадцать секунд, которые живёт запрос панели, а
		   оборванная на середине установка -- худшее из возможных состояний.

		   Довод против автоматики никуда не делся: регулярный стук в GitHub с
		   домашнего адреса -- ровный след «здесь стоит byway», снимаемый на
		   стороне провайдера без всякого разбора трафика. Поэтому обе
		   настройки ниже выключаются, и обе названы вслух: до 2026-09-06 этот
		   блок утверждал, что byway никуда не ходит сам, а сторож к тому
		   времени уже ходил раз в сутки. */
		ss = block('_update', _('Обновление'),
			_('Панель только проверяет обновления: установка дольше, чем она ждёт ответа. Установить — командой byway update в консоли или автоматически (ниже).'));

		o = ss.option(form.Flag, 'update_check', _('Проверка обновлений раз в сутки'),
			_('byway раз в сутки спрашивает GitHub, нет ли версии новее, и говорит об этом в сводке. Ничего не скачивает и не ставит. Плата за удобство: с домашнего адреса раз в сутки уходит запрос к GitHub — по нему видно, что здесь стоит byway, и видно это без всякого разбора трафика.'));
		o.default = '1';
		o.rmempty = false;

		o = ss.option(form.Flag, 'auto_update', _('Автоматическая установка обновлений'),
			_('Выключено намеренно: обновление перезапускает службу, то есть на минуту отнимает туннель у всего дома. Включив, вы соглашаетесь, что это произойдёт в назначенный час ниже, по часам роутера, и не раньше чем через трое суток после выхода версии — важные ставятся сразу. Обновление идёт только внутри минорной версии, а если туннель не поднялся за две с половиной минуты, byway сам возвращает прежнюю. След утром — строка «ночью …» в сводке.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('update_check', '1');

		o = ss.option(form.Value, 'auto_update_hour', _('Час обновления'),
			_('По часам роутера. Его время и пояс — «Система → Система».'));
		o.datatype = 'range(0,23)';
		o.placeholder = '04';
		o.depends('auto_update', '1');
		/* Спрятанное depends поле LuCI на сохранении стирает -- тот же
		   keepHidden, что на вкладке списков. */
		o.remove = function () {};

		/* Тот же порядок, что и в приёме: сначала действие, потом ответ. */
		var updMsg = bwui.output('');
		o = ss.option(form.Button, '_check', _('Проверить'));
		o.inputstyle = 'action';
		o.inputtitle = _('Проверить обновление');
		o.onclick = function () {
			bwui.say(updMsg, _('идёт проверка…'));
			return fs.exec(bwui.BYWAY, [ 'update', '--check' ]).then(function (r) {
				bwui.say(updMsg, bwui.plain((r.stdout || '') + (r.stderr || ''))
					.replace(/^\[.\]\s*/, '').trim() || _('нет ответа'));
			}).catch(function () {
				bwui.say(updMsg, _('Спросить не вышло — byway ничего не ответил.'));
			});
		};

		o = ss.option(form.DummyValue, '_updmsg', _('Ответ'));
		o.cfgvalue = function () { return updMsg; };

		/* ── Ядро Xray ────────────────────────────────────────────────── */

		/* Та же причина, что у обновления: замена ядра -- это скачивание
		   десятка мегабайт, проверка суммы и перезапуск службы, минута и
		   дольше. Панель только показывает версии и готовую команду; ставит
		   byway engine из консоли, и откатывается он там же сам. */
		ss = block('_engine', _('Ядро Xray'),
			_('Есть ли обновление ядра Xray. Заменить — командой byway engine в консоли; если туннель на новом ядре не поднимется, byway вернёт прежнее.'));

		var engMsg = bwui.output('');
		o = ss.option(form.Button, '_engcheck', _('Проверить'));
		o.inputstyle = 'action';
		o.inputtitle = _('Проверить обновление ядра');
		o.onclick = function () {
			bwui.say(engMsg, _('идёт проверка…'));
			return fs.exec(bwui.BYWAY, [ 'engine', '--check' ]).then(function (r) {
				bwui.say(engMsg, bwui.plain((r.stdout || '') + (r.stderr || ''))
					.replace(/^\[.\]\s*/gm, '').trim() || _('нет ответа'));
			}).catch(function () {
				bwui.say(engMsg, _('Спросить не вышло — byway ничего не ответил.'));
			});
		};

		o = ss.option(form.DummyValue, '_engmsg', _('Ответ'));
		o.cfgvalue = function () { return engMsg; };

		/* ── Экспорт ──────────────────────────────────────────────────── */

		ss = block('_export', _('Экспорт настроек'),
			_('Все настройки и списки одним текстом. Такой текст переносят на другой роутер, сохраняют перед опытами или прикладывают к вопросу о поломке.'));

		var noKey = ss.option(form.Flag, '_nokey', _('Без ключа от VPN'),
			_('Со снятой галочкой в текст попадёт ключ, и показывать такой файл нельзя никому.'));
		noKey.default = '1';
		scratch(noKey);
		noKey.load = function () { return '1'; };

		var expOut = ss.option(form.TextValue, '_exported', _('Выгрузка'));
		expOut.rows = 8;
		expOut.monospace = true;
		expOut.readonly = true;
		expOut.placeholder = _('здесь появится выгрузка');
		scratch(expOut);

		/* С каким состоянием галочки собрана та выгрузка, что сейчас в поле.
		   Без этого «Скачать файлом» отдавал показанный текст, а текст мог
		   быть собран ДО того, как галочку включили: человек видит «без
		   ключа», а в файле ключ. По самому тексту это не определить --
		   первая строка одинакова в обоих случаях. */
		var shownNoKey = null;

		o = ss.option(form.Button, '_show', '');
		o.inputstyle = 'action';
		o.inputtitle = _('Показать');
		o.onclick = function () {
			var noKeyNow = noKey.formvalue('main') === '1';
			var args = [ 'export' ];
			if (noKeyNow) args.push('--no-key');
			var el = expOut.getUIElement('main');
			shownNoKey = null;
			el.setValue(_('идёт сбор…'));
			return bwui.run(args).then(function (txt) {
				el.setValue(txt || _('не получилось'));
				if (txt) shownNoKey = noKeyNow;
			});
		};

		o = ss.option(form.Button, '_save', '');
		o.inputtitle = _('Скачать файлом');
		o.onclick = function () {
			var txt = expOut.getUIElement('main').getValue();
			if (!txt || txt.indexOf('# byway export') !== 0) {
				ui.addNotification(null,
					E('p', {}, _('Сначала нужно нажать «Показать».')), 'warning');
				return;
			}
			if (shownNoKey !== (noKey.formvalue('main') === '1')) {
				ui.addNotification(null, E('p', {},
					_('Галочка «Без ключа» изменилась после сбора — нажмите «Показать» ещё раз, иначе в файл уйдёт не то, что вы видите.')),
					'warning');
				return;
			}
			/* Скачивание делаем из уже показанного текста, а не вторым
			   вызовом: иначе галочка «без ключа» и содержимое файла могли бы
			   разойтись, и в файл ушло бы не то, что человек видел. */
			var url = URL.createObjectURL(new Blob([ txt ], { type: 'text/plain' }));
			var a = E('a', { 'href': url, 'download': 'byway-settings.txt' });
			document.body.appendChild(a); a.click(); document.body.removeChild(a);
			URL.revokeObjectURL(url);
		};

		/* ── Импорт ───────────────────────────────────────────────────── */

		ss = block('_import', _('Импорт настроек'),
			_('Списки будут заменены целиком. Прежние сохраняются в /etc/byway/before-import/ — если новая настройка не соберётся, byway вернёт всё как было.'));

		var impIn = ss.option(form.TextValue, '_incoming', _('Выгрузка'));
		impIn.rows = 8;
		impIn.monospace = true;
		impIn.placeholder = _('выгрузка целиком, начиная с # byway export');
		scratch(impIn);

		/* ⚠️ У приёма СВОЯ галочка, и выключенная. Прежде кнопка «Принять»
		   читала галочку из блока ЭКСПОРТА -- а та включена по умолчанию,
		   чтобы ключ не попадал в показываемый текст. Выходило, что импорт
		   через панель НИКОГДА не брал ключ из выгрузки: настройки
		   принимались, ключ оставался прежним, и на свежей установке конфиг
		   не собирался вовсе. Ошибка вылезала тремя шагами позже -- «конфиг
		   не собрался», -- и на настоящую причину не указывала ничем.
		   Поймано приёмкой владельца 2026-09-07. */
		var impNoKey = ss.option(form.Flag, '_impnokey', _('Оставить нынешний ключ'),
			_('Принять всё, кроме подключения к VPN. По умолчанию ключ берётся из выгрузки — если он в ней есть.'));
		impNoKey.default = '0';
		scratch(impNoKey);
		impNoKey.load = function () { return '0'; };

		/* Порядок: вставил текст -> нажал -> прочитал ответ. Прежде «Ответ»
		   стоял НАД кнопкой, и читалось это как «сначала ответ, потом
		   действие». */
		var impMsg = bwui.output('');
		o = ss.option(form.Button, '_take', '');
		impBtn = o;
		o.inputstyle = 'negative';
		o.inputtitle = _('Принять');
		o.onclick = function () {
			var txt = (impIn.getUIElement('main').getValue() || '').trim();
			if (txt.indexOf('# byway export') !== 0) {
				bwui.say(impMsg,
					_('Это не выгрузка byway: в первой строке должно быть «# byway export».'));
				return;
			}
			if (!confirm(_('Настройки и списки будут заменены содержимым выгрузки. Продолжить?')))
				return;
			bwui.say(impMsg, _('идёт применение…'));
			var args = [ 'import', IMPORT_TMP ];
			if (impNoKey.formvalue('main') === '1') args.push('--no-key');
			/* Зовём fs.exec напрямую, а не через run: там код возврата
			   теряется, и служба перезапускалась бы даже после отказа --
			   поверх настроек, которые byway только что откатил. */
			return fs.write(IMPORT_TMP, txt + '\n').then(function () {
				return fs.exec(bwui.BYWAY, args);
			}).then(function (r) {
				bwui.say(impMsg,
					bwui.plain((r.stdout || '') + (r.stderr || '')) || _('нет ответа'));
				if (r.code !== 0) {
					ui.addNotification(null,
						E('p', {}, _('Не принято — осталось как было.')), 'error');
					return;
				}
				/* byway import сам делает uci commit, а дальше службу
				   перезапускает procd -- и только если конфиг изменился. */
				ui.addNotification(null, E('p', {}, _('Принято и применено')), 'info');
			}).catch(function () {
				/* Обрыв по времени -- не отказ: запрос панели живёт около
				   двадцати секунд, а приём на роутере идёт своим ходом. */
				bwui.say(impMsg, _('Приём идёт дольше, чем панель готова ждать. На роутере он продолжается — откройте вкладку заново через минуту и посмотрите «Полное состояние».'));
			});
		};

		o = ss.option(form.DummyValue, '_inmsg', _('Ответ'));
		o.cfgvalue = function () { return impMsg; };

		/* ── Чем пользуются ───────────────────────────────────────────── */

		/* В режиме «всё через VPN» сбор бессмыслен: туда попадёт каждый
		   домен, какой откроют, и список «чем пользуются» перестанет
		   отвечать на вопрос, ради которого заводился. */
		var byLists = uci.get('byway', 'main', 'list_mode') !== 'all';
		var showUsage = uci.get('byway', 'main', 'show_usage') === '1' && byLists;

		ss = block('_stats', _('Чем пользуются'),
			_('Какие записи списков правда используются — пригодится, когда список чистят. Данные не покидают роутер.'));

		if (byLists) {
			o = ss.option(form.Flag, 'show_usage', _('Сбор статистики'));
			o.default = '0';
			o.rmempty = false;
		} else {
			o = ss.option(form.DummyValue, '_nousage', _('Статистика'));
			o.cfgvalue = function () {
				return _('Не собирается: в режиме «Всё через VPN» туда попадает каждый открытый домен.');
			};
		}

		if (showUsage) {
			var usage = bwui.table(_('загружается…'));
			bwui.run([ 'top', '25' ]).then(function (t) {
				bwui.say(usage, (t && t.trim()) ? t : _('пока пусто'));
			});

			o = ss.option(form.DummyValue, '_usage', _('Записи'),
				_('Соединения к подсетям идут по адресам и к домену не привязываются — они одной строкой «(по IP)».'));
			o.cfgvalue = function () { return usage; };

			o = ss.option(form.Button, '_usageclear', _('Очистить'));
			o.inputstyle = 'negative';
			o.inputtitle = _('Очистить статистику');
			o.onclick = bwui.clearAction('stat',
				_('Накопленная статистика будет стёрта без возможности вернуть. Продолжить?'));
		}

		/* Кнопка «Принять» показывается, только когда в поле есть текст.
		   Пустая кнопка рядом с пустым полем -- это приглашение нажать её и
		   получить отказ; владелец на приёмке спросил ровно это: «я вставил
		   текст, а что дальше то?».

		   Делаем ПОСЛЕ отрисовки и в try: виджет доступен только собранным, а
		   если тема поменяет разметку -- кнопка просто останется видна, как
		   была. Отказ здесь не должен ронять вкладку. */
		return m.render().then(function (node) {
			try {
				var ui = impIn.getUIElement('main');
				var btn = impBtn.map.findElement('[data-name="_take"]') ||
					(impBtn.getUIElement('main') || {}).node;
				var row = btn && btn.closest ? btn.closest('.cbi-value') : null;
				if (ui && row) {
					var sync = function () {
						row.style.display =
							(ui.getValue() || '').trim() ? '' : 'none';
					};
					sync();
					var el = ui.node && ui.node.querySelector
						? ui.node.querySelector('textarea') : null;
					if (el) {
						el.addEventListener('input', sync);
						el.addEventListener('change', sync);
					}
				}
			} catch (e) { /* кнопка останется видимой -- это не поломка */ }
			return bwui.hideEmptyRows(node);
		});
	},

	/* Таблица «Записи» и кнопка очистки заводятся при отрисовке, по
	   сохранённому значению show_usage. Значит включение сбора без
	   перезагрузки страницы ничего на экране не меняло: человек ставил
	   галочку, применял и не понимал, где обещанное. Перечитываем страницу,
	   но ТОЛЬКО когда галочка действительно поменялась. */
	handleSaveApply: function (ev) {
		var before = uci.get('byway', 'main', 'show_usage');
		return this.super('handleSaveApply', [ ev ]).then(function () {
			if (uci.get('byway', 'main', 'show_usage') !== before)
				location.reload();
		});
	}
});
