// Разбор ключа (vless, vmess, trojan, ss, socks, hysteria2, wireguard).
// Логика -- прежний keys/parse.uc без правок разбора: на выходе команды sh
// (bw_uc parse, по ним сверяет scripts/parse-check.sh) и, для сборки, сам ключ
// объектом (N) с сообщениями (msgs, fatal). Выход из середины -- исключением
// PARSE_STOP: die каркаса завершает программу.
//
// ⚠️ Помощники -- функции верхнего уровня, состояние -- глобальное (PK_*), без
// вложенных функций: ucode до 2024-11-29 (22.03, 23.05) хранил захваченную
// вложенной функцией переменную объемлющей функции в массиве или объекте
// ссылкой на кадр стека -- после выхода из функции программа падала при
// уборке памяти (стенды 2026-10-16; исправлено в ucode «resolve upvalue
// values in arrays and objects»).
const PARSE_STOP = '__byway_parse_stop__';
let PK_OUT = [], PK_R = null, PK_N = null, PK_QUERY = '', PK_PREV_SNI = '', PK_PREV_WSHOST = '';

// Функции верхнего уровня видят только объявленное выше: pk_q и pk_put первыми.
function pk_q(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }
function pk_put(n, v) { push(PK_OUT, n + '=' + pk_q(v)); }
function pk_stop() { raise(PARSE_STOP); }
function pk_warn(m) { push(PK_OUT, 'warn ' + pk_q(m)); push(PK_R.msgs, [ m ]); }
function pk_warnf(m, a) { push(PK_OUT, 'warnf ' + pk_q(m) + ' ' + pk_q(a)); push(PK_R.msgs, [ m, a ]); }
function pk_die(m) { push(PK_OUT, 'die ' + pk_q(m)); PK_R.fatal = [ m ]; pk_stop(); }
function pk_dief(m, a) { push(PK_OUT, 'dief ' + pk_q(m) + ' ' + pk_q(a)); PK_R.fatal = [ m, a ]; pk_stop(); }
// vmess: поле JSON строкой (была стрелка внутри ветки -- захват локального).
function pk_jf(o, k) { return (o[k] == null) ? '' : '' + o[k]; }

function pk_nl(s) { return rtrim(s, '\n'); }

function pk_pctd(s) {
    return pk_nl(replace(s, /%([0-9a-fA-F]{1,2})?/g,
        (m, h) => h ? (hex(h) ? chr(hex(h)) : '') : '\\x'));
}

function pk_b64d(s) {
    s = replace(replace(replace(s, /[\r\n]/g, ''), '_', '/'), '-', '+');
    if (length(s) % 4 == 2) s += '==';
    else if (length(s) % 4 == 3) s += '=';
    let r = b64dec(s);
    return r == null ? '' : pk_nl(replace(r, '\0', ''));
}

function pk_before(s, c) { let i = index(s, c); return i < 0 ? s : substr(s, 0, i); }

function pk_after(s, c) { let i = index(s, c); return i < 0 ? s : substr(s, i + length(c)); }

function pk_lastafter(s, c) { let i = rindex(s, c); return i < 0 ? s : substr(s, i + length(c)); }

function pk_grepq(re, s) {
    if (s == '') return false;
    for (let l in split(s, '\n')) if (match(l, re)) return true;
    return false;
}

function pk_jstr(s) {
    return '"' + replace(s, /[\\"\x01-\x1f]/g,
        (c) => (c == '\\' || c == '"') ? '\\' + c : sprintf('\\u%04x', ord(c))) + '"';
}

function pk_flush() {
    for (let k in PK_N) pk_put('N_' + k, PK_N[k]);
    for (let k in [ 'PASS', 'USER', 'OBFSPW' ]) pk_put('J_' + k, pk_jstr(PK_N[k] ?? ''));
}

function pk_node_json_ok() {
    for (let p in [ ['адрес', PK_N.HOST], ['id', PK_N.UUID], ['пароль', PK_N.PASS],
                    ['user', PK_N.USER], ['method', PK_N.METHOD], ['type', PK_N.TYPE],
                    ['security', PK_N.SEC], ['sni', PK_N.SNI ?? PK_PREV_SNI], ['fp', PK_N.FP],
                    ['path', PK_N.PATH], ['host', PK_N.WSHOST ?? PK_PREV_WSHOST], ['pbk', PK_N.PBK],
                    ['sid', PK_N.SID], ['flow', PK_N.FLOW], ['mode', PK_N.MODE],
                    ['alpn', PK_N.ALPN], ['headerType', PK_N.HDR], ['seed', PK_N.SEED],
                    ['serviceName', PK_N.SVC], ['authority', PK_N.AUTH], ['spx', PK_N.SPX],
                    ['pqv', PK_N.PQV], ['quicSecurity', PK_N.QSEC], ['key', PK_N.QKEY],
                    ['encryption', PK_N.ENC], ['obfs-password', PK_N.OBFSPW],
                    ['pcs', PK_N.PIN], ['vcn', PK_N.VCN], ['obfs', PK_N.OBFS],
                    ['privatekey', PK_N.WGKEY], ['publickey', PK_N.WGPUB],
                    ['presharedkey', PK_N.WGPSK], ['address', PK_N.WGADDR],
                    ['mtu', PK_N.WGMTU], ['reserved', PK_N.WGRES], ['keepalive', PK_N.WGKA] ]) {
        if (match(p[1], /[\x01-\x1f\x7f]/)) {
            pk_flush();
            pk_dief("в поле «%s» ссылки управляющий знак (перевод строки, табуляция): такая ссылка подменяет поля конфига", p[0]);
        }
        if (p[0] in [ 'пароль', 'user', 'obfs-password' ]) continue;
        if (index(p[1], '"') >= 0 || index(p[1], '\\') >= 0) {
            pk_flush();
            pk_dief("в поле «%s» ссылки кавычка или обратная косая: значения уходят в конфиг как есть, и такая ссылка подменяет его поля", p[0]);
        }
    }
}

function pk_json_obj_ok(s) {
    let d = 0, instr = false, esc = false, started = false, closed = false;
    for (let c in split(s + '\n', '')) {
        if (instr) {
            if (esc) esc = false;
            else if (c == '\\') esc = true;
            else if (c == '"') instr = false;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
        if (!started) {
            if (c != '{') return false;
            started = true; d = 1; continue;
        }
        if (closed) return false;
        if (c == '"') { instr = true; continue; }
        if (c == '{' || c == '[') { d++; continue; }
        if (c == '}' || c == ']') {
            d--;
            if (d < 0) return false;
            if (d == 0) closed = true;
            continue;
        }
    }
    return !instr && started && closed && d == 0;
}

function pk_qraw(name) {
    for (let l in split(PK_QUERY, '&'))
        if (substr(l, 0, length(name) + 1) == name + '=')
            return substr(l, length(name) + 1);
    return null;
}

function pk_qp(name) { let v = pk_qraw(name); return v == null ? '' : pk_pctd(v); }

function pk_qpa(names) { for (let n in names) { let v = pk_qp(n); if (v != '') return v; } return ''; }

function pk_qp_json(name) {
    let v = pk_qraw(name);
    if (v == null) return '';
    for (let p in [ ['%2F', '/'], ['%3A', ':'], ['%2C', ','], ['%20', ' '], ['%3D', '='],
                    ['%26', '&'], ['%7B', '{'], ['%7D', '}'], ['%22', '"'], ['%5B', '['],
                    ['%5D', ']'] ])
        v = replace(v, p[0], p[1]);
    return pk_nl(v);
}

function parse_key(URL, prev_sni, prev_wshost) {
	PK_OUT = [];
	PK_R = { msgs: [], fatal: null, scheme: '', label: '' };
	PK_QUERY = '';
	PK_PREV_SNI = prev_sni ?? '';
	PK_PREV_WSHOST = prev_wshost ?? '';
	try {
		// Как `printf %b` над «%» -> «\x»: «%» без цифры остаётся «\x», NUL пропадает.
		// base64 и base64url без «=» (SIP002), как `base64 -d` после добивки.
		// grep -Eq: совпала хоть одна строка.

		PK_N = {
		    UUID: '', PASS: '', USER: '', METHOD: '', AID: '0',
		    TYPE: 'tcp', SEC: 'none', PATH: '/', FP: 'chrome',
		    PBK: '', SID: '', FLOW: '', MODE: '', ALPN: '',
		    HDR: '', SEED: '', SVC: '', AUTH: '', SPX: '', PQV: '',
		    ENC: '', QSEC: '', QKEY: '', EXTRA: '', INSEC: '',
		    OBFS: '', OBFSPW: '', PIN: '', VCN: '',
		    WGKEY: '', WGPUB: '', WGPSK: '', WGADDR: '', WGMTU: '', WGRES: '', WGKA: ''
		};
		// sni и host ss не задаёт: в sh остаются прежние, их и проверяем.
		// Строка JSON: пароль и логин уходят в конфиг строкой JSON, кавычка и
		// обратная косая в них законны и экранируются (J_*), а не запрещаются.

		// Поля, уходящие в конфиг строками. Пароли и логин экранирует jstr --
		// кавычка в них не отказ; управляющий знак -- отказ везде.

		// extra подставляется в конфиг объектом, мимо node_json_ok: ровно один
		// объект и ничего вокруг. `{} } }, "settings": {…}` закрыл бы
		// xhttpSettings и streamSettings и дописал свой settings (Xray берёт
		// последний из повторных ключей). Вид скобок не различаем -- ядро отвергнет.

		let scheme = pk_before(URL, '://');
		pk_put('N_SCHEME', scheme);
		PK_R.scheme = scheme;
		if (!(scheme in [ 'vless', 'trojan', 'socks', 'vmess', 'ss', 'hysteria2', 'hy2', 'wireguard', 'wg' ])) {
		    // В Xray-core нет исходящего tuic, а hysteria -- только вторая версия
		    // (сверено по исходникам 26.9.30).
		    if (scheme == 'hysteria' || scheme == 'tuic')
		        pk_dief("%s в Xray-core нет; из похожего есть hysteria2", scheme);
		    pk_dief("неизвестный вид ссылки: %s", scheme);
		}
		let rest = pk_after(URL, '://');
		// Метка после решётки -- имя, обычно с флагом; не секрет.
		// Без управляющих знаков: метка попадает в вывод терминала.
		PK_R.label = index(URL, '#') >= 0 ? replace(pk_pctd(pk_after(URL, '#')), /[\x01-\x1f\x7f]/g, '') : '';
		pk_put('N_LABEL', PK_R.label);
		rest = pk_before(rest, '#');

		// vmess://<base64 от JSON>: add, port, id, aid, net, type, host, path, tls,
		// sni, scy, alpn, fp.
		if (scheme == 'vmess') {
		    let j = pk_b64d(rest);
		    if (j == '') { pk_flush(); pk_die("vmess-ссылка не раскодировалась"); }
		    // Битый JSON бросает исключение: ucode выходил с трассой вместо отказа.
		    let o = null;
		    try { o = json(j); } catch (e) { o = null; }
		    if (type(o) != 'object') { pk_flush(); pk_die("vmess-ссылка не раскодировалась"); }
		    PK_N.HOST = pk_jf(o, 'add'); PK_N.PORT = pk_jf(o, 'port'); PK_N.UUID = pk_jf(o, 'id');
		    if (index(PK_N.HOST, ':') >= 0) { pk_flush(); pk_dief("адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя", PK_N.HOST); }
		    // aid уходит в конфиг без кавычек -- только число.
		    PK_N.AID = pk_jf(o, 'aid') || '0';
		    if (!match(PK_N.AID, /^[0-9]+$/)) { pk_flush(); pk_dief("aid у vmess — не число: %s", PK_N.AID); }
		    PK_N.TYPE = pk_jf(o, 'net') || 'tcp';
		    PK_N.PATH = pk_jf(o, 'path') || '/';
		    PK_N.WSHOST = pk_jf(o, 'host');
		    // type=none клиенты пишут почти всегда; свежее ядро отвергает его как
		    // заголовок mkcp, поэтому «нет заголовка» -- пусто.
		    PK_N.HDR = pk_jf(o, 'type'); if (PK_N.HDR == 'none') PK_N.HDR = '';
		    if (pk_jf(o, 'tls') == 'tls') PK_N.SEC = 'tls';
		    PK_N.SNI = pk_jf(o, 'sni') || PK_N.WSHOST || PK_N.HOST;
		    if (PK_N.WSHOST == '') PK_N.WSHOST = PK_N.HOST;
		    PK_N.METHOD = pk_jf(o, 'scy');
		    if (!(PK_N.METHOD in [ '', 'auto', 'aes-128-gcm', 'chacha20-poly1305', 'none', 'zero' ])) {
		        pk_flush();
		        pk_dief("scy=%s у vmess Xray-core не знает: есть auto, aes-128-gcm, chacha20-poly1305, none, zero", PK_N.METHOD);
		    }
		    PK_N.ALPN = pk_jf(o, 'alpn');
		    if (pk_jf(o, 'fp') != '') PK_N.FP = pk_jf(o, 'fp');
		    // У vmess имя сервиса gRPC лежит в path (v2rayN и др.); сырой path, не
		    // PK_N.PATH, где пустой заменён на «/».
		    if (PK_N.TYPE == 'grpc') PK_N.SVC = pk_jf(o, 'path');
		    PK_N.PROTO = 'vmess';
		    // Прочие поля JSON (allowInsecure и т. п.) не переносятся -- называем.
		    for (let k in keys(o))
		        if (!(k in [ 'v', 'ps', 'add', 'port', 'id', 'aid', 'scy', 'net', 'type', 'host',
		                     'path', 'tls', 'sni', 'alpn', 'fp' ]))
		            pk_warnf("параметр ссылки «%s» byway в конфиг не переносит — стоит проверить, важен ли он", k);
		    pk_node_json_ok();
		    pk_flush(); pk_stop();
		}

		// ss://<base64 метод:пароль>@host:port и ss://метод:пароль@host:port; в
		// старой форме в base64 вся ссылка.
		if (scheme == 'ss') {
		    if (index(rest, '@') < 0) {
		        rest = pk_b64d(pk_before(rest, '?'));
		        if (index(rest, '@') < 0) { pk_flush(); pk_die("ss-ссылка не разобралась"); }
		    }
		    // Делим по последней «@»: в открытом пароле она законна.
		    let ui = substr(rest, 0, rindex(rest, '@'));
		    let hp = pk_lastafter(rest, '@');
		    // Плагин (obfs-local, v2ray-plugin) Xray-core не запускает; прочие
		    // параметры не переносятся -- называем.
		    if (index(hp, 'plugin=') >= 0)
		        pk_warn("plugin у shadowsocks не переносится: Xray-core плагины не запускает, сервер с плагином не ответит");
		    if (index(hp, '?') >= 0)
		        for (let l in split(pk_after(hp, '?'), '&')) {
		            let pn = pk_before(l, '=');
		            if (pn != '' && pn != 'plugin')
		                pk_warnf("параметр ссылки «%s» byway в конфиг не переносит — стоит проверить, важен ли он", pn);
		        }
		    hp = pk_before(pk_before(hp, '?'), '/');
		    let plain = index(ui, ':') >= 0 ? pk_pctd(ui) : pk_b64d(ui);
		    if (substr(hp, 0, 1) == '[') { pk_flush(); pk_dief("адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя", hp); }
		    PK_N.METHOD = pk_before(plain, ':');
		    PK_N.PASS = pk_after(plain, ':');
		    PK_N.HOST = pk_before(hp, ':');
		    PK_N.PORT = pk_lastafter(hp, ':');
		    // Без порта взялся бы сам адрес: "port": example.com.
		    if (PK_N.PORT == PK_N.HOST) PK_N.PORT = '443';
		    PK_N.PROTO = 'shadowsocks';
		    pk_node_json_ok();
		    pk_flush(); pk_stop();
		}

		// Остальные схемы -- всё в адресе открытым текстом. Без «@» части до неё
		// нет: wg-ссылки Hiddify и hysteria2 без пароля несут всё в параметрах.
		let ui = index(rest, '@') >= 0 ? pk_before(rest, '@') : '';
		let rest2 = pk_after(rest, '@');
		// hysteria2 пишет «host:port/?sni=…» -- косая перед вопросом не порт.
		let hostport = pk_before(pk_before(rest2, '?'), '/');
		// IPv6 не поддержан: [2001:db8::1]:443 резался бы по первому двоеточию.
		if (substr(hostport, 0, 1) == '[') { pk_flush(); pk_dief("адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя", hostport); }
		PK_N.HOST = pk_before(hostport, ':');
		PK_N.PORT = pk_lastafter(hostport, ':');
		if (PK_N.PORT == PK_N.HOST) PK_N.PORT = '443';
		PK_QUERY = index(rest2, '?') >= 0 ? pk_after(rest2, '?') : '';

		if (scheme == 'vless') { PK_N.UUID = ui; PK_N.PROTO = 'vless'; }
		else if (scheme == 'trojan') { PK_N.PASS = pk_pctd(ui); PK_N.PROTO = 'trojan'; }
		else if (scheme == 'hysteria2' || scheme == 'hy2') { PK_N.PASS = pk_pctd(ui); PK_N.PROTO = 'hysteria'; }
		else if (scheme == 'wireguard' || scheme == 'wg') { PK_N.WGKEY = pk_pctd(ui); PK_N.PROTO = 'wireguard'; }
		else if (scheme == 'socks') {
		    let su = pk_pctd(ui);
		    // Часть клиентов кладёт «логин:пароль» в base64 (socks://dXNlcjpwYXNz@…).
		    if (su != '' && index(su, ':') < 0) {
		        let sd = pk_b64d(su);
		        if (index(sd, ':') >= 0) su = sd;
		    }
		    PK_N.USER = pk_before(su, ':'); PK_N.PASS = pk_after(su, ':');
		    if (PK_N.USER == su) { PK_N.USER = ''; PK_N.PASS = ''; }
		    PK_N.PROTO = 'socks';
		}

		// Раскодируем целиком: кавычку, косую и управляющие знаки отсекает
		// node_json_ok. Частичное раскодирование превращало путь v2rayN
		// `%2F%3Fed%3D2048` в `/%3Fed=2048`: Xray не находил ed, ответ 404.
		// Первый непустой из нескольких имён (v2rayN -- publickey, Hiddify -- peer_pk).
		// extra -- объект JSON: раскодируются только знаки, законные в нём; объект
		// проверяет json_obj_ok.

		let v = pk_qp('type'); if (v != '') PK_N.TYPE = v;
		// trojan без TLS не бывает, а клиенты security часто опускают.
		if (PK_N.PROTO == 'trojan') PK_N.SEC = 'tls';
		v = pk_qp('security'); if (v != '') PK_N.SEC = v;
		PK_N.SNI = pk_qp('sni') || PK_N.HOST;
		v = pk_qp('fp'); if (v != '') PK_N.FP = v;
		v = pk_qp('path'); if (v != '') PK_N.PATH = v;
		PK_N.WSHOST = pk_qp('host') || PK_N.HOST;
		PK_N.PBK = pk_qp('pbk'); PK_N.SID = pk_qp('sid'); PK_N.FLOW = pk_qp('flow');
		// flow у trojan в конфиг не пишется, а mux при нём отключался.
		if (PK_N.PROTO == 'trojan' && PK_N.FLOW != '') {
		    pk_warnf("flow=%s у trojan Xray-core не поддерживает — пропущен", PK_N.FLOW); PK_N.FLOW = '';
		}
		PK_N.MODE = pk_qp('mode'); PK_N.ALPN = pk_qp('alpn'); PK_N.HDR = pk_qp('headerType');
		PK_N.SEED = pk_qp('seed'); PK_N.SVC = pk_qp('serviceName'); PK_N.AUTH = pk_qp('authority');
		PK_N.SPX = pk_qp('spx'); PK_N.PQV = pk_qp('pqv'); PK_N.ENC = pk_qp('encryption');
		PK_N.QSEC = pk_qp('quicSecurity'); PK_N.QKEY = pk_qp('key'); PK_N.EXTRA = pk_qp_json('extra');
		PK_N.INSEC = pk_qp('allowInsecure') || pk_qp('insecure');
		// pcs -- имя у v2rayN, pinSHA256 -- у hysteria2; значение одно и то же.
		PK_N.PIN = pk_qp('pcs') || pk_qp('pinSHA256');
		PK_N.VCN = pk_qp('vcn');

		if (PK_N.PROTO == 'hysteria') {
		    // Транспорт hysteria всегда под TLS («tls config is nil» без него); у
		    // QUIC нет uTLS-отпечатка.
		    PK_N.TYPE = 'hysteria'; PK_N.SEC = 'tls'; PK_N.FP = '';
		    if (PK_N.ALPN == '') PK_N.ALPN = 'h3';
		    // Диапазон портов Xray-core через hysteriaSettings не берёт.
		    if (match(PK_N.PORT, /[,-]/)) {
		        let p1 = match(PK_N.PORT, /^[^,-]*/)[0];
		        pk_warnf("диапазон портов в ключе не переносится: соединение идёт на порт %s", p1);
		        PK_N.PORT = p1;
		    }
		    v = pk_qp('obfs');
		    if (v == 'salamander') {
		        PK_N.OBFS = 'salamander'; PK_N.OBFSPW = pk_qp('obfs-password');
		        if (PK_N.OBFSPW == '') { pk_flush(); pk_die("obfs=salamander без obfs-password: пароль обфускации обязателен"); }
		    }
		    else if (v != '' && v != 'none') {
		        pk_flush(); pk_dief("obfs=%s у hysteria2 не поддержан: в Xray-core есть только salamander", v);
		    }
		    if (pk_qp('mport') != '')
		        pk_warn("mport (смена портов) не переносится: соединение идёт на основной порт из ключа");
		}

		if (PK_N.PROTO == 'wireguard') {
		    PK_N.TYPE = 'wireguard'; PK_N.SEC = 'none';
		    if (PK_N.WGKEY == '') PK_N.WGKEY = pk_qpa([ 'privatekey', 'secretkey', 'pk' ]);
		    PK_N.WGPUB = pk_qpa([ 'publickey', 'peer_pk' ]);
		    PK_N.WGPSK = pk_qpa([ 'presharedkey', 'pre_shared_key', 'psk' ]);
		    PK_N.WGADDR = pk_nl(replace(pk_qpa([ 'address', 'local_address' ]), ' ', ''));
		    PK_N.WGMTU = pk_qp('mtu'); PK_N.WGRES = pk_nl(replace(pk_qp('reserved'), ' ', '')); PK_N.WGKA = pk_qp('keepalive');
		    // Ключи -- base64 на 32 байта либо hex (ParseWireGuardKey); образец
		    // строгий: значение уходит в конфиг.
		    let key = /^([A-Za-z0-9+\/]{43}=|[0-9a-fA-F]{64})$/;
		    if (!pk_grepq(key, PK_N.WGKEY)) { pk_flush(); pk_die("в ключе wireguard нет закрытого ключа либо он не той формы (base64 на 44 знака либо 64 шестнадцатеричных)"); }
		    if (!pk_grepq(key, PK_N.WGPUB)) { pk_flush(); pk_die("в ключе wireguard нет публичного ключа сервера (publickey) либо он не той формы"); }
		    if (PK_N.WGPSK != '' && !pk_grepq(key, PK_N.WGPSK)) { pk_flush(); pk_die("presharedkey в ключе wireguard не той формы"); }
		    // Без своего адреса в туннеле ядро ставит 10.0.0.1, сервер такого
		    // клиента не узнаёт, и соединение молча не идёт.
		    if (PK_N.WGADDR == '') { pk_flush(); pk_die("в ключе wireguard нет address -- адреса этого клиента в туннеле"); }
		    if (!pk_grepq(/^[0-9a-fA-F.:]+(\/[0-9]{1,3})?(,[0-9a-fA-F.:]+(\/[0-9]{1,3})?)*$/, PK_N.WGADDR)) {
		        pk_flush(); pk_dief("address в ключе wireguard не похож на список адресов: %s", PK_N.WGADDR);
		    }
		    if (PK_N.WGMTU != '' && !pk_grepq(/^[0-9]{3,4}$/, PK_N.WGMTU)) { pk_flush(); pk_dief("mtu в ключе wireguard -- не число: %s", PK_N.WGMTU); }
		    if (PK_N.WGRES != '' && !pk_grepq(/^[0-9]{1,3},[0-9]{1,3},[0-9]{1,3}$/, PK_N.WGRES)) {
		        pk_flush(); pk_dief("reserved в ключе wireguard -- не три числа через запятую: %s", PK_N.WGRES);
		    }
		    if (PK_N.WGKA != '' && !pk_grepq(/^[0-9]{1,5}$/, PK_N.WGKA)) { pk_flush(); pk_dief("keepalive в ключе wireguard -- не число: %s", PK_N.WGKA); }
		}
		if (PK_N.PIN != '' && !pk_grepq(/^[0-9a-fA-F:,]+$/, PK_N.PIN)) {
		    pk_flush(); pk_dief("отпечаток сертификата (pcs, pinSHA256) -- не шестнадцатеричный: %s", PK_N.PIN);
		}
		if (PK_N.VCN != '' && !pk_grepq(/^[A-Za-z0-9.,*-]+$/, PK_N.VCN)) {
		    pk_flush(); pk_dief("имя для проверки сертификата (vcn) -- не имя хоста: %s", PK_N.VCN);
		}
		pk_node_json_ok();
		if (PK_N.EXTRA != '' && !pk_json_obj_ok(PK_N.EXTRA)) {
		    pk_flush();
		    pk_die("параметр extra в ссылке -- не один объект JSON: он подставляется в конфиг как есть, и такая ссылка переписывает соседние поля, включая адрес сервера и защиту");
		}

		// Имена параметров В ССЫЛКЕ -- соглашение клиентов; незнакомые называем,
		// чтобы человек узнал, что из ссылки не перенесено.
		let known = [ 'type', 'security', 'sni', 'fp', 'alpn', 'path', 'host', 'headerType', 'seed',
		              'serviceName', 'mode', 'authority', 'pbk', 'sid', 'spx', 'pqv', 'flow',
		              'encryption', 'quicSecurity', 'key', 'extra', 'allowInsecure', 'insecure',
		              'pinSHA256', 'pcs', 'vcn' ];
		if (PK_N.PROTO == 'hysteria') push(known, 'obfs', 'obfs-password', 'mport');
		if (PK_N.PROTO == 'wireguard')
		    push(known, 'publickey', 'privatekey', 'secretkey', 'pk', 'peer_pk', 'presharedkey',
		         'pre_shared_key', 'psk', 'address', 'local_address', 'mtu', 'reserved', 'keepalive');
		for (let l in split(PK_QUERY, '&'))
		    for (let pn in split(pk_before(l, '='), /[ \t]+/))
		        if (pn != '' && !(pn in known))
		            pk_warnf("параметр ссылки «%s» byway в конфиг не переносит — стоит проверить, важен ли он", pn);

		// Шифрование VLESS: форма -- образцом, версию ядра -- ob_key (uc/outbound.uc).
		if (PK_N.ENC != '' && PK_N.ENC != 'none') {
		    if (PK_N.PROTO != 'vless') { pk_flush(); pk_dief("encryption=%s бывает только у vless", PK_N.ENC); }
		    if (!pk_grepq(/^mlkem768x25519plus\.[A-Za-z0-9._+\/=-]+$/, PK_N.ENC)) {
		        pk_flush(); pk_dief("encryption=%s не поддержан: Xray-core знает только mlkem768x25519plus", PK_N.ENC);
		    }
		}
		pk_flush(); pk_stop();
	} catch (e) {
		if (e.message !== PARSE_STOP) raise(e.message);
	}
	return { out: PK_OUT, msgs: PK_R.msgs, fatal: PK_R.fatal, N: PK_N, scheme: PK_R.scheme, label: PK_R.label };
}

function cmd_parse() {
	let r = parse_key(getenv('BW_URL') ?? '', getenv('BW_SNI') ?? '', getenv('BW_WSHOST') ?? '');
	print(join('\n', r.out), '\n');
}
