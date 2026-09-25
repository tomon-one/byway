'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require byway.lang as lang';

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

/* Список направления с диска. Отдельной функцией, потому что его просят
   двое -- счётчик в таблице и поле в окне правки, -- и просят при каждой
   отрисовке. */
function routeList(name) {
	return fs.read(DIR + 'routes/' + name + '.lst').catch(function () { return ''; });
}

/* Поле, за которым стоит файл, а не запись UCI. Читаем заранее в load,
   пишем в write -- дальше LuCI сам решает, когда что вызвать. */
function fileField(s, key, title, hint, content, path) {
	var o = s.option(form.TextValue, key, title, hint);
	o.rows = 18;
	o.monospace = true;
	o.cfgvalue = function () { return content; };
	o.write = function (section_id, value) {
		var v = value || '';
		if (v.length && v.slice(-1) !== '\n') v += '\n';
		return fs.write(path, v);
	};
	/* Пустое поле LuCI отдаёт не в write, а в remove -- значит «стереть
	   список целиком» приходило сюда. Заглушка нужна только когда опция
	   СКРЫТА зависимостью (режим «всё через VPN»): там стирать нечего.
	   Видимое поле, очищенное человеком, обязано опустеть и на диске. */
	o.remove = function (section_id) {
		return this.isActive(section_id) ? fs.write(path, '') : Promise.resolve();
	};
	o.depends('list_mode', 'lists');
	return o;
}

function count(text) {
	return (text || '').split('\n')
		.filter(function (l) { return l.trim() && !/^\s*(\/\/|#)/.test(l); })
		.length;
}

return view.extend({
	load: function () {
		/* Списки направлений здесь НЕ читаем: их просит routeList() при
		   каждой отрисовке. Снимок, снятый один раз, устаревал в пределах
		   одной сессии страницы и молча терял правки. */
		return uci.load('byway').then(function () {
			return Promise.all([
				fs.read(DIR + 'domains.lst').catch(function () { return ''; }),
				fs.read(DIR + 'subnets.lst').catch(function () { return ''; })
			]);
		});
	},

	render: function (data) {
		setTitle();

		var m = new form.Map('byway', _('Что пускать через VPN'),
			_('По спискам — через VPN идёт только перечисленное ниже. Всё через VPN — весь трафик, включая загрузки и обновления.'));

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
		o.default = '1';
		o.rmempty = false;
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
			_('Работают вместе с вашими списками ниже, записи объединяются. Списки byway и itdoginfo-subnets приносят подсети, остальные только домены. Чужие списки никем не проверяются, а подсети в них бывают широкими — byway скажет насколько.'));
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
			var out = E('pre', {
				'style': 'white-space:pre-wrap;margin:.6em 0 0;font-size:90%;display:none'
			}, '');
			function show(text) {
				out.textContent = text || '';
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
						return fs.exec('/usr/local/bin/byway', [ 'presets' ])
							.then(function (r) {
								var t = ((r.stdout || '') + (r.stderr || ''))
									.replace(/\[[0-9;]*m/g, '') ;
								return fs.exec('/etc/init.d/byway', [ 'reload' ])
									.then(function () {
										show((t || _('готово')) + '\n' + _('применено'));
									})
									.catch(function () {
										show((t || '') + '\n' + _('скачано, но не применено — нажмите «Перезапустить» на вкладке «Основное»'));
									});
							})
							.catch(function () {
								show(_('Загрузка идёт дольше, чем панель готова ждать. На роутере она продолжается — обновите страницу через минуту.'));
							});
					})
				}, _('Скачать сейчас')),
				out
			]);
		};

		fileField(s, '_domains',
			_('Домены (') + count(data[0]) + ')',
			_('По одному на строку; строки с // или # — комментарии. Домен покрывает поддомены: example.com ловит и mail.example.com. Кириллица — в пуникоде (xn--…). Точнее: full: — только это имя, keyword: — часть имени, regexp: — регулярное выражение. Строки не по форме byway пропускает и называет при сборке.'),
			data[0] || '', DIR + 'domains.lst');

		fileField(s, '_subnets',
			_('Подсети (') + count(data[1]) + ')',
			_('Диапазоны адресов, по одному на строку, в виде 1.2.3.0/24; одиночный адрес тоже годится. Только IPv4. Нужны для сервисов, которые работают не по именам, — например Telegram. Слишком широкие диапазоны вредны: они уводят в VPN чужой трафик и замедляют его.'),
			data[1] || '', DIR + 'subnets.lst');

		/* ── Направления ───────────────────────────────────────────────
		   «Этот список -- через этот ключ». Отдельная секция UCI на каждое, имя
		   секции служит именем файла со списком: /etc/byway/routes/<имя>.lst.

		   Ключ здесь выбирается ПО МЕТКЕ, а не вписывается: сама ссылка
		   лежит в node_urls на «Основном», и дублировать её значило бы
		   держать один uuid в двух местах и расходиться при первой смене. */
		var routeKeys = (L.toArray(uci.get('byway', 'main', 'node_urls')) || [])
			.map(function (u) {
				var h = u.indexOf('#');
				if (h < 0) return null;
				try { return decodeURIComponent(u.slice(h + 1)); }
				catch (e) { return u.slice(h + 1); }
			}).filter(function (x) { return x; });

		/* GridSection, а не TypedSection: у второй кнопка удаления рисуется
		   ОТДЕЛЬНОЙ строкой выше имени секции и прижата вправо -- издали она
		   читается как кнопка всей страницы, и владелец так и снёс два
		   направления подряд. Сетка кладёт каждое направление строкой
		   таблицы со своими кнопками «Изменить» и «Удалить», а длинный
		   список уводит в окно правки. Так же сделаны правила файрвола и
		   переадресации в штатной панели. */
		var rs = m.section(form.GridSection, 'route', _('Направления'),
			_('Свой список для отдельного ключа: перечисленное в нём пойдёт не через основной ключ, а через выбранный. Имя направления — латиницей, оно же имя файла со списком.'));
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
			var self = this, args = arguments;
			return fs.remove(DIR + 'routes/' + section_id + '.lst')
				.catch(function () { /* файла могло не быть -- это не отказ */ })
				.then(function () { return removeRoute.apply(self, args); });
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
		ro = rs.option(form.DummyValue, '_rcount', _('Записей'));
		ro.cfgvalue = function (section_id) {
			return routeList(section_id).then(function (t) {
				return String(count(t));
			});
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
		ro.remove = function () { return Promise.resolve(); };

		return m.render();
	},

	handleSaveApply: function (ev) {
		return this.super('handleSaveApply', [ ev ]).then(function () {
			ui.showModal(_('Применение'), [
				E('p', { 'class': 'spinning' }, _('Идёт пересборка и перезапуск'))
			]);
			return fs.exec('/usr/local/bin/byway', [ 'gen' ]).then(function (r) {
				var out = ((r.stdout || '') + (r.stderr || ''))
					.replace(/\x1b\[[0-9;]*m/g, '');
				if (r.code !== 0) {
					ui.hideModal();
					ui.addNotification(null, [
						E('p', {}, _('Не применилось — работает прежняя настройка.')),
						E('pre', { 'style': 'white-space:pre-wrap' }, [ out ])
					], 'error');
					return;
				}
				/* Перезапуск отдан procd: он видит commit и зовёт reload,
				   а тот трогает службу только при изменившемся конфиге. */
				ui.hideModal();
				/* Успешный gen тоже бывает не молчаливым: он предупреждает
				   о пересечении с zapret, о подозрительно широкой подсети, о
				   выключенном mux. Раньше весь его вывод выбрасывался при
				   коде 0, и человек не видел этих слов НИКОГДА. */
				if (out.trim())
					ui.addNotification(null, [
						E('p', {}, _('Применено, но byway есть что сказать:')),
						E('pre', { 'style': 'white-space:pre-wrap' }, [ out.trim() ])
					], 'warning');
				else
					ui.addNotification(null, E('p', {}, _('Применено')), 'info');
			});
		});
	}
});
