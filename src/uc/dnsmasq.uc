// dnsmasq и byway: каталог добавок экземпляра @dnsmasq[0] и файл, которым
// резолвер уводится на DNS-вход Xray (byway-dns.conf). UCI dnsmasq byway не
// трогает (с 0.4.0): «Сохранить» на странице DHCP в LuCI закрепляла во флеше
// прежнюю правку UCI, и при мёртвом движке дом оставался без DNS.

const DM_DNS = 'byway-dns.conf';
const DM_BLOCK = 'byway-block.conf';

// Имя секции первого экземпляра: его конфиг -- /var/etc/dnsmasq.conf.ИМЯ.
function dm_section() {
	let l = split(run([ 'uci', '-q', 'show', 'dhcp.@dnsmasq[0]' ]).out, '\n')[0] ?? '';
	let m = match(l, /^dhcp\.([^.=]+)=dnsmasq$/);
	return m ? m[1] : '';
}

// Каталог добавок из конфига экземпляра: в имени хеш секции
// (/tmp/dnsmasq.cfg01411c.d), на 22.03 -- /tmp/dnsmasq.d, человек мог задать
// свой (option confdir). Конфига экземпляра нет -- первый попавшийся.
// BW_CONFDIR -- подставной для стенда.
function dm_confdir() {
	let o = getenv('BW_CONFDIR');
	if (o != null) return o;
	let s = dm_section(), fl = [];
	if (s !== '' && fs.stat('/var/etc/dnsmasq.conf.' + s)) push(fl, 'dnsmasq.conf.' + s);
	else fl = sort(filter(fs.lsdir('/var/etc') ?? [], (f) => substr(f, 0, 13) == 'dnsmasq.conf.'));
	for (let f in fl)
		for (let l in split(fs.readfile('/var/etc/' + f) ?? '', '\n')) {
			if (substr(l, 0, 9) != 'conf-dir=') continue;
			let d = split(substr(l, 9), ',')[0];
			return (d !== '' && fs.stat(d)?.type == 'directory') ? d : '';
		}
	return '';
}

// Путь к файлу byway в каталоге добавок; каталога нет -- пусто.
function dm_file(name) {
	let d = dm_confdir();
	return d !== '' ? d + '/' + name : '';
}

// Серверы из файла byway (server=…) по порядку; файла нет -- пусто.
function dm_servers() {
	let f = dm_file(DM_DNS), r = [];
	if (f === '') return r;
	for (let l in split(fs.readfile(f) ?? '', '\n'))
		if (substr(l, 0, 7) == 'server=') push(r, substr(l, 7));
	return r;
}

// Свои апстримы человека в UCI (не доменные записи server=/дом/адрес и не
// адрес byway): файлом их не отключить, и dnsmasq шлёт им часть запросов --
// домены списка получают настоящий адрес через раз.
function dm_foreign(own) {
	let r = [];
	for (let s in split(rtrim(run([ 'uci', '-q', 'get', 'dhcp.@dnsmasq[0].server' ]).out, '\n'), /[ \t\n]+/))
		if (s !== '' && substr(s, 0, 1) != '/' && s != own) push(r, s);
	return r;
}
