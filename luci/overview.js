'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require byway.lang as lang';

/* Заголовок вкладки: «имя роутера | byway». LuCI ставит «имя — Раздел», и при
   нескольких открытых вкладках их не различить. Имя запоминаем при первом
   заходе: повторный render иначе съел бы его. */
/* Короткое имя для перевода. Строки в коде остаются русскими и служат
   ключом словаря: пропущенный перевод выводится по-русски. */
var _ = function (s) { return lang.tr(s); };

/* Перезапуск уже идёт. Флаг живёт в МОДУЛЕ, а не в замыкании render:
   LuCI перерисовывает вкладку при переходах, и кнопка из нового render
   ничего не знала о запущенном перезапуске -- два `/etc/init.d/byway
   restart` подряд поднимали движок дважды. */
var RESTARTING = false;

/* Поле со списком ключей и перерисовка выбора активного. Держим на уровне
   модуля, потому что подписка складывает ключи из своего обработчика --
   класс SubPicker объявлен раньше, чем render заводит опции. Без этого
   загруженные из подписки ключи не появлялись ни в списке, ни в выборе,
   пока страницу не сохранишь и не откроешь заново. */
var KEYS_OPT = null;
var REPAINT_ACTIVE = null;

/* remove() для полей, которые прячутся зависимостью: скрытое значение
   сохраняем, очистку видимого поля пропускаем к штатной обработке. */
function keepHidden(section_id) {
	if (this.isActive(section_id))
		return form.Value.prototype.remove.apply(this, arguments);
	return Promise.resolve();
}

var HOSTNAME = null;
var FAVICON_WAS = null;

/* Значок вкладки. Своего favicon у приложения LuCI не бывает: он один на всю
   панель и принадлежит теме, а не разделу. Но вкладку эта страница и так
   переименовывает под себя строкой ниже, и значок -- ровно та же мера тем же
   способом: пока открыт byway, во вкладке его знак.

   Прежнее значение запоминается и возвращается, как только адрес перестал
   быть страницей byway. Без этого панель роутера носила бы чужой значок и
   после ухода отсюда -- мелочь, но чужое место. Берётся плоское начертание:
   во вкладке шестнадцать пикселей, а грани там превращаются в грязь. */
function faviconLink() {
	var l = document.querySelector('link[rel~="icon"]');
	if (!l) {
		l = document.createElement('link');
		l.rel = 'icon';
		document.head.appendChild(l);
	}
	return l;
}

function setFavicon() {
	var l = faviconLink();
	if (FAVICON_WAS === null)
		FAVICON_WAS = l.getAttribute('href') || '';
	l.type = 'image/svg+xml';
	l.setAttribute('href', '/luci-static/resources/byway/logo-flat.svg');
}

function restoreFavicon() {
	if (FAVICON_WAS === null || /\/byway(\/|$)/.test(location.pathname))
		return;
	var l = faviconLink();
	l.removeAttribute('type');
	if (FAVICON_WAS)
		l.setAttribute('href', FAVICON_WAS);
	else
		l.parentNode.removeChild(l);
	FAVICON_WAS = null;
}

window.addEventListener('popstate', restoreFavicon);
window.addEventListener('hashchange', restoreFavicon);

function setTitle() {
	if (HOSTNAME === null)
		HOSTNAME = (document.title.split(/\s[-|—]\s/)[0] || '').trim();
	document.title = (HOSTNAME ? HOSTNAME + ' | ' : '') + 'byway';
	setFavicon();
	lang.tabs();
}

/* Основное: работает ли, через что, и как это поменять.

   Третья редакция этой страницы. Первая говорила языком разработчика.
   Вторая спрятала выбор ключа за кнопкой в модальном окне -- владелец
   справедливо сказал, что о такой возможности не догадаешься, а список
   ключей в окне не читается как выбор.

   Теперь способ подключения выбирается ЯВНО, списком, и всё происходит
   прямо на странице. Видно, что вариантов два, ещё до того как что-то
   нажмёшь. */

var BYWAY = '/usr/local/bin/byway';

function plain(s) { return (s || '').replace(/\x1b\[[0-9;]*m/g, ''); }

function run(args) {
	return fs.exec(BYWAY, args).then(function (r) {
		return plain((r.stdout || '') + (r.stderr || ''));
	}).catch(function () { return ''; });
}

/* Подписки почти всегда приходят в base64. Раскодировать надо здесь: на
   роутере нечем, а в браузере atob есть всегда. */
function maybeDecode(s) {
	if (/:\/\//.test(s)) return s;
	try {
		var bin = atob((s || '').replace(/\s+/g, ''));
		var b = new Uint8Array(bin.length);
		for (var i = 0; i < bin.length; i++) b[i] = bin.charCodeAt(i);
		return new TextDecoder('utf-8').decode(b);
	} catch (e) { return s; }
}

/* Что byway разбирает. Каждая схема проверена прогоном: конфиг собирается и
   принимается ядром Xray-core, а hysteria2, wireguard и vless с шифрованием --
   ещё и соединением через настоящий сервер (стенд 2026-10-01). tuic и hysteria
   первой версии отсутствуют в самом Xray-core — это не наше ограничение. */
var SUPPORTED = [ 'vless', 'vmess', 'trojan', 'ss', 'socks', 'hysteria2', 'hy2',
                  'wireguard', 'wg' ];
var KNOWN = SUPPORTED.concat([ 'ssr', 'hysteria', 'hysteria2', 'hy2', 'tuic',
                               'wireguard', 'warp' ]);

function parseKeys(text) {
	var out = [];
	/* По СТРОКАМ, а не по любому пробелу. Подписка -- один ключ на строку, а
	   метка после решётки сплошь и рядом с пробелами: «#Node 2 EU». Разбор
	   по пробелам резал такую метку на первом же и терял хвост ключа. */
	(text || '').split(/[\r\n]+/).forEach(function (raw) {
		var line = (raw || '').trim();
		var m0 = line.match(/^([a-z0-9+.-]+):\/\//i);
		if (!m0) return;
		var scheme = m0[1].toLowerCase();
		if (KNOWN.indexOf(scheme) < 0) return;
		var label = '';
		var h = line.indexOf('#');
		if (h >= 0) {
			try { label = decodeURIComponent(line.slice(h + 1)); }
			catch (e) { label = line.slice(h + 1); }
		}
		var ty = line.match(/[?&]type=([a-z]+)/);
		var se = line.match(/[?&]security=([a-z]+)/);
		out.push({
			url: line,
			label: label || _('(без имени)'),
			ok: SUPPORTED.indexOf(scheme) >= 0,
			kind: scheme + (ty ? ' · ' + ty[1] : '') + (se ? ' · ' + se[1] : '')
		});
	});
	return out;
}

/* Имя ключа для показа: то, что после решётки. Без него в списке видны
   только неотличимые простыни. */
function keyLabel(url) {
	var h = (url || '').indexOf('#');
	if (h < 0) return url.slice(0, 40) + '…';
	try { return decodeURIComponent(url.slice(h + 1)); }
	catch (e) { return url.slice(h + 1); }
}

/* ── проверки ── */
/* Функция, а не готовый объект: на уровне модуля uci ещё не загружен, и
   перевод в этот момент вернул бы русский текст даже при английском языке.
   К вызову из render конфигурация уже прочитана. */
function checks() {
	return {
		service: _('Служба'),
		vpn:     _('Связь с VPN'),
		tunnel:  _('Трафик через VPN'),
		dns:     _('DNS')
	};
}
var TONE = { ok: '#2a2', warn: '#e90', fail: '#c00' };

function healthBox(text) {
	var seen = {};
	(text || '').split('\n').forEach(function (l) {
		var p = l.split('\t');
		if (p.length >= 3) seen[p[0]] = { state: p[1], note: p[2] };
	});
	return E('div', {}, Object.keys(checks()).map(function (k) {
		var v = seen[k] || { state: 'warn', note: _('нет данных') };
		return E('div', {
			'style': 'display:inline-block;min-width:13em;margin:0 1.5em .4em 0'
		}, [
			E('span', { 'style': 'color:' + (TONE[v.state] || TONE.warn) +
			                     ';font-size:1.3em' }, '●'),
			E('span', { 'style': 'margin-left:.4em' }, checks()[k]),
			E('span', { 'style': 'margin-left:.4em;opacity:.65' }, [ '— ' + v.note ])
		]);
	}));
}

/* Строки «ВНИМАНИЕ …» из статуса. byway печатает их ради человека, а панель
   их выбрасывала: connName разбирает вывод по первому слову, и всё, что не
   «ключ»/«транспорт»/«подключение», просто терялось. Между тем среди них три
   вида предупреждения о запрете «не пускать мимо VPN» -- включая «ВЕСЬ трафик
   мимо VPN ЗАКРЫТ». Человек с закрытым трафиком видел в панели обычную
   строку подключения. Найдено третьим аудитом 2026-09-07. */
function connWarn(statusText) {
	var out = [];
	(statusText || '').split('\n').forEach(function (l) {
		var t = l.replace(/\u001b\[[0-9;]*m/g, '').trim();
		if (/^(ВНИМАНИЕ|WARNING)\s/.test(t))
			out.push(t.replace(/^(ВНИМАНИЕ|WARNING)\s+/, ''));
	});
	return out;
}

function connName(statusText) {
	var g = {};
	(statusText || '').split('\n').forEach(function (l) {
		/* \s+, а не \s{2,}: строка «подключение автовыбор из N ключей»
		   выровнена ОДНИМ пробелом -- слово длиной ровно в колонку. С
		   прежним условием эта строка не разбиралась, и в режиме
		   «несколько, автоматически» панель показывала «(ключ не задан)»
		   на исправно настроенном туннеле. */
		var m = l.match(/^(\S+)\s+(.*)$/);
		if (m) g[m[1]] = m[2].trim();
	});
	/* В режиме автовыбора одного ключа нет: status пишет «подключение» и
	   «сейчас». В обычном — «ключ» и «транспорт». Читаем оба вида.
	   ⚠️ Имя поля здесь и в byway меняются ТОЛЬКО вместе. */
	if (g[_('подключение')])
		return g[_('подключение')] + (g[_('сейчас')] ? _('  ·  сейчас ') + g[_('сейчас')] : '');
	return (g[_('ключ')] || _('(ключ не задан)')) +
	       (g[_('транспорт')] ? '  ·  ' + g[_('транспорт')] : '');
}

/* Выбор ключа из подписки. Живёт прямо в форме, а не в окне: возможность
   должна быть видна, а не найдена. Список — настоящие радиокнопки, чтобы
   читалось как выбор. */
var SubPicker = form.DummyValue.extend({
	renderWidget: function (section_id, option_index, cfgvalue) {
		var self = this;
		var box = E('div', {});
		var listBox = E('div', { 'style': 'margin-top:.7em' });

		var btn = E('button', {
			'class': 'btn cbi-button-action',
			'click': ui.createHandlerFn(this, function () {
				/* Спрашиваем значение У ФОРМЫ, а не ищем поле по id в DOM.
				   Прежняя редакция искала селектором и не находила ничего:
				   идентификаторы у LuCI свои. Из-за этого кнопка ругалась
				   «впиши адрес», когда адрес был вписан. */
				var url = '';
				try {
					url = (self.section.formvalue(section_id, 'sub_url') || '').trim();
				} catch (e) { url = ''; }
				if (!url)
					url = (uci.get('byway', 'main', 'sub_url') || '').trim();

				if (!url) {
					listBox.innerHTML = '';
					listBox.appendChild(E('em', { 'style': 'color:#c00' },
						_('Адрес подписки указывается в поле выше.')));
					return Promise.resolve();
				}
				/* Схему дописываем сами: человек копирует адрес откуда угодно
				   и «https://» спереди может не попасть. */
				if (!/^https?:\/\//i.test(url)) url = 'https://' + url;
				listBox.innerHTML = '';
				listBox.appendChild(E('span', { 'class': 'spinning' },
					_('Список загружается…')));
				return run([ 'sub', url ]).then(function (body) {
					var keys = parseKeys(maybeDecode(body));
					listBox.innerHTML = '';
					if (!keys.length) {
						/* Если byway назвал причину -- показываем её, а не
						   общую догадку: «подписка не скачалась» и «пришло,
						   но ключей внутри нет» лечатся по-разному. */
						var why = (body || '').replace(/^\s*\[[x!*]\]\s*/, '').trim();
						listBox.appendChild(E('em', { 'style': 'color:#c00' },
							why ? why
							    : _('Ключей не пришло. Либо адрес неверен, либо ответ не успел прийти — вторая причина вероятнее, если подписка обычно работает.')));
						return;
					}
					var cur = uci.get('byway', 'main', 'node_url') || '';

					/* Складываем ВСЕ пригодные ключи разом. Тогда режимы
					   «выбрать вручную» и «автовыбор» получают их готовыми,
					   и подписку не надо загружать заново. */
					var good = keys.filter(function (x) { return x.ok; })
					               .map(function (x) { return x.url; });
					uci.set('byway', 'main', 'node_urls', good);
					uci.changed();
					/* То же самое -- в само поле и в выбор активного, иначе
					   на экране останется прежний список, а в настройках уже
					   будет новый. */
					if (KEYS_OPT) {
						var el = KEYS_OPT.getUIElement('main');
						if (el) el.setValue(good);
					}
					if (REPAINT_ACTIVE) REPAINT_ACTIVE();
					listBox.appendChild(E('div', {
						'style': 'margin-bottom:.5em;opacity:.75'
					}, _('Найдено ключей: ') + keys.length +
					   _('. Нужный отмечается ниже:')));

					keys.forEach(function (k, i) {
						var id = 'bwkey' + i;
						var radio = E('input', {
							'type': 'radio',
							'name': 'bwkey',
							'id': id,
							'style': 'margin-right:.5em',
							'disabled': k.ok ? null : 'disabled',
							'checked': (k.url === cur) ? 'checked' : null
						});
						radio.addEventListener('change', function () {
							uci.set('byway', 'main', 'node_url', k.url);
							uci.set('byway', 'main', 'conn_mode', 'sub');
							uci.changed();
						});
						listBox.appendChild(E('div', {
							'style': 'padding:.25em 0' + (k.ok ? '' : ';opacity:.45')
						}, [
							radio,
							E('label', {
								'for': id,
								'style': 'cursor:' + (k.ok ? 'pointer' : 'default')
							}, [
								/* textContent, а не третьим аргументом E(): одиночную
								   строку LuCI кладёт через innerHTML, и метка после
								   решётки в чужой ссылке становится разметкой --
								   выполнение кода в открытой админке роутера. */
								(function (s) { s.textContent = k.label; return s; })(
									E('span', {
										'style': 'display:inline-block;min-width:16em'
									})),
								E('span', { 'style': 'opacity:.6' },
									k.kind + (k.ok ? '' : _(' — byway такое не умеет')))
							])
						]));
					});
					listBox.appendChild(E('div', {
						'class': 'cbi-value-description',
						'style': 'margin-top:.6em'
					}, _('После выбора — кнопка «Применить» внизу страницы.')));
				});
			})
		}, _('Загрузить список ключей'));

		box.appendChild(btn);
		box.appendChild(listBox);
		return box;
	}
});

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('byway'),
			run([ 'health' ]),
			run([ 'status', '--short' ])
		]);
	},

	/* Своего применения у этой вкладки не было: на трёх других после
	   сохранения вызывается gen и показывается ошибка, а на той, куда вводят
	   ключ, не показывалось ничего. Человек уверен, что ключ принят, а туннель
	   работает на прежнем конфиге -- или не работает вовсе. */
	handleSaveApply: function (ev) {
		return this.super('handleSaveApply', [ ev ]).then(function () {
			return fs.exec(BYWAY, [ 'gen' ]).then(function (r) {
				var out = plain((r.stdout || '') + (r.stderr || ''));
				if (r.code !== 0) {
					ui.addNotification(null, [
						E('p', {}, _('Ключ не принят — работает прежняя настройка.')),
						E('pre', { 'style': 'white-space:pre-wrap' }, [ out ])
					], 'error');
					return;
				}
				/* Успешный gen тоже бывает не молчаливым: он предупреждает
				   о пересечении с zapret, о подозрительно широкой подсети, о
				   выключенном mux. Раньше весь его вывод выбрасывался при
				   коде 0, и человек не видел этих слов НИКОГДА. */
				var warns = out.split('\n').filter(function (l) { return /\[!\]/.test(l); }).join('\n');
				if (warns.trim())
					ui.addNotification(null, [
						E('p', {}, _('Применено, но byway есть что сказать:')),
						E('pre', { 'style': 'white-space:pre-wrap' }, [ warns.trim() ])
					], 'warning');
				else
					ui.addNotification(null, E('p', {}, _('Применено')), 'info');
			});
		});
	},

	render: function (data) {
		setTitle();

		var health = E('div', {}, healthBox(data[1]));
		var nameEl = E('span', { 'style': 'font-weight:bold' }, [ connName(data[2]) ]);
		var warnEl = E('div', {});
		var showWarn = function (txt) {
			warnEl.innerHTML = '';
			connWarn(txt).forEach(function (w) {
				warnEl.appendChild(E('div', {
					'style': 'color:#c00; font-weight:bold; margin-top:4px'
				}, [ '\u26a0 ' + w ]));
			});
		};
		showWarn(data[2]);

		var refresh = function () {
			return Promise.all([ run([ 'health' ]), run([ 'status', '--short' ]) ])
				.then(function (r) {
					health.innerHTML = '';
					health.appendChild(healthBox(r[0]));
					nameEl.textContent = connName(r[1]);
					showWarn(r[1]);
				});
		};

		/* Опроса по таймеру НЕТ намеренно: health ходит в сеть, а render
		   вызывается при каждом переходе по вкладкам, отчего опросчики
		   копились и укладывали роутер. Только по кнопке и при открытии. */

		var m = new form.Map('byway', 'byway',
			_('Часть трафика идёт через VPN, остальное напрямую.'));
		var s = m.section(form.NamedSection, 'main', 'byway');
		s.addremove = false;
		s.anonymous = true;

		/* Проверка -- такие же опции формы, как и настройки ниже. Прежде
		   этот блок собирался своими <div> и <button> и вставлялся рядом с
		   картой: тема раскладывала его по своим правилам, и он стоял не по
		   тем колонкам, что остальная страница. */
		var ss = s.option(form.SectionValue, '_check', form.NamedSection,
			'main', 'byway', _('Проверка')).subsection;

		var o = ss.option(form.DummyValue, '_health', _('Состояние'));
		o.cfgvalue = function () { return health; };

		o = ss.option(form.DummyValue, '_conn', _('Подключение'));
		o.cfgvalue = function () { return E('div', {}, [ nameEl, warnEl ]); };

		o = ss.option(form.Button, '_restart', _('Служба'));
		o.inputstyle = 'action';
		o.inputtitle = _('Перезапустить');
		o.onclick = function () {
			if (RESTARTING) {
				ui.addNotification(null, E('p', {},
					_('Перезапуск уже идёт — дождитесь его.')), 'info');
				return;
			}
			RESTARTING = true;
			ui.showModal(_('Перезапуск'), [
				E('p', { 'class': 'spinning' }, _('Идёт перезапуск'))
			]);
			/* Перезапуск СЛУЖБЫ, а не подъём обвязки. Прежде звалась
			   plumb on: она ставит правила поверх работающего движка, но
			   остановленную службу не запускает -- то есть кнопка не делала
			   ничего ровно в том случае, ради которого её и нажимают. */
			return fs.exec('/etc/init.d/byway', [ 'restart' ]).then(function (r) {
				if (r && r.code !== 0) {
					ui.hideModal();
					ui.addNotification(null, E('p', {},
						_('Перезапустить не удалось: ') +
						plain((r.stderr || '') + (r.stdout || ''))), 'error');
					RESTARTING = false;
					return refresh();
				}
				/* Движок поднимается около пятнадцати секунд: проверять
				   раньше значит показать красное на исправном. */
				return new Promise(function (ok) {
					window.setTimeout(ok, 15000);
				}).then(function () {
					ui.hideModal();
					RESTARTING = false;
					return refresh();
				});
			}).catch(function (e) {
				/* Обрыв по времени -- НЕ отказ. Запрос панели живёт около
				   двадцати секунд, а перезапуск на роутере идёт своим ходом
				   и после обрыва продолжается. Называть это «не удалось»
				   значит врать: туннель в этот момент как раз поднимается. */
				var slow = /timed out|timeout/i.test(String(e));
				ui.hideModal();
				ui.addNotification(null, E('p', {}, slow
					? _('Перезапуск идёт дольше, чем панель готова ждать. На роутере он продолжается — проверка обновится сама.')
					: _('Перезапустить не удалось: ') + e), slow ? 'info' : 'error');
				return new Promise(function (ok) {
					window.setTimeout(ok, 15000);
				}).then(function () {
					RESTARTING = false;
					return refresh();
				});
			});
		};

		o = ss.option(form.Button, '_recheck', _('Проверка'));
		o.inputtitle = _('Проверить сейчас');
		o.onclick = function () { return refresh(); };

		/* ── Настройки ────────────────────────────────────────────────── */

		o = s.option(form.Flag, 'enabled', _('Включить'),
			_('Выключить — интернет останется, VPN не будет.'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'conn_mode', _('Способ подключения'),
			_('byway понимает vless, vmess, trojan, shadowsocks, socks, hysteria2 и wireguard. Автоматически — Xray-core замеряет задержку и ведёт трафик через самый быстрый живой ключ.'));
		o.value('key', _('Один ключ'));
		o.value('sub', _('Загрузка из подписки'));
		o.value('selector', _('Несколько, вручную'));
		o.value('urltest', _('Несколько, автоматически'));
		o.value('outbound', _('Свой конфиг'));
		o.default = 'key';

		o = s.option(form.TextValue, 'node_url', _('Ключ'),
			_('Ссылка целиком. Имя после решётки станет названием подключения.'));
		o.rows = 3;
		o.monospace = true;
		o.depends('conn_mode', 'key');
		/* LuCI удаляет значение опции, если она скрыта зависимостью. Здесь это
		   означало: выбрал «Загрузка из подписки» -- и панель стёрла ключ,
		   который сама же дала выбрать. Ключ хранится один на все режимы.

		   Но глушить remove НАСОВСЕМ нельзя: тем же путём LuCI обрабатывает
		   и осознанную очистку -- человек стёр текст в поле, которое сейчас
		   на экране. С безусловной заглушкой такая правка молча не
		   сохранялась. Отличаем одно от другого по isActive: скрытая
		   зависимостью опция неактивна. */
		o.remove = keepHidden;

		o = s.option(form.Value, 'sub_url', _('Адрес подписки'),
			_('Адрес https://…, по которому сервис отдаёт список ключей. Это не сам ключ.'));
		o.placeholder = 'https://example.com/sub/abcdef';
		o.depends('conn_mode', 'sub');
		o.remove = keepHidden;

		o = s.option(SubPicker, '_pick', _('Ключ из подписки'));
		o.depends('conn_mode', 'sub');

		/* Несколько ключей сразу. Загрузка подписки складывает их сюда сама,
		   так что обычно вписывать руками не придётся. */
		var keysOpt = s.option(form.DynamicList, 'node_urls', _('Ключи'),
			_('По одному на строку. Подписка заполняет их сама.'));
		keysOpt.depends('conn_mode', 'selector');
		keysOpt.depends('conn_mode', 'urltest');
		keysOpt.remove = function () {};

		/* Список ключей берётся ЗАНОВО при каждой отрисовке, а не один раз при
		   входе на страницу. Со снимком, сделанным в render, добавленный ключ
		   не появлялся в выборе ниже: LuCI после сохранения перерисовывает
		   секции, но render вкладки заново не зовёт, и снимок оставался
		   вчерашним до перезагрузки страницы.
		   Сперва спрашиваем само поле -- оно знает и про несохранённые правки,
		   -- и только если виджета ещё нет, берём из UCI. */
		function keyList() {
			var live = null;
			try { live = keysOpt.formvalue('main'); } catch (e) { live = null; }
			if (live && live.length) return live;
			return L.toArray(uci.get('byway', 'main', 'node_urls'));
		}

		/* Выбор активного ключа сделан ОТДЕЛЬНЫМ виджетом, а не второй опцией
		   с именем node_url. Две опции с одним именем LuCI не допускает: вторая
		   ломает первую, и поле «Ключ» в режиме «один ключ» просто исчезало. */
		o = s.option(form.DummyValue, '_active', _('Активный ключ'));
		o.depends('conn_mode', 'selector');
		o.cfgvalue = function () { return ' '; };
		o.renderWidget = function () {
			var box = E('div', {});
			REPAINT_ACTIVE = function () { paintActive(box); };
			REPAINT_ACTIVE();
			return box;
		};

		function paintActive(box) {
			box.innerHTML = '';
			var stored = keyList();
			if (!stored.length) {
				box.appendChild(E('em', { 'style': 'opacity:.6' },
					_('Ключи добавляются выше или загружаются из подписки.')));
				return;
			}
			var cur = uci.get('byway', 'main', 'node_url') || '';
			stored.forEach(function (k, i) {
				var id = 'bwsel' + i;
				var radio = E('input', {
					'type': 'radio', 'name': 'bwsel', 'id': id,
					'style': 'margin-right:.5em',
					'checked': (k === cur) ? 'checked' : null
				});
				radio.addEventListener('change', function () {
					uci.set('byway', 'main', 'node_url', k);
					uci.changed();
				});
				box.appendChild(E('div', { 'style': 'padding:.25em 0' }, [
					radio,
					E('label', { 'for': id, 'style': 'cursor:pointer' },
						[ keyLabel(k) ])
				]));
			});
		}

		/* Свой конфиг — способ подключиться к тому, чего byway не понимает
		   по ссылке. У podkop это называлось Outbound Config. */
		o = s.option(form.TextValue, 'outbound_json', _('Конфиг аутбаунда'),
			_('Кусок конфигурации Xray-core объектом: protocol, settings, при нужде streamSettings. Тег byway подставит сам.'));
		o.rows = 10;
		o.monospace = true;
		o.depends('conn_mode', 'outbound');
		o.remove = keepHidden;

		o = s.option(form.Value, 'conn_label', _('Название подключения'),
			_('Показывается в строке «Подключение» вверху страницы.'));
		o.placeholder = _('свой конфиг');
		o.depends('conn_mode', 'outbound');
		o.remove = keepHidden;

		o = s.option(form.ListValue, 'on_failure', _('Если VPN не поднялся'),
			_('Когда движок VPN на роутере не работает или перехват не лёг. Недоступный сервер при работающем движке сюда не относится: трафик и так уходит в движок и мимо VPN не идёт. «Пустить напрямую» — интернет работает, но то, что шло через VPN, идёт без него. «Не пускать» — это закрывается: в режиме «по спискам» — сайты из списков, в режиме «всё через VPN» — весь интернет. Доступ к роутеру остаётся.'));
		o.value('open', _('Пустить напрямую'));
		o.value('closed', _('Не пускать'));
		o.default = 'closed';
		o.rmempty = false;

		return m.render();
	}
});
