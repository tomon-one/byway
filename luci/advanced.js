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
   подробность журнала, шаг проверки ключей, язык, путь к движку, сторож.

   Всё, на что смотрят, переехало на «Обслуживание», сетевые адреса и порты
   -- на «Сеть». Раньше эта вкладка была вдвое длиннее остальных, потому что
   собирала три несвязанные вещи разом. */

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
						E('pre', { 'style': 'white-space:pre-wrap' },
							[ bwui.plain((r.stdout || '') + (r.stderr || '')) ])
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

		o = s.option(form.ListValue, 'log_level',
			_('Подробность журнала'),
			_('Подробные уровни имеет смысл включать на время разбирательства: журнал живёт в памяти и при большом трафике быстро вытесняет сам себя. Начиная с «каждого соединения» в него попадают ещё и адреса, к которым обращаются из сети.'));
		o.value('none', _('ничего'));
		o.value('error', _('только ошибки'));
		o.value('warning', _('ошибки и предупреждения'));
		o.value('info', _('каждое соединение'));
		o.value('debug', _('всё подряд'));
		o.default = 'warning';

		o = s.option(form.Value, 'probe_interval',
			_('Интервал проверки ключей'),
			_('Только для режима автовыбора: с каким шагом Xray-core проверяет задержку до каждого ключа. Чаще — быстрее заметит отвал, но больше лишнего трафика.'));
		o.placeholder = '3m';

		/* ── Внутреннее ── */
		/* Язык один на панель и на консоль: byway.main.lang читают обе. */
		o = s.option(form.ListValue, 'lang', _('Язык'),
			_('Язык панели и вывода команды byway в консоли. Английский словарь byway скачивает с GitHub при переключении.'));
		o.value('ru', 'Русский');
		o.value('en', 'English');
		o.default = 'ru';

		o = s.option(form.Value, 'xray_bin', _('Путь к ядру Xray'),
			_('Путь вписывает byway engine при замене ядра. Пусто — ядро из пакета.'));
		o.placeholder = '/usr/bin/xray';

		o = s.option(form.Flag, 'guard', _('Восстановление перехвата'),
			_('Раз в пять минут byway проверяет, на месте ли его правила в файрволе, и возвращает их, если их сняли (чужой скрипт, обновление firewall4, другая служба). Снятые вручную командой byway plumb off не возвращаются до перезагрузки.'));
		o.default = '1';
		o.rmempty = false;

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
