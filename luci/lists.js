'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require byway.lang as lang';
'require byway.ui as bwui';

/* Короткое имя для перевода. Строки в коде остаются русскими и служат
   ключом словаря: пропущенный перевод выводится по-русски. */
var _ = function (s) { return lang.tr(s); };

var HOSTNAME = null;
/* Скрытая опция не должна стираться при сохранении. LuCI удаляет всё, что
   спрятано через depends, -- и переключение режима на «Всё через VPN» уносило
   из UCI список подключённых пресетов и период их обновления. Своя копия
   функции: в overview.js такая уже есть, но общего модуля у вкладок нет.
   Найдено третьим аудитом 2026-09-07. */
function keepHidden(section_id) {
	if (this.isActive(section_id))
		return form.Value.prototype.remove.apply(this, arguments);
	return Promise.resolve();
}

function setTitle() {
	if (HOSTNAME === null)
		HOSTNAME = (document.title.split(/\s[-|—]\s/)[0] || '').trim();
	document.title = (HOSTNAME ? HOSTNAME + ' | ' : '') + 'byway';
	lang.tabs();
}

/* Режим работы и списки.

   Режима два и оба осмысленны для человека: гнать всё через VPN либо
   разделять по спискам. У podkop было ещё «выключено» и «динамический
   список», но первое дублирует выключатель на Основном, а второе — просто
   другой способ ввести то же самое.

   Списки сделаны ОПЦИЯМИ ФОРМЫ, а не отдельной разметкой ниже. Так LuCI сам
   прячет их по зависимости от режима — сразу, как только переключишь список.
   Прежняя редакция считала видимость по СОХРАНЁННОМУ значению, и списки
   исчезали только после «Применить». */

var DIR = '/etc/byway/';
/* Пакет UCI с ключами (Ф9, п1-12); без прав на него -- пусто. */
var KP = 'byway_key';

/* Удалённые направления: их списки стираются после сохранения. */
var PENDING_RM = [];

function dropRemoved() {
	var gone = PENDING_RM.filter(function (n) { return !uci.get('byway', n); });
	PENDING_RM = PENDING_RM.filter(function (n) { return gone.indexOf(n) < 0; });
	return Promise.all(gone.map(function (n) {
		return fs.remove(DIR + 'routes/' + n + '.lst').catch(function () {});
	}));
}

/* Список направления с диска. Отдельной функцией, потому что его просят
   двое -- счётчик в таблице и поле в окне правки, -- и просят при каждой
   отрисовке. */
function routeList(name) {
	return fs.read(DIR + 'routes/' + name + '.lst').catch(function () { return ''; });
}

/* Поле, за которым стоит файл, а не запись UCI. Читаем заранее в load,
   пишем в write -- дальше LuCI сам решает, когда что вызвать. */
/* Файл, который rpcd не отдаёт (больше ~256 КБ), -- null из load: поле
   только для чтения и запись отвергается. Прежде он приходил пустым, сверка
   совпадала, и «Сохранить» стирала весь список (н1-13). */
function readList(path) {
	return fs.read(path).catch(function () {
		return fs.stat(path).then(function () { return null; }, function () { return ''; });
	});
}

function fileField(s, key, title, hint, content, path) {
	var big = content === null;
	var o = s.option(form.TextValue, key, title, big ?
		_('Список больше, чем панель может показать, — правка консолью: byway add, byway del, byway list.') : hint);
	o.rows = 18;
	o.monospace = true;
	if (big) o.readonly = true;
	o.cfgvalue = function () { return big ? '' : content; };
	/* Файл сверяется с тем, что читали при открытии вкладки: правку,
	   сделанную консолью или другой вкладкой за это время, панель затирала
	   целиком (Ф9, п2-37). Изменился -- не пишем, говорим. */
	var same = function () {
		return readList(path).then(function (cur) {
			if (big || cur === null || cur !== content)
				throw new Error(_('Список изменён на роутере после открытия вкладки — правка не записана. Обновите страницу и повторите.'));
		});
	};
	o.write = function (section_id, value) {
		var v = value || '';
		if (v.length && v.slice(-1) !== '\n') v += '\n';
		return same().then(function () { return fs.write(path, v); })
			.then(function () { content = v; });
	};
	/* Пустое поле LuCI отдаёт не в write, а в remove -- значит «стереть
	   список целиком» приходило сюда. Заглушка нужна только когда опция
	   СКРЫТА зависимостью (режим «всё через VPN»): там стирать нечего.
	   Видимое поле, очищенное человеком, обязано опустеть и на диске. */
	o.remove = function (section_id) {
		return this.isActive(section_id) ?
			same().then(function () { return fs.write(path, ''); }).then(function () { content = ''; }) :
			Promise.resolve();
	};
	o.depends('list_mode', 'lists');
	return o;
}

function count(text) {
	return (text || '').split('\n')
		.filter(function (l) { return l.trim() && !/^\s*(\/\/|#)/.test(l); })
		.length;
}

/* Правка одних файлов списков: сборка и reload -- задачами byway job
   (прямой вызов rpcd убивает через 30 секунд, Ф9, п2-8). */
function applyFiles() {
	ui.showModal(_('Применение'), [
		E('p', { 'class': 'spinning' }, _('Идёт пересборка и перезапуск'))
	]);
	return bwui.jobRun([ 'gen' ]).then(function (r) {
		var out = r.out;
		if (r.code !== 0) {
			ui.hideModal();
			ui.addNotification(null, [
				E('p', {}, _('Не применилось — работает прежняя настройка.')),
				bwui.pretty(out)
			], 'error');
			return;
		}
		/* Правка одного файла списка UCI не меняет, commit не происходит, и
		   procd reload не зовёт: служба оставалась на прежнем конфиге при
		   слове «Применено». Зовём сами; при неизменном конфиге reload ничего
		   не трогает. */
		return bwui.jobRun([ 'reload' ]).then(function (rl) {
			if (rl.code !== 0) throw rl;
			ui.hideModal();
			/* Успешный gen тоже бывает не молчаливым: он предупреждает о
			   пересечении с zapret, о подозрительно широкой подсети, о
			   выключенном mux. */
			var warns = out.split('\n').filter(function (l) {
				return /\[!\]/.test(l) && !/ -- (ожидание|waiting)\s*$/.test(l);
			}).join('\n');
			if (warns.trim())
				ui.addNotification(null, [
					E('p', {}, _('Применено, но byway есть что сказать:')),
					bwui.pretty(warns.trim())
				], 'warning');
			else
				ui.addNotification(null, E('p', {}, _('Применено')), 'info');
		}).catch(function () {
			ui.hideModal();
			ui.addNotification(null, E('p', {},
				_('Конфиг собран, но служба не перезапущена — нажмите «Перезапустить» на вкладке «Основное»')), 'warning');
		});
	});
}

return view.extend({
	load: function () {
		/* Списки направлений здесь НЕ читаем: их просит routeList() при
		   каждой отрисовке. Снимок, снятый один раз, устаревал в пределах
		   одной сессии страницы и молча терял правки. */
		return Promise.all([ uci.load('byway'), L.resolveDefault(uci.load(KP), null) ]).then(function () {
			var names = uci.sections('byway', 'route').map(function (r) { return r['.name']; });
			return Promise.all([
				readList(DIR + 'domains.lst'),
				readList(DIR + 'subnets.lst'),
				Promise.all(names.map(routeList)).then(function (t) {
					var c = {};
					names.forEach(function (n, i) { c[n] = count(t[i]); });
					return c;
				})
			]);
		});
	},

	render: function (data) {
		setTitle();
		bwui.afterApply(_('Не применилось — работает прежняя настройка.'));

		var m = new form.Map('byway', _('Что пускать через VPN'),
			_('По спискам — через VPN идут только сайты и адреса, перечисленные ниже, остальное как обычно, напрямую. Всё через VPN — весь трафик, включая загрузки и обновления.'));

		var s = m.section(form.NamedSection, 'main', 'byway');
		s.addremove = false;
		s.anonymous = true;

		var o = s.option(form.ListValue, 'list_mode', _('Режим'));
		o.value('lists', _('По спискам'));
		o.value('all', _('Всё через VPN'));
		o.default = 'lists';

		/* Галочка вместо списков во «всём». Это те же списки, но одной
		   понятной строкой — и она закрывает главную опасность режима. */
		o = s.option(form.Flag, 'ru_direct', _('.ru, .su и .рф — напрямую'),
			_('Российские сайты мимо VPN. Выключать почти всегда ошибка.'));
		/* Без опции byway её не включает (Ф9, п3-32); поставка вписывает 1. */
		o.default = '0';
		o.rmempty = false;
		/* Скрыта в режиме «по спискам» -- LuCI стирал её при сохранении, и
		   при возврате к «всё через VPN» .ru шли в туннель (Ф9, п3-33). */
		o.remove = keepHidden;
		o.depends('list_mode', 'all');

		o = s.option(form.DummyValue, '_allnote', _('Важно'));
		o.cfgvalue = function () {
			return _('Через VPN пойдёт весь трафик: загрузки, видео, обновления. Если у VPN есть ограничение по объёму, оно кончится быстро.');
		};
		o.depends('list_mode', 'all');

		/* Готовые списки. По умолчанию обновляются только по кнопке: у
		   чужого списка содержимое меняется без предупреждения, и обновление
		   без спроса однажды тихо притащило бы домен, уже лежащий в zapret.
		   byway после загрузки о таких пересечениях говорит вслух, поэтому
		   автоматическое обновление есть, но включает его человек сам. */
		/* DynamicList, а не MultiValue: тот всегда рисует выпадающий список,
		   и три подписи в нём ужимались в одну строку с обрезкой. Здесь
		   подключённые списки стоят строками во всю ширину -- как ключи на
		   «Основном», -- а выбор нового предлагается снизу. */
		o = s.option(form.DynamicList, 'preset', _('Готовые списки'),
			_('Списки сайтов, которые ведут другие люди, — например, всё заблокированное в России. Работают вместе с вашими списками ниже. Списки byway и itdoginfo-subnets приносят ещё и подсети (диапазоны адресов), остальные — только домены. Чужие списки никто не проверяет, а подсети в них бывают широкими — byway скажет насколько.'));
		o.value('byway', _('byway — список разработчика'));
		o.value('itdoginfo-geoblock', _('itdoginfo — закрытое для РФ'));
		o.value('itdoginfo-block', _('itdoginfo — заблокированное в РФ'));
		o.value('itdoginfo-subnets', _('itdoginfo — подсети сервисов и хостеров'));
		o.depends('list_mode', 'lists');
		/* ⚠️ Скрытое поле НЕ стираем. `depends` прячет опцию при переключении
		   режима на «Всё через VPN», а LuCI на сохранении удаляет всё
		   скрытое: список подключённых пресетов и период их обновления
		   пропадали из UCI молча, и вернуть их было можно только руками.
		   Найдено третьим аудитом 2026-09-07; та же защита стоит в
		   overview.js. */
		o.remove = keepHidden;

		o = s.option(form.Value, 'lists_update', _('Период автообновления'),
			_('Например 12h, 2h37m, 1d, 90m; просто число — минуты. Не чаще 30m. Пусто — только по кнопке.'));
		o.placeholder = '12h';
		o.depends('list_mode', 'lists');
		o.remove = keepHidden;
		o.validate = function (section, value) {
			if (!value || value === '0') return true;
			if (!/^([0-9]+d)?([0-9]+h)?([0-9]+m)?$|^[0-9]+$/.test(value))
				return _('Пишется как 12h, 2h37m, 1d или числом минут.');
			return true;
		};

		o = s.option(form.DummyValue, '_refresh', _('Обновить готовые списки'));
		o.depends('list_mode', 'lists');
		o.cfgvalue = function () { return ' '; };
		o.renderWidget = function () {
			/* Спрятан, пока сказать нечего: пустой <pre> тема рисует серой
			   полосой, и на странице появляется прямоугольник ниоткуда.
			   Именно display, а не атрибут hidden: тема задаёт <pre> свой
			   display и в этой борьбе побеждает. */
			var out = E('div', { 'style': 'margin:.6em 0 0;display:none' });
			function show(text) {
				out.innerHTML = '';
				if (text) out.appendChild(bwui.pretty(text));
				out.style.display = text ? 'block' : 'none';
			}
			return E('div', {}, [
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(null, function () {
						show(_('Идёт загрузка…'));
						/* Загрузка пресетов идёт до нескольких минут, а запрос панели
						   живёт около двадцати секунд. Без этой ветки кнопка просто
						   замолкала: человек не знал, скачалось ли, и жал ещё раз,
						   запуская вторую загрузку поверх первой. */
						/* ⚠️ Скачать -- ещё не применить. cmd_presets только кладёт файлы;
						   в работающий конфиг их переносит reload. Сторож в cron и меню в
						   консоли зовут его сами, а кнопка -- нет: до 2026-09-07 человек
						   нажимал «Скачать сейчас», видел «готово» и получал прежнюю
						   маршрутизацию. Найдено третьим аудитом. */
						/* Задачей byway job (скачать и reload): прямой вызов rpcd
						   обрывает через 30 секунд, посреди загрузки. */
						return bwui.jobRun([ 'presets' ], function (t) {
							show(t.trim() || _('Идёт загрузка…'));
						}).then(function (r) {
							show((r.out.trim() || _('готово')) +
								(r.code === 0 ? '\n' + _('применено') : ''));
						});
					})
				}, _('Скачать сейчас')),
				out
			]);
		};

		fileField(s, '_domains',
			_('Домены (') + (data[0] === null ? '?' : count(data[0])) + ')',
			_('По одному сайту на строку, без https:// и без пути: example.com. Сайт покрывает свои поддомены: example.com ловит и mail.example.com. Строки с // или # — комментарии. Русские домены — в пуникоде (xn--…). Для опытных: full: — только это имя, keyword: — часть имени, regexp: — регулярное выражение. Неправильные строки byway пропускает и называет при сборке.'),
			data[0], DIR + 'domains.lst');

		fileField(s, '_subnets',
			_('Подсети (') + (data[1] === null ? '?' : count(data[1])) + ')',
			_('Диапазоны IP-адресов, по одному на строку, в виде 1.2.3.0/24; одиночный адрес тоже годится. Только IPv4. Нужны для сервисов, которые соединяются по адресам, а не по именам сайтов, — например Telegram. Слишком широкие диапазоны вредны: они уводят в VPN чужой трафик и замедляют его.'),
			data[1], DIR + 'subnets.lst');

		/* ── Направления ───────────────────────────────────────────────
		   «Этот список -- через этот ключ». Отдельная секция UCI на каждое, имя
		   секции служит именем файла со списком: /etc/byway/routes/<имя>.lst.

		   Ключ здесь выбирается ПО МЕТКЕ, а не вписывается: сама ссылка
		   лежит в node_urls на «Основном», и дублировать её значило бы
		   держать один uuid в двух местах и расходиться при первой смене. */
		var routeKeys = (L.toArray(uci.get(KP, 'main', 'node_urls')) || [])
			.map(function (u) {
				var h = u.indexOf('#');
				if (h < 0) return null;
				return bwui.pctd(u.slice(h + 1));
			}).filter(function (x) { return x; });

		/* GridSection, а не TypedSection: у второй кнопка удаления рисуется
		   ОТДЕЛЬНОЙ строкой выше имени секции и прижата вправо -- издали она
		   читается как кнопка всей страницы, и владелец так и снёс два
		   направления подряд. Сетка кладёт каждое направление строкой
		   таблицы со своими кнопками «Изменить» и «Удалить», а длинный
		   список уводит в окно правки. Так же сделаны правила файрвола и
		   переадресации в штатной панели. */
		var rs = m.section(form.GridSection, 'route', _('Направления'),
			_('Отдельный список, который идёт через другой ключ, а не через основной: например, видео — через один сервер, работа — через другой. Имя направления — латиницей, оно же имя файла со списком.'));
		rs.addremove = true;
		rs.anonymous = false;
		rs.sortable = false;
		rs.addbtntitle = _('Добавить направление');
		rs.modaltitle = function (section_id) {
			return _('Направление') + ' — ' + section_id;
		};

		/* Удаление спрашивает и убирает файл списка. Штатный handleRemove
		   не делает ни того, ни другого: направление исчезало по одному
		   нажатию без вопроса, а его список оставался лежать в
		   /etc/byway/routes/ -- byway такой файл не читает, но он путает
		   того, кто заглянет в каталог, и doctor о нём говорит. */
		var removeRoute = rs.handleRemove;
		rs.handleRemove = function (section_id, ev) {
			if (!confirm(_('Направление «%s» будет удалено вместе со своим списком. Продолжить?')
					.replace('%s', section_id)))
				return Promise.resolve();
			/* Файл -- после сохранения, когда секции и правда нет: удалённый
			   сразу, он пропадал и при «Сбросить» (Ф9, п4-71). */
			if (PENDING_RM.indexOf(section_id) < 0) PENDING_RM.push(section_id);
			return removeRoute.apply(this, arguments);
		};

		var ro = rs.option(form.ListValue, 'label', _('Ключ'));
		if (routeKeys.length)
			routeKeys.forEach(function (k) { ro.value(k, k); });
		else
			ro.value('', _('сначала добавьте ключи на «Основном»'));

		ro = rs.option(form.Flag, 'enabled', _('Включено'));
		ro.default = '1';
		ro.rmempty = false;

		/* Сколько записей -- видно прямо в таблице, чтобы не открывать
		   окно ради одного числа. */
		/* Файл читается ЗАНОВО при каждой отрисовке, а не берётся из снимка,
		   сделанного в load(). Со снимком счётчик оставался старым после
		   правки списка в окне, а повторное открытие окна показывало
		   вчерашний текст -- и дописанная поверх него строка затирала то,
		   что было сохранено между заходом на вкладку и этим моментом.
		   cfgvalue вправе вернуть обещание: form.js делает
		   Promise.resolve(this.cfgvalue(...)).then(renderWidget). */
		/* Ячейка таблицы обещание не ждёт: колонка была пустой всегда (Ф9,
		   п3-36). Число -- из чтения при загрузке вкладки. */
		ro = rs.option(form.DummyValue, '_rcount', _('Записей'));
		ro.cfgvalue = function (section_id) {
			return String(data[2][section_id] != null ? data[2][section_id] : '—');
		};

		ro = rs.option(form.TextValue, '_rlist', _('Список'),
			_('Домены и подсети вперемешку, по одному на строку. Что похоже на адрес — пойдёт правилом по адресам, остальное по именам. Форма записи та же, что в общих списках выше, включая full:, keyword: и regexp:.'));
		ro.modalonly = true;
		ro.rows = 12;
		ro.monospace = true;
		ro.cfgvalue = function (section_id) { return routeList(section_id); };
		ro.write = function (section_id, value) {
			var v = value || '';
			if (v.length && v.slice(-1) !== '\n') v += '\n';
			return fs.write(DIR + 'routes/' + section_id + '.lst', v);
		};
		/* Пустое поле LuCI отдаёт в remove: очистить список направления было
		   нельзя (Ф9, п4-70). Скрытое -- не трогаем. */
		ro.remove = function (section_id) {
			return this.isActive(section_id) ? fs.write(DIR + 'routes/' + section_id + '.lst', '') : Promise.resolve();
		};

		return m.render();
	},

	handleSaveApply: function (ev, mode) {
		/* Правка UCI (направления) -- применяет LuCI: procd reload сам
		   собирает конфиг, итог покажет render (bwui.markApplied). Своя сборка
		   рядом шла параллельно с ним и давала двойной перезапуск (Ф9, п4-73).
		   Правку одних файлов списков UCI не видит: её применяем сами. */
		return this.handleSave(ev).then(function () {
			return uci.changes();
		}).then(function (ch) {
			if (ch && ch.byway && ch.byway.length) {
				bwui.markApplied();
				return dropRemoved().then(function () { ui.changes.apply(mode == '0'); });
			}
			return dropRemoved().then(applyFiles);
		});
	}
});
