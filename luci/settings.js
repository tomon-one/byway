'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require byway.lang as lang';
'require network';
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


/* Настройки. Только то, что помогает, когда что-то не работает прямо
   сейчас: через какие сети пускать VPN, объединять ли соединения, каким
   резолвером пользоваться. Адреса и порты внутренней кухни -- на
   «Дополнительном» (владелец 2026-10-18).

   Разбор ключей и подписки отсюда УБРАН и переехал в «Основное»: держать
   ключ на одной вкладке, а его разбор на другой — ровно та путаница, из-за
   которой владелец решил, что подписку надо вставлять в поле ключа. */

var BYWAY = '/usr/local/bin/byway';


return view.extend({
	load: function () {
		return Promise.all([
			uci.load('byway'),
			network.getDevices().catch(function () { return []; }),
			/* Нужен ровно ради одной строки: какой транспорт работает сейчас.
			   Без неё поле Mux показывает «8» и при XHTTP, где mux выключен
			   самим byway, -- цифра стоит, а смысла за ней нет. */
			fs.exec(BYWAY, [ 'status', '--short' ]).catch(function () { return {}; })
		]);
	},

	render: function (data) {
		setTitle();
		bwui.afterApply(_('Настройки не приняты — работают прежние.'));

		var devices = (data[1] || []).map(function (d) {
			return d.getName ? d.getName() : String(d);
		}).filter(function (n) {
			/* Показываем мосты и физические сети, прячем служебное:
			   выбирать из тридцати имён вроде ifb0 человеку незачем. */
			return /^(br-|eth|wlan|lan|wan)/.test(n) && !/^wan/.test(n);
		}).sort();

		var m, s, o;

		m = new form.Map('byway', _('Сеть'));

		s = m.section(form.NamedSection, 'main', 'byway');
		s.addremove = false;
		s.anonymous = true;

		/* ── Куда пускать ── */
		/* В список обязательно попадает то, что УЖЕ выбрано, даже если netifd
		   о нём сейчас не рассказал: иначе галочка гостевой сети просто не
		   нарисуется, и первое же сохранение отключит ей туннель. */
		var chosen = uci.get('byway', 'main', 'interface') || [];
		if (typeof chosen === 'string') chosen = chosen.split(/\s+/);
		chosen.forEach(function (n) {
			if (n && devices.indexOf(n) < 0) devices.push(n);
		});
		if (!devices.length) devices = [ 'br-lan' ];
		devices.sort();

		o = s.option(form.DynamicList, 'interface', _('Интерфейсы'),
			_('Какие сети роутера пользуются VPN. Обычно одна — br-lan (домашняя); гостевая и другие появятся в списке, если заведены.'));
		devices.forEach(function (d) { o.value(d, d); });

		/* ── Соединения ── */
		/* Транспорт берём из состояния, а не из ссылки: ссылку разбирает
		   byway, и повторять его разбор в панели значит однажды разойтись с
		   ним в мелочи. */
		var st = ((data[2] || {}).stdout || '');
		var mt = st.match(/(?:транспорт|transport)\s+(\S+)/);
		var tnow = mt ? mt[1] : '';
		/* ⚠️ Судим по ФАКТУ, а не по имени транспорта. byway дописывает
		   «, mux=N» в строку статуса только когда mux действительно собран,
		   значит его отсутствие при непустой настройке и есть ответ. Прежде
		   список имён ловил xhttp и grpc, а `vision` искался в статусе, где
		   его нет вовсе: у ключа с flow=xtls-rprx-vision предупреждение не
		   показывалось. Найдено третьим аудитом 2026-09-07. */
		var muxOff = !!tnow && !/mux=/.test(st);

		o = s.option(form.Value, 'mux_concurrency', 'Mux',
			_('Сколько потоков в одно соединение. 0 — выключено, разумно 4–8. Помогает WebSocket и HTTPUpgrade, где каждое соединение обходится дорого. XHTTP, gRPC, Hysteria2 и xtls-rprx-vision мультиплексируют сами — им второй слой мешает, и byway отключает mux; у WireGuard потока нет вовсе.'));
		o.datatype = 'uinteger';
		o.placeholder = '8';
		/* Говорим прямо в поле, а не только в подсказке. Подсказку сворачивают
		   и не читают, а цифра «8» рядом с XHTTP выглядит как работающая
		   настройка -- владелец на это и указал. */
		if (muxOff && tnow === 'wireguard')
			o.description = '⚠ ' + _('Сейчас не действует: у WireGuard потока нет, мультиплексировать нечего. ') +
				o.description;
		else if (muxOff)
			o.description = '⚠ ' + _('Сейчас не действует: у транспорта ') +
				tnow + _(' своё мультиплексирование, byway отключает mux сам. ') +
				o.description;

		/* ── DNS ── */
		o = s.option(form.Value, 'dns_upstream', _('DNS-сервер'),
			_('Шифрованный DoH: обычные запросы провайдер подменяет. Свой лучше вписывать адресом; именем — только вместе с полем «DNS для имени DoH-сервера».'));
		/* Готовые адреса известных DoH-серверов, как в podkop. Поле остаётся
		   вводимым: список -- это подсказка, а не ограничение.

		   Все записаны АДРЕСОМ. Имя вроде dns.google сюда вписать нельзя не
		   из вкусовщины: byway резолвит через этот же сервер, и имя самого
		   сервера было бы негде разрешить -- получился бы замкнутый круг. */
		o.value('https://8.8.8.8/dns-query',        'Google — 8.8.8.8');
		o.value('https://8.8.4.4/dns-query',        _('Google, запасной — 8.8.4.4'));
		o.value('https://1.1.1.1/dns-query',        'Cloudflare — 1.1.1.1');
		o.value('https://1.0.0.1/dns-query',        _('Cloudflare, запасной — 1.0.0.1'));
		o.value('https://9.9.9.9/dns-query',        _('Quad9, режет вредоносные — 9.9.9.9'));
		o.value('https://149.112.112.112/dns-query',_('Quad9, запасной — 149.112.112.112'));
		o.value('https://94.140.14.14/dns-query',   _('AdGuard, режет рекламу — 94.140.14.14'));
		o.value('https://94.140.14.140/dns-query',  _('AdGuard без фильтров — 94.140.14.140'));
		o.value('https://208.67.222.222/dns-query', 'OpenDNS — 208.67.222.222');
		o.placeholder = 'https://8.8.8.8/dns-query';

		o = s.option(form.Value, 'dns_upstream2', _('Запасной DNS-сервер'),
			_('Спрашивается, когда первый молчит. Берите ДРУГОГО оператора: у одного оператора оба адреса лежат в одной сети и падают вместе. Отключить — «без запасного» в списке.'));
		o.value('https://1.1.1.1/dns-query',        'Cloudflare — 1.1.1.1');
		o.value('https://9.9.9.9/dns-query',        _('Quad9, режет вредоносные — 9.9.9.9'));
		o.value('https://8.8.8.8/dns-query',        'Google — 8.8.8.8');
		o.value('https://94.140.14.14/dns-query',   _('AdGuard, режет рекламу — 94.140.14.14'));
		o.value('https://208.67.222.222/dns-query', 'OpenDNS — 208.67.222.222');
		o.value('none',                             _('без запасного'));
		o.placeholder = 'https://1.1.1.1/dns-query';

		o = s.option(form.Value, 'dns_bootstrap', _('DNS для имени DoH-сервера'),
			_('Нужен, только если DNS-сервер выше вписан именем (например dns.nextdns.io): у этого адреса спрашивается только имя DoH-сервера. При адресах — пусто.'));
		o.value('77.88.8.8',  _('Яндекс — 77.88.8.8'));
		o.value('8.8.8.8',    'Google — 8.8.8.8');
		o.value('1.1.1.1',    'Cloudflare — 1.1.1.1');
		o.datatype = 'or(ipaddr,string)';

		o = s.option(form.ListValue, 'dns_route', _('Путь к DNS-серверу'),
			_('Напрямую — быстрее, резолв не зависит от VPN. Через VPN — провайдер не видит и самих запросов. Домены из списка это не затрагивает: на них отвечают локально.'));
		o.value('direct', _('Напрямую'));
		o.value('tunnel', _('Через VPN'));
		o.default = 'direct';
		o.rmempty = false;


		o = s.option(form.Flag, 'block_quic',
			_('Отказ QUIC для сайтов через VPN'),
			_('С ключами поверх TCP (vless, trojan, vmess) протокол QUIC внутри VPN зависает: приложение ждёт десятки секунд, прежде чем перейти на обычное соединение. С отказом сайт сразу открывается по TCP. С ключами hysteria2 и wireguard VPN сам идёт по UDP — там отказ не нужен.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'router_via_vpn',
			_('VPN для программ на роутере'),
			_('Без неё программы на самом роутере (обновление zapret, свои скрипты) не достают до сайтов и подсетей из списка и виснут до таймаута. Домашних устройств не касается; обновлениям byway не нужна.'));
		o.default = '1';
		o.rmempty = false;

		return m.render();
	},

	handleSaveApply: function (ev) {
		/* Что перезапускать -- решает procd: он видит uci commit byway и
		   зовёт reload, а тот сверяет собранный конфиг с прежним и трогает
		   службу только при отличии. Итог сборки -- после перезагрузки
		   страницы (bwui.markApplied). */
		bwui.markApplied();
		return this.super('handleSaveApply', [ ev ]);
	}
});
