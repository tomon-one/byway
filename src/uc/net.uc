// Загрузки, которые обязаны пройти и при сломанном туннеле: прокси-вход, потом напрямую, потом адреса
// GitHub из DoH.

// Адрес имени по DoH, запросом К АДРЕСУ, не к имени: при сломанном туннеле
// локальный DNS отдаёт подставной адрес на всё из списка. Тот же приём в
// install.sh (doh_a).
function nt_doh_a(name) {
	for (let q in [ 'https://8.8.8.8/resolve?name=' + name + '&type=A',
	                'https://1.1.1.1/dns-query?name=' + name + '&type=A' ]) {
		let r = run([ 'curl', '-fsSL', '--max-time', '8', '-H', 'accept: application/dns-json', q ]);
		for (let p in split(r.out, ',')) {
			let m = match(p, /"data":"([0-9][0-9.]*)"/);
			if (m && match(m[1], /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) return m[1];
		}
	}
	return null;
}

// --resolve для имён GitHub (и переадресаций выпусков), один раз за запуск.
let NT_RES = null;
function nt_gh_resolve() {
	if (NT_RES != null) return NT_RES;
	NT_RES = [];
	for (let h in [ 'github.com', 'api.github.com', 'raw.githubusercontent.com', 'codeload.github.com',
	                'objects.githubusercontent.com', 'release-assets.githubusercontent.com' ]) {
		let a = nt_doh_a(h);
		if (a) push(NT_RES, '--resolve', h + ':443:' + a);
	}
	return NT_RES;
}

// curl с доводами args; итог -- код выхода последней попытки (0 -- удача).
// NT_CERT -- хоть одна попытка отказала проверкой сертификата (curl 60): по
// ней часы называются причиной и тогда, когда они позже порога clock_bad, а
// сертификат GitHub ещё «не действует» (Ф9, п2-14, прогон 5).
let NT_CERT = false;
function nt_get(args) {
	let px = u('local_proxy_port') || '1603';
	let base = [ 'curl', '-fsSL', '-A', 'Mozilla/5.0' ];
	let c = run([ ...base, '--proxy', 'http://127.0.0.1:' + px, ...args ]).code;
	if (c == 0) return 0;
	if (c == 60) NT_CERT = true;
	c = run([ ...base, ...args ]).code;
	if (c == 0) return 0;
	if (c == 60) NT_CERT = true;
	let res = nt_gh_resolve();
	if (!length(res)) return 1;
	c = run([ ...base, ...res, ...args ]).code;
	if (c == 60) NT_CERT = true;
	return c;
}
