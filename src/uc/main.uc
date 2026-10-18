// Разбор команды. Сюда попадают только перенесённые на ucode команды: прочие
// разбирает shell (ui/main.sh) и зовёт bw_uc лишь для этих.

// Перевод сообщения init-скрипта: формат и доводы, как shell printf --
// формат приходит из командной строки с \n двумя знаками.
function cmd_xlat(fmt, ...args) {
	let s = _t(fmt ?? '');
	s = replace(replace(replace(s, '\\n', '\n'), '\\t', '\t'), '\\\\', '\\');
	print(_pf(s, args));
}

const CMDS = {
	version: function () { print('byway ', getenv('BW_VERSION'), '\n'); },
	xlat: cmd_xlat,
	parse: cmd_parse,
	check: cmd_check,
	probe: cmd_probe,
	show: cmd_show,
	status: cmd_status,
	health: cmd_health,
	rawok: cmd_rawok,
	stat: cmd_stat,
	top: cmd_top,
	gen: cmd_gen,
};

let _cmd = ARGV[0] ?? '';
if (CMDS[_cmd] == null)
	dief('byway: неизвестная команда «%s». Список: byway', _cmd);
CMDS[_cmd](...slice(ARGV, 1));
