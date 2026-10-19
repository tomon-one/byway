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
	version: function () { print('byway ', getenv('BW_VERSION'), '\n', _t('Собрано задолго до рассвета'), '\n'); },
	xlat: cmd_xlat,
	parse: cmd_parse,
	check: cmd_check,
	probe: cmd_probe,
	show: cmd_show,
	status: cmd_status,
	health: cmd_health,
	stat: cmd_stat,
	top: cmd_top,
	// --fix: сперва починить, что чинится само (uc/cli.uc), потом проверка.
	doctor: function (a) { if (a == '--fix') cmd_fix(); cmd_doctor(); },
	report: cmd_report,
	presets: cmd_presets,
	sub: cmd_sub,
	export: cmd_export,
	import: cmd_import,
	clear: cmd_clear,
	gen: cmd_gen,
	merged: cmd_merged,
	plumb: cmd_plumb,
	nft: cmd_nft,
	nftsig: cmd_nftsig,
	nftblock: cmd_nftblock,
	selfmark: cmd_selfmark,
	watch: cmd_watch,
	lang: cmd_lang,
	update: cmd_update,
	engine: cmd_engine,
	'engine-ram': cmd_engine_ram,
	menu: cmd_menu,
	pulse: cmd_pulse,
	home: cmd_home,
	help: cmd_help,
	hfmt: cmd_hfmt,
	key: cmd_key2,
	keys: cmd_keys,
	set: cmd_set,
	list: cmd_list,
	mode: cmd_mode,
	unknown: cmd_unknown,
	onoff: function (on) { cmd_onoff(on == '1'); },
	add: cmd_add,
	del: cmd_del,
};

let _cmd = ARGV[0] ?? '';
if (CMDS[_cmd] == null) cmd_unknown(_cmd);
CMDS[_cmd](...slice(ARGV, 1));
