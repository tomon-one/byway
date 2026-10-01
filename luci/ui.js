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
		var pre = E('pre', {
			'style': 'white-space:pre-wrap;font-size:90%;margin:0'
		}, [ text || '' ]);
		var box = E('div', {
			'class': 'byway-out', 'style': 'max-width:100%'
		}, pre);
		if (!text) box.style.display = 'none';
		return box;
	},

	/* То же, но для вывода с колонками: перенос выключен, вместо него
	   прокрутка. На телефоне таблица «чем пользуются» иначе переносилась по
	   пробелам, и колонки переставали быть колонками. */
	table: function (text) {
		var pre = E('pre', {
			'style': 'white-space:pre;font-size:90%;margin:0'
		}, [ text || '' ]);
		var box = E('div', {
			'class': 'byway-out', 'style': 'overflow-x:auto;max-width:100%'
		}, pre);
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
						self.say(box, (l.stdout || '').trim() || _('запуск…'));
						if (l.code === 3) setTimeout(poll, 3000);
						else done();
					}).catch(function () { setTimeout(poll, 3000); });
				})();
			});
		});
	},

	say: function (box, text) {
		box.firstChild.textContent = text || '';
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
