# Вывод и журнал: say/warn/die и их формы с подстановками (f), logt/logf
# в syslog. Строка печатается через перевод (_t).

_say()  { printf '\033[1;32m[*]\033[0m %s\n' "$1"; }

_warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }

die_raw() { printf '\033[1;31m[x]\033[0m %s\n' "$1"; exit 1; }

# Вторые (sayf, warnf, dief) переводят ФОРМАТ, а не готовый текст:
# подставленное значение в словаре не найдётся, и строка осталась бы русской.
say()   { _say  "$(_t "$1")"; }

warn()  { _warn "$(_t "$1")"; }

die()   { die_raw "$(_t "$1")"; }

sayf()  { _fmt=$(_t "$1"); shift; _say    "$(printf "$_fmt" "$@")"; }

warnf() { _fmt=$(_t "$1"); shift; _warn   "$(printf "$_fmt" "$@")"; }

dief()  { _fmt=$(_t "$1"); shift; die_raw "$(printf "$_fmt" "$@")"; }

# Журнал системы читает тот же человек, что и экран; обёртки не дают забыть
# перевод строк logger.
logt()  { logger -t byway "$(_t "$1")"; }

logf()  { _lfm=$(_t "$1"); shift; logger -t byway "$(printf "$_lfm" "$@")"; }
