'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require byway.lang as lang';
'require byway.ui as bwui';

/* Заголовок вкладки: «имя роутера | byway». LuCI ставит «имя — Раздел»,
   и при нескольких открытых вкладках их не различить. Имя запоминаем при
   первом заходе: повторный render иначе съел бы его. */
/* Короткое имя для перевода. Строки в коде остаются русскими и служат
   ключом словаря: пропущенный перевод выводится по-русски. */
var _ = function (s) { return lang.tr(s); };

var HOSTNAME = null;
function setTitle() {
	if (HOSTNAME === null)
		HOSTNAME = (document.title.split(/\s[-|—]\s/)[0] || '').trim();
	document.title = (HOSTNAME ? HOSTNAME + ' | ' : '') + 'byway';
	lang.tabs();
}


/* Дополнительное. То, что меняют раз в жизни или не меняют вовсе:
   подробность журнала, шаг проверки ключей, язык, путь к движку, сторож, а
   на своей подвкладке -- адреса и порты внутренней кухни.

   Всё, на что смотрят, -- на «Обслуживании». */

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('byway'),
		]);
	},

	render: function (data) {
		setTitle();
		/* Итог сохранения -- после перезагрузки LuCI (bwui.markApplied). Язык
		   сменили -- byway lang докачивает словарь (установщик кладёт только
		   выбранный) и страница перечитывается ещё раз под новый словарь;
		   прежде загрузку обрывала перезагрузка LuCI после применения. */
		var applied = bwui.takeApplied();
		if (applied && applied.lang)
			fs.exec(bwui.BYWAY, [ 'lang', applied.lang ]).then(function (r) {
				if (r.code !== 0)
					ui.addNotification(null, [
						E('p', {}, _('Словарь не установлен — язык остался прежним.')),
						bwui.pretty(bwui.plain((r.stdout || '') + (r.stderr || '')))
					], 'error');
				else
					location.reload();
			}).catch(function () {});
		else if (applied)
			bwui.genReport(_('Настройки не приняты — работают прежние.'));

		var m, s, o;

		m = new form.Map('byway', _('Дополнительное'),
			_('Значения по умолчанию подобраны и работают. Менять их стоит, только если понятна причина.'));

		s = m.section(form.NamedSection, 'main', 'byway');
		s.addremove = false;
		s.anonymous = true;

		/* Подвкладки: «Адреса и порты» вернулись с «Сети» (владелец
		   2026-10-18) -- при настройке они ничего не решают. */
		s.tab('main', _('Общее'));
		s.tab('ports', _('Адреса и порты'),
			_('Служебные значения. Менять — только если byway сталкивается с другой службой на роутере (podkop, passwall и подобные).'));

		o = s.taboption('main', form.ListValue, 'log_level',
			_('Подробность журнала'),
			_('Подробные уровни имеет смысл включать на время разбирательства: журнал живёт в памяти и при большом трафике быстро вытесняет сам себя. Начиная с «каждого соединения» в него попадают ещё и адреса, к которым обращаются из сети.'));
		o.value('none', _('ничего'));
		o.value('error', _('только ошибки'));
		o.value('warning', _('ошибки и предупреждения'));
		o.value('info', _('каждое соединение'));
		o.value('debug', _('всё подряд'));
		o.default = 'warning';

		o = s.taboption('main', form.Value, 'probe_interval',
			_('Интервал проверки ключей'),
			_('Только для режима автовыбора: с каким шагом Xray-core проверяет задержку до каждого ключа. Чаще — быстрее заметит отвал, но больше лишнего трафика.'));
		o.placeholder = '3m';

		/* ── Внутреннее ── */
		/* Язык один на панель и на консоль: byway.main.lang читают обе. */
		o = s.taboption('main', form.ListValue, 'lang', _('Язык'),
			_('Язык панели и вывода команды byway в консоли. Английский словарь byway скачивает с GitHub при переключении.'));
		o.value('ru', 'Русский');
		o.value('en', 'English');
		o.default = 'ru';

		o = s.taboption('main', form.Value, 'xray_bin', _('Путь к ядру Xray'),
			_('Путь вписывает byway core при замене ядра. Пусто — ядро из пакета.'));
		o.placeholder = '/usr/bin/xray';

		o = s.taboption('main', form.Value, 'xray_memlimit', _('Предел памяти ядра'),
			_('Мягкий предел для Xray-core: при нём ядро чаще убирает мусор, а не растёт, пока система его не убьёт. Пусто — 40 % памяти роутера; 0 — без предела; можно 96 (мегабайты) или 128MiB.'));
		o.placeholder = _('40 % памяти');
		/* Мерка -- как у byway set: байты, КиБ и меньше 16 МиБ дают сборку
		   мусора без остановки (прогон 5). */
		o.validate = function (id, v) {
			var m = /^(off|no|([0-9]{1,7})(MiB|GiB|TiB|MB|M|Mi|GB|G|Gi)?)$/.exec(v || '');
			if (v === '' || v == null) return true;
			if (!m || (m[2] && /^(MiB|MB|M|Mi)?$/.test(m[3] || '') && +m[2] > 0 && +m[2] < 16))
				return _('Число мегабайт (от 16), 128MiB, 1GiB, 0 или off.');
			return true;
		};

		o = s.taboption('main', form.Flag, 'xray_root', _('Ядро от root'),
			_('Небезопасно: ядро получает все права на роутере. По умолчанию оно работает от отдельного пользователя byway с двумя узкими правами. Включать — только если без этого не работает.'));
		o.default = '0';

		o = s.taboption('main', form.Flag, 'allow_insecure', _('Разрешить незащищённые ключи'),
			_('Небезопасно: соединение с сервером можно подменить. Нужно только для своего сервера с самоподписанным сертификатом на старом ядре (ниже 26.3.27) и для ключей vless и trojan без TLS к публичному адресу на ядре ниже 26.7.11. Новое ядро проверку сертификата отключить не даёт — там поможет отпечаток (pinSHA256) в ключе.'));
		o.default = '0';

		o = s.taboption('main', form.Flag, 'guard', _('Восстановление перехвата'),
			_('Раз в пять минут byway проверяет, на месте ли его правила в файрволе, и возвращает их, если их сняли (чужой скрипт, обновление firewall4, другая служба). Снятые вручную командой byway plumb off не возвращаются до перезагрузки.'));
		o.default = '1';
		o.rmempty = false;

		/* ── Адреса и порты ── */
		o = s.taboption('ports', form.Value, 'fakeip_pool',
			_('Пул подставных адресов'),
			_('byway даёт каждому сайту из списков адрес из этого диапазона, чтобы узнать его трафик. Такие адреса нигде в интернете не существуют и наружу не уходят.'));
		o.datatype = 'cidr4';
		o.placeholder = '198.18.0.0/15';

		o = s.taboption('ports', form.Value, 'dns_listen', _('Адрес резолвера byway'),
			_('Куда dnsmasq пересылает запросы. Отдельный адрес нужен, чтобы не столкнуться с самим dnsmasq на том же порту.'));
		o.placeholder = '127.0.0.42';
		/* Та же мерка, что у byway set: 127.0.0.1 и адреса сетей занимает
		   dnsmasq, движок не займёт порт, а резолвер уйдёт в петлю. */
		o.validate = function (id, v) {
			return (v === '' || (/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(v) && v !== '127.0.0.1')) ? true :
				_('Нужен адрес петли 127.x.x.x, кроме 127.0.0.1: его занимает dnsmasq');
		};

		o = s.taboption('ports', form.Value, 'tproxy_port', _('Порт перехвата'),
			_('Порт, на котором byway принимает трафик из списков. Менять — только при столкновении с другой службой.'));
		o.datatype = 'port';
		o.placeholder = '1602';

		o = s.taboption('ports', form.Value, 'local_proxy_port',
			_('Порт прокси byway'),
			_('Через этот порт byway скачивает списки и обновления по VPN. Менять — только при столкновении с другой службой.'));
		o.datatype = 'port';
		o.placeholder = '1603';

		o = s.taboption('ports', form.Value, 'fakeip6_pool', _('Пул подставных адресов IPv6'),
			_('То же, что пул выше, но для IPv6. Действует, только когда включён IPv6 на вкладке «Сеть».'));
		o.datatype = 'cidr6';
		o.placeholder = 'fc00::/18';

		o = s.taboption('ports', form.Value, 'self_mark', _('Метка соединений ядра'),
			_('Ей помечаются соединения самого Xray-core, чтобы VPN для программ на роутере не заворачивал их обратно в ядро. Должна отличаться битами от метки пакетов ниже.'));
		o.placeholder = '0x400000';

		o = s.taboption('ports', form.Value, 'mark', _('Метка пакетов'),
			_('Служебное значение, которым помечается перехваченный трафик. Менять только при столкновении с другой службой.'));
		o.placeholder = '0x100000';
		/* Та же мерка, что у byway set: ноль ловил бы весь трафик роутера. */
		o.validate = function (id, v) {
			return (v === '' || (/^0x[0-9a-fA-F]{1,8}$/.test(v) && parseInt(v, 16) !== 0)) ? true :
				_('Метка — шестнадцатеричное число вида 0x100000, не ноль');
		};

		return m.render();
	},

	handleSaveApply: function (ev) {
		var langBefore = uci.get('byway', 'main', 'lang') || 'ru';
		/* Метку ставит uci-applied через секунды, после подтверждения
		   применения, -- успеваем подписаться и после сохранения. */
		return this.super('handleSaveApply', [ ev ]).then(function () {
			var langNow = uci.get('byway', 'main', 'lang') || 'ru';
			bwui.markApplied(langNow !== langBefore ? { lang: langNow } : null);
		});
	}
});
