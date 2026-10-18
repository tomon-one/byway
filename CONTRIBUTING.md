# Как помочь

*[English below](#contributing)*

## Отчёты — самое полезное

- **Что-то не работает** — [issue «Ошибка»](https://github.com/tomon-one/byway/issues/new?template=bug.yml).
  Приложите вывод `byway report`: в нём состояние и диагностика, ключа от VPN
  там нет.
- **Запустили на своём роутере** — [отчёт о совместимости](https://github.com/tomon-one/byway/issues/new?template=compatibility.yml),
  и удачный, и неудачный. byway проверен целиком на одной модели, так что
  каждый такой отчёт ценен.
- **Уязвимость** — не в issue, а закрыто: см. [SECURITY.md](SECURITY.md).

## Правки кода

**Сначала issue, потом pull request.** Опишите, что хотите поменять и зачем:
может оказаться, что так уже пробовали или что это решается иначе. Опечатки
и правки текста можно присылать сразу pull request'ом.

Что нужно знать о коде:

- **Две части в одном файле.** Обёртка — POSIX sh под busybox ash (замки, ловушки сигналов, пути), без bash-измов: `[[ ]]`, массивы, `echo -e` не годятся; проверка — `sh -n`. Остальное — ucode в `src/uc/`, файл на тему (`keys.uc` — разбор ключей, `gen.uc` — конфиг Xray, `plumb.uc` — перехват, `watch.uc` — сторож и т. д.). Только модули `fs` и `uci`: на OpenWrt 22.03 других нет. Функции — верхнего уровня: вложенная функция, трогающая локальные переменные объемлющей, на ucode 22.03 и 23.05 роняет программу. Функция видит только то, что объявлено выше неё в порядке `src/uc/ORDER`, и ошибка всплывает лишь при вызове.
- **Код — в `src/`**: shell — каталог на область (`core`, `config`, `lists`, `plumb`, `service`, `diag`, `update`, `data`, `ui`), ucode — `src/uc/`. Файл `byway` собирается командой `sh src/build.sh` в порядке `src/ORDER` и `src/uc/ORDER` — правьте `src/`, а не `byway`, и коммитьте оба.
- **Всё, что видит человек, переводится.** Русская строка в коде — ключ,
  английский перевод лежит отдельно:
  - `byway` — в `lang/en.tsv`: русская строка целиком, табуляция, перевод;
    строки печатаются через `_t` / `_f`;
  - `install.sh` и `uninstall.sh` — во встроенном словаре, функция `t()`;
  - панель — строки `_('…')` в `luci/*.js`, перевод в `luci/lang.js`.

  Меняете текст — меняйте ключ в словаре тем же движением, иначе английский
  пользователь увидит русскую строку.
- **Как пишется текст.** Без «я/мы» от лица программы («загрузка», а не
  «качаю»); подписи настроек — существительными; без жаргона; ответ на
  вопрос команды — первой строкой.
- **Проверка на OpenWrt.** В pull request напишите, где проверяли: модель и
  версию OpenWrt либо виртуальную машину. Правки файрвола, DNS и маршрутов —
  только с проверкой на живой системе: ошибка там оставляет дом без
  интернета.
- **Поведение изменилось** — поправьте README, оба языка.

Код распространяется под [GPL-2.0](LICENSE); присланные правки — под ней же.
Общение в issue и pull request'ах — по [кодексу поведения](CODE_OF_CONDUCT.ru.md).

---

# Contributing

## Reports are the most useful thing

- **Something does not work** — a [bug issue](https://github.com/tomon-one/byway/issues/new?template=bug.yml).
  Attach the output of `byway report`: it has the state and diagnostics, and no
  VPN key.
- **You ran it on your router** — a [compatibility report](https://github.com/tomon-one/byway/issues/new?template=compatibility.yml),
  successful or not. byway is fully verified on one model only, so every such
  report counts.
- **A vulnerability** — not in an issue, privately: see [SECURITY.md](SECURITY.md).

## Code changes

**An issue first, then a pull request.** Describe what you want to change and
why: it may turn out to have been tried already, or to be solvable another
way. Typos and text fixes can go straight to a pull request.

What to know about the code:

- **Two parts in one file.** The wrapper is POSIX sh under busybox ash
  (locks, signal traps, paths), no bashisms: `[[ ]]`, arrays, `echo -e` will
  not do; check with `sh -n`. The rest is ucode in `src/uc/`, a file per topic
  (`keys.uc` — key parsing, `gen.uc` — the Xray config, `plumb.uc` —
  interception, `watch.uc` — the watchdog, and so on). Only the `fs` and `uci`
  modules: OpenWrt 22.03 has no others. Functions stay at the top level: a
  nested function that touches the enclosing function's locals crashes the
  program on ucode from 22.03 and 23.05. A function sees only what is declared
  above it in the order of `src/uc/ORDER`, and the error shows up only when
  the call runs.
- **The code lives in `src/`**: shell — a directory per area (`core`,
  `config`, `lists`, `plumb`, `service`, `diag`, `update`, `data`, `ui`),
  ucode — `src/uc/`. `byway` is built with `sh src/build.sh` in the order of
  `src/ORDER` and `src/uc/ORDER` — edit `src/`, not `byway`, and commit both.
- **Everything a person sees is translated.** The Russian string in the code is
  the key, the English translation lives separately:
  - `byway` — in `lang/en.tsv`: the whole Russian string, a tab, the
    translation; strings are printed through `_t` / `_f`;
  - `install.sh` and `uninstall.sh` — in a built-in dictionary, the `t()`
    function;
  - the web UI — `_('…')` strings in `luci/*.js`, translations in
    `luci/lang.js`.

  If you change a text, change its dictionary key in the same edit, otherwise
  an English user sees the Russian string.
- **How the text is written.** No "I/we" on the program's behalf; setting
  labels are nouns; no jargon; a command's answer to its question comes first.
- **Tested on OpenWrt.** In the pull request, say where you tested: the model
  and OpenWrt version, or a virtual machine. Changes to the firewall, DNS and
  routes need a test on a live system: a mistake there leaves the house
  without internet.
- **Behaviour changed** — update the README, both languages.

The code is licensed under [GPL-2.0](LICENSE); contributions are accepted
under the same license.
Issues and pull requests follow the [Code of Conduct](CODE_OF_CONDUCT.md).
