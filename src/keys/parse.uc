let out = [];
function q(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }
function put(n, v) { push(out, n + '=' + q(v)); }
function stop() { print(join('\n', out), '\n'); exit(0); }
function warn(m) { push(out, 'warn ' + q(m)); }
function warnf(m, a) { push(out, 'warnf ' + q(m) + ' ' + q(a)); }
function die(m) { push(out, 'die ' + q(m)); stop(); }
function dief(m, a) { push(out, 'dief ' + q(m) + ' ' + q(a)); stop(); }

function nl(s) { return rtrim(s, '\n'); }
// Как `printf %b` над «%» -> «\x»: «%» без цифры остаётся «\x», NUL пропадает.
function pctd(s) {
    return nl(replace(s, /%([0-9a-fA-F]{1,2})?/g,
        (m, h) => h ? (hex(h) ? chr(hex(h)) : '') : '\\x'));
}
// base64 и base64url без «=» (SIP002), как `base64 -d` после добивки.
function b64d(s) {
    s = replace(replace(replace(s, /[\r\n]/g, ''), '_', '/'), '-', '+');
    if (length(s) % 4 == 2) s += '==';
    else if (length(s) % 4 == 3) s += '=';
    let r = b64dec(s);
    return r == null ? '' : nl(replace(r, '\0', ''));
}
function before(s, c) { let i = index(s, c); return i < 0 ? s : substr(s, 0, i); }
function after(s, c) { let i = index(s, c); return i < 0 ? s : substr(s, i + length(c)); }
function lastafter(s, c) { let i = rindex(s, c); return i < 0 ? s : substr(s, i + length(c)); }
// grep -Eq: совпала хоть одна строка.
function grepq(re, s) {
    if (s == '') return false;
    for (let l in split(s, '\n')) if (match(l, re)) return true;
    return false;
}

let URL = getenv('BW_URL') ?? '';
let N = {
    UUID: '', PASS: '', USER: '', METHOD: '', AID: '0',
    TYPE: 'tcp', SEC: 'none', PATH: '/', FP: 'chrome',
    PBK: '', SID: '', FLOW: '', MODE: '', ALPN: '',
    HDR: '', SEED: '', SVC: '', AUTH: '', SPX: '', PQV: '',
    ENC: '', QSEC: '', QKEY: '', EXTRA: '', INSEC: '',
    OBFS: '', OBFSPW: '', PIN: '', VCN: '',
    WGKEY: '', WGPUB: '', WGPSK: '', WGADDR: '', WGMTU: '', WGRES: '', WGKA: ''
};
// sni и host ss не задаёт: в sh остаются прежние, их и проверяем.
let PREV_SNI = getenv('BW_SNI') ?? '', PREV_WSHOST = getenv('BW_WSHOST') ?? '';
// Строка JSON: пароль и логин уходят в конфиг строкой JSON, кавычка и
// обратная косая в них законны и экранируются (J_*), а не запрещаются.
function jstr(s) {
    return '"' + replace(s, /[\\"\x01-\x1f]/g,
        (c) => (c == '\\' || c == '"') ? '\\' + c : sprintf('\\u%04x', ord(c))) + '"';
}
function flush() {
    for (let k in N) put('N_' + k, N[k]);
    for (let k in [ 'PASS', 'USER', 'OBFSPW' ]) put('J_' + k, jstr(N[k] ?? ''));
}

// Поля, уходящие в конфиг строками. Пароли и логин экранирует jstr --
// кавычка в них не отказ; управляющий знак -- отказ везде.
function node_json_ok() {
    for (let p in [ ['адрес', N.HOST], ['id', N.UUID], ['пароль', N.PASS],
                    ['user', N.USER], ['method', N.METHOD], ['type', N.TYPE],
                    ['security', N.SEC], ['sni', N.SNI ?? PREV_SNI], ['fp', N.FP],
                    ['path', N.PATH], ['host', N.WSHOST ?? PREV_WSHOST], ['pbk', N.PBK],
                    ['sid', N.SID], ['flow', N.FLOW], ['mode', N.MODE],
                    ['alpn', N.ALPN], ['headerType', N.HDR], ['seed', N.SEED],
                    ['serviceName', N.SVC], ['authority', N.AUTH], ['spx', N.SPX],
                    ['pqv', N.PQV], ['quicSecurity', N.QSEC], ['key', N.QKEY],
                    ['encryption', N.ENC], ['obfs-password', N.OBFSPW],
                    ['pcs', N.PIN], ['vcn', N.VCN], ['obfs', N.OBFS],
                    ['privatekey', N.WGKEY], ['publickey', N.WGPUB],
                    ['presharedkey', N.WGPSK], ['address', N.WGADDR],
                    ['mtu', N.WGMTU], ['reserved', N.WGRES], ['keepalive', N.WGKA] ]) {
        if (match(p[1], /[\x01-\x1f\x7f]/)) {
            flush();
            dief("в поле «%s» ссылки управляющий знак (перевод строки, табуляция): такая ссылка подменяет поля конфига", p[0]);
        }
        if (p[0] in [ 'пароль', 'user', 'obfs-password' ]) continue;
        if (index(p[1], '"') >= 0 || index(p[1], '\\') >= 0) {
            flush();
            dief("в поле «%s» ссылки кавычка или обратная косая: значения уходят в конфиг как есть, и такая ссылка подменяет его поля", p[0]);
        }
    }
}

// extra подставляется в конфиг объектом, мимо node_json_ok: ровно один
// объект и ничего вокруг. `{} } }, "settings": {…}` закрыл бы
// xhttpSettings и streamSettings и дописал свой settings (Xray берёт
// последний из повторных ключей). Вид скобок не различаем -- ядро отвергнет.
function json_obj_ok(s) {
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

let scheme = before(URL, '://');
put('N_SCHEME', scheme);
if (!(scheme in [ 'vless', 'trojan', 'socks', 'vmess', 'ss', 'hysteria2', 'hy2', 'wireguard', 'wg' ])) {
    // В Xray-core нет исходящего tuic, а hysteria -- только вторая версия
    // (сверено по исходникам 26.9.30).
    if (scheme == 'hysteria' || scheme == 'tuic')
        dief("%s в Xray-core нет; из похожего есть hysteria2", scheme);
    dief("неизвестный вид ссылки: %s", scheme);
}
let rest = after(URL, '://');
// Метка после решётки -- имя, обычно с флагом; не секрет.
put('N_LABEL', index(URL, '#') >= 0 ? pctd(after(URL, '#')) : '');
rest = before(rest, '#');

// vmess://<base64 от JSON>: add, port, id, aid, net, type, host, path, tls,
// sni, scy, alpn, fp.
if (scheme == 'vmess') {
    let j = b64d(rest);
    if (j == '') { flush(); die("vmess-ссылка не раскодировалась"); }
    let o = json(j);
    if (type(o) != 'object') { flush(); die("vmess-ссылка не раскодировалась"); }
    let jf = (k) => (o[k] == null) ? '' : '' + o[k];
    N.HOST = jf('add'); N.PORT = jf('port'); N.UUID = jf('id');
    if (index(N.HOST, ':') >= 0) { flush(); dief("адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя", N.HOST); }
    // aid уходит в конфиг без кавычек -- только число.
    N.AID = jf('aid') || '0';
    if (!match(N.AID, /^[0-9]+$/)) { flush(); dief("aid у vmess — не число: %s", N.AID); }
    N.TYPE = jf('net') || 'tcp';
    N.PATH = jf('path') || '/';
    N.WSHOST = jf('host');
    // type=none клиенты пишут почти всегда; свежее ядро отвергает его как
    // заголовок mkcp, поэтому «нет заголовка» -- пусто.
    N.HDR = jf('type'); if (N.HDR == 'none') N.HDR = '';
    if (jf('tls') == 'tls') N.SEC = 'tls';
    N.SNI = jf('sni') || N.WSHOST || N.HOST;
    if (N.WSHOST == '') N.WSHOST = N.HOST;
    N.METHOD = jf('scy');
    if (!(N.METHOD in [ '', 'auto', 'aes-128-gcm', 'chacha20-poly1305', 'none', 'zero' ])) {
        flush();
        dief("scy=%s у vmess Xray-core не знает: есть auto, aes-128-gcm, chacha20-poly1305, none, zero", N.METHOD);
    }
    N.ALPN = jf('alpn');
    if (jf('fp') != '') N.FP = jf('fp');
    // У vmess имя сервиса gRPC лежит в path (v2rayN и др.); сырой path, не
    // N.PATH, где пустой заменён на «/».
    if (N.TYPE == 'grpc') N.SVC = jf('path');
    N.PROTO = 'vmess';
    // Прочие поля JSON (allowInsecure и т. п.) не переносятся -- называем.
    for (let k in keys(o))
        if (!(k in [ 'v', 'ps', 'add', 'port', 'id', 'aid', 'scy', 'net', 'type', 'host',
                     'path', 'tls', 'sni', 'alpn', 'fp' ]))
            warnf("параметр ссылки «%s» byway в конфиг не переносит — стоит проверить, важен ли он", k);
    node_json_ok();
    flush(); stop();
}

// ss://<base64 метод:пароль>@host:port и ss://метод:пароль@host:port; в
// старой форме в base64 вся ссылка.
if (scheme == 'ss') {
    if (index(rest, '@') < 0) {
        rest = b64d(before(rest, '?'));
        if (index(rest, '@') < 0) { flush(); die("ss-ссылка не разобралась"); }
    }
    // Делим по последней «@»: в открытом пароле она законна.
    let ui = substr(rest, 0, rindex(rest, '@'));
    let hp = lastafter(rest, '@');
    // Плагин (obfs-local, v2ray-plugin) Xray-core не запускает; прочие
    // параметры не переносятся -- называем.
    if (index(hp, 'plugin=') >= 0)
        warn("plugin у shadowsocks не переносится: Xray-core плагины не запускает, сервер с плагином не ответит");
    if (index(hp, '?') >= 0)
        for (let l in split(after(hp, '?'), '&')) {
            let pn = before(l, '=');
            if (pn != '' && pn != 'plugin')
                warnf("параметр ссылки «%s» byway в конфиг не переносит — стоит проверить, важен ли он", pn);
        }
    hp = before(before(hp, '?'), '/');
    let plain = index(ui, ':') >= 0 ? pctd(ui) : b64d(ui);
    if (substr(hp, 0, 1) == '[') { flush(); dief("адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя", hp); }
    N.METHOD = before(plain, ':');
    N.PASS = after(plain, ':');
    N.HOST = before(hp, ':');
    N.PORT = lastafter(hp, ':');
    // Без порта взялся бы сам адрес: "port": example.com.
    if (N.PORT == N.HOST) N.PORT = '443';
    N.PROTO = 'shadowsocks';
    node_json_ok();
    flush(); stop();
}

// Остальные схемы -- всё в адресе открытым текстом. Без «@» части до неё
// нет: wg-ссылки Hiddify и hysteria2 без пароля несут всё в параметрах.
let ui = index(rest, '@') >= 0 ? before(rest, '@') : '';
let rest2 = after(rest, '@');
// hysteria2 пишет «host:port/?sni=…» -- косая перед вопросом не порт.
let hostport = before(before(rest2, '?'), '/');
// IPv6 не поддержан: [2001:db8::1]:443 резался бы по первому двоеточию.
if (substr(hostport, 0, 1) == '[') { flush(); dief("адрес IPv6 в ключе не поддержан: %s — нужен IPv4 или имя", hostport); }
N.HOST = before(hostport, ':');
N.PORT = lastafter(hostport, ':');
if (N.PORT == N.HOST) N.PORT = '443';
let query = index(rest2, '?') >= 0 ? after(rest2, '?') : '';

if (scheme == 'vless') { N.UUID = ui; N.PROTO = 'vless'; }
else if (scheme == 'trojan') { N.PASS = pctd(ui); N.PROTO = 'trojan'; }
else if (scheme == 'hysteria2' || scheme == 'hy2') { N.PASS = pctd(ui); N.PROTO = 'hysteria'; }
else if (scheme == 'wireguard' || scheme == 'wg') { N.WGKEY = pctd(ui); N.PROTO = 'wireguard'; }
else if (scheme == 'socks') {
    let su = pctd(ui);
    // Часть клиентов кладёт «логин:пароль» в base64 (socks://dXNlcjpwYXNz@…).
    if (su != '' && index(su, ':') < 0) {
        let sd = b64d(su);
        if (index(sd, ':') >= 0) su = sd;
    }
    N.USER = before(su, ':'); N.PASS = after(su, ':');
    if (N.USER == su) { N.USER = ''; N.PASS = ''; }
    N.PROTO = 'socks';
}

function qraw(name) {
    for (let l in split(query, '&'))
        if (substr(l, 0, length(name) + 1) == name + '=')
            return substr(l, length(name) + 1);
    return null;
}
// Раскодируем целиком: кавычку, косую и управляющие знаки отсекает
// node_json_ok. Частичное раскодирование превращало путь v2rayN
// `%2F%3Fed%3D2048` в `/%3Fed=2048`: Xray не находил ed, ответ 404.
function qp(name) { let v = qraw(name); return v == null ? '' : pctd(v); }
// Первый непустой из нескольких имён (v2rayN -- publickey, Hiddify -- peer_pk).
function qpa(names) { for (let n in names) { let v = qp(n); if (v != '') return v; } return ''; }
// extra -- объект JSON: раскодируются только знаки, законные в нём; объект
// проверяет json_obj_ok.
function qp_json(name) {
    let v = qraw(name);
    if (v == null) return '';
    for (let p in [ ['%2F', '/'], ['%3A', ':'], ['%2C', ','], ['%20', ' '], ['%3D', '='],
                    ['%26', '&'], ['%7B', '{'], ['%7D', '}'], ['%22', '"'], ['%5B', '['],
                    ['%5D', ']'] ])
        v = replace(v, p[0], p[1]);
    return nl(v);
}

let v = qp('type'); if (v != '') N.TYPE = v;
// trojan без TLS не бывает, а клиенты security часто опускают.
if (N.PROTO == 'trojan') N.SEC = 'tls';
v = qp('security'); if (v != '') N.SEC = v;
N.SNI = qp('sni') || N.HOST;
v = qp('fp'); if (v != '') N.FP = v;
v = qp('path'); if (v != '') N.PATH = v;
N.WSHOST = qp('host') || N.HOST;
N.PBK = qp('pbk'); N.SID = qp('sid'); N.FLOW = qp('flow');
// flow у trojan в конфиг не пишется, а mux при нём отключался.
if (N.PROTO == 'trojan' && N.FLOW != '') {
    warnf("flow=%s у trojan Xray-core не поддерживает — пропущен", N.FLOW); N.FLOW = '';
}
N.MODE = qp('mode'); N.ALPN = qp('alpn'); N.HDR = qp('headerType');
N.SEED = qp('seed'); N.SVC = qp('serviceName'); N.AUTH = qp('authority');
N.SPX = qp('spx'); N.PQV = qp('pqv'); N.ENC = qp('encryption');
N.QSEC = qp('quicSecurity'); N.QKEY = qp('key'); N.EXTRA = qp_json('extra');
N.INSEC = qp('allowInsecure') || qp('insecure');
// pcs -- имя у v2rayN, pinSHA256 -- у hysteria2; значение одно и то же.
N.PIN = qp('pcs') || qp('pinSHA256');
N.VCN = qp('vcn');

if (N.PROTO == 'hysteria') {
    // Транспорт hysteria всегда под TLS («tls config is nil» без него); у
    // QUIC нет uTLS-отпечатка.
    N.TYPE = 'hysteria'; N.SEC = 'tls'; N.FP = '';
    if (N.ALPN == '') N.ALPN = 'h3';
    // Диапазон портов Xray-core через hysteriaSettings не берёт.
    if (match(N.PORT, /[,-]/)) {
        let p1 = match(N.PORT, /^[^,-]*/)[0];
        warnf("диапазон портов в ключе не переносится: соединение идёт на порт %s", p1);
        N.PORT = p1;
    }
    v = qp('obfs');
    if (v == 'salamander') {
        N.OBFS = 'salamander'; N.OBFSPW = qp('obfs-password');
        if (N.OBFSPW == '') { flush(); die("obfs=salamander без obfs-password: пароль обфускации обязателен"); }
    }
    else if (v != '' && v != 'none') {
        flush(); dief("obfs=%s у hysteria2 не поддержан: в Xray-core есть только salamander", v);
    }
    if (qp('mport') != '')
        warn("mport (смена портов) не переносится: соединение идёт на основной порт из ключа");
}

if (N.PROTO == 'wireguard') {
    N.TYPE = 'wireguard'; N.SEC = 'none';
    if (N.WGKEY == '') N.WGKEY = qpa([ 'privatekey', 'secretkey', 'pk' ]);
    N.WGPUB = qpa([ 'publickey', 'peer_pk' ]);
    N.WGPSK = qpa([ 'presharedkey', 'pre_shared_key', 'psk' ]);
    N.WGADDR = nl(replace(qpa([ 'address', 'local_address' ]), ' ', ''));
    N.WGMTU = qp('mtu'); N.WGRES = nl(replace(qp('reserved'), ' ', '')); N.WGKA = qp('keepalive');
    // Ключи -- base64 на 32 байта либо hex (ParseWireGuardKey); образец
    // строгий: значение уходит в конфиг.
    let key = /^([A-Za-z0-9+\/]{43}=|[0-9a-fA-F]{64})$/;
    if (!grepq(key, N.WGKEY)) { flush(); die("в ключе wireguard нет закрытого ключа либо он не той формы (base64 на 44 знака либо 64 шестнадцатеричных)"); }
    if (!grepq(key, N.WGPUB)) { flush(); die("в ключе wireguard нет публичного ключа сервера (publickey) либо он не той формы"); }
    if (N.WGPSK != '' && !grepq(key, N.WGPSK)) { flush(); die("presharedkey в ключе wireguard не той формы"); }
    // Без своего адреса в туннеле ядро ставит 10.0.0.1, сервер такого
    // клиента не узнаёт, и соединение молча не идёт.
    if (N.WGADDR == '') { flush(); die("в ключе wireguard нет address -- адреса этого клиента в туннеле"); }
    if (!grepq(/^[0-9a-fA-F.:]+(\/[0-9]{1,3})?(,[0-9a-fA-F.:]+(\/[0-9]{1,3})?)*$/, N.WGADDR)) {
        flush(); dief("address в ключе wireguard не похож на список адресов: %s", N.WGADDR);
    }
    if (N.WGMTU != '' && !grepq(/^[0-9]{3,4}$/, N.WGMTU)) { flush(); dief("mtu в ключе wireguard -- не число: %s", N.WGMTU); }
    if (N.WGRES != '' && !grepq(/^[0-9]{1,3},[0-9]{1,3},[0-9]{1,3}$/, N.WGRES)) {
        flush(); dief("reserved в ключе wireguard -- не три числа через запятую: %s", N.WGRES);
    }
    if (N.WGKA != '' && !grepq(/^[0-9]{1,5}$/, N.WGKA)) { flush(); dief("keepalive в ключе wireguard -- не число: %s", N.WGKA); }
}
if (N.PIN != '' && !grepq(/^[0-9a-fA-F:,]+$/, N.PIN)) {
    flush(); dief("отпечаток сертификата (pcs, pinSHA256) -- не шестнадцатеричный: %s", N.PIN);
}
if (N.VCN != '' && !grepq(/^[A-Za-z0-9.,*-]+$/, N.VCN)) {
    flush(); dief("имя для проверки сертификата (vcn) -- не имя хоста: %s", N.VCN);
}
node_json_ok();
if (N.EXTRA != '' && !json_obj_ok(N.EXTRA)) {
    flush();
    die("параметр extra в ссылке -- не один объект JSON: он подставляется в конфиг как есть, и такая ссылка переписывает соседние поля, включая адрес сервера и защиту");
}

// Имена параметров В ССЫЛКЕ -- соглашение клиентов; незнакомые называем,
// чтобы человек узнал, что из ссылки не перенесено.
let known = [ 'type', 'security', 'sni', 'fp', 'alpn', 'path', 'host', 'headerType', 'seed',
              'serviceName', 'mode', 'authority', 'pbk', 'sid', 'spx', 'pqv', 'flow',
              'encryption', 'quicSecurity', 'key', 'extra', 'allowInsecure', 'insecure',
              'pinSHA256', 'pcs', 'vcn' ];
if (N.PROTO == 'hysteria') push(known, 'obfs', 'obfs-password', 'mport');
if (N.PROTO == 'wireguard')
    push(known, 'publickey', 'privatekey', 'secretkey', 'pk', 'peer_pk', 'presharedkey',
         'pre_shared_key', 'psk', 'address', 'local_address', 'mtu', 'reserved', 'keepalive');
for (let l in split(query, '&'))
    for (let pn in split(before(l, '='), /[ \t]+/))
        if (pn != '' && !(pn in known))
            warnf("параметр ссылки «%s» byway в конфиг не переносит — стоит проверить, важен ли он", pn);

// Шифрование VLESS: форма -- образцом, версию ядра проверяет parse_node.
if (N.ENC != '' && N.ENC != 'none') {
    if (N.PROTO != 'vless') { flush(); dief("encryption=%s бывает только у vless", N.ENC); }
    if (!grepq(/^mlkem768x25519plus\.[A-Za-z0-9._+\/=-]+$/, N.ENC)) {
        flush(); dief("encryption=%s не поддержан: Xray-core знает только mlkem768x25519plus", N.ENC);
    }
}
flush(); stop();
