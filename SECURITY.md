# Безопасность

*[English below](#security-policy)*

byway работает на роутере от root, трогает файрвол и DNS всего дома и хранит
ключ от вашего VPN. Поэтому об уязвимости лучше сообщить закрыто, а не в
открытом issue.

## Как сообщить

Любым из трёх способов:

- **GitHub** — [приватный отчёт](https://github.com/tomon-one/byway/security/advisories/new)
  (вкладка Security → «Report a vulnerability»). Его видит только автор;
- **почта** — tomon.one0@gmail.com;
- **Telegram** — [@toomonn](https://t.me/toomonn).

Что приложить:

- версию byway (`byway version`) и OpenWrt (`grep DISTRIB_RELEASE /etc/openwrt_release`);
- что нужно сделать, чтобы воспроизвести, и что получается в итоге;
- чем это грозит: кто может воспользоваться и что он получит.

⚠️ **Не присылайте свой ключ VPN** — ни ссылку `vless://…`, ни выгрузку с
ключом. `byway report` и `byway export` собирают всё нужное без него.

Проект ведёт один человек. Исправление уязвимости выходит отдельным выпуском,
не дожидаясь других правок; в описании выпуска будет сказано, что обновиться
нужно сразу.

## Какие версии поддерживаются

Только последний выпуск. Исправления в старые версии не переносятся:
обновление — `byway update`.

## Что считается уязвимостью

- утечка ключа VPN: в журнал, в отчёт, в выгрузку без ключа, в файл, доступный
  по http, в ответ панели;
- выполнение команд через данные извне: ключ, подписку, готовые списки,
  выгрузку для импорта, ответы GitHub;
- действия через панель LuCI сверх того, что разрешает её ACL
  (`/usr/share/rpcd/acl.d/luci-app-byway.json`);
- трафик, который уходит мимо VPN, когда в «Если VPN не поднялся» выбрано
  «Не пускать»;
- подмена файлов при установке или обновлении, которую byway не замечает там,
  где обещает проверку.

## Что уязвимостью не считается

Эти ограничения описаны в README и известны:

- устройство с «Приватным DNS» или DoH идёт мимо byway;
- при «Если VPN не поднялся» → «Пустить напрямую» без туннеля трафик списка
  идёт напрямую;
- IPv6 экспериментален и не проверен настоящим трафиком;
- уязвимости самого Xray-core, OpenWrt или LuCI — о них сообщают их авторам:
  [XTLS/Xray-core](https://github.com/XTLS/Xray-core/security),
  [OpenWrt](https://openwrt.org/docs/guide-developer/security).

## Что стоит знать заранее

- **Ключ хранится в `/etc/config/byway`**, как и прочие настройки OpenWrt: его
  может прочитать root и пользователь LuCI с доступом к настройкам byway.
  `byway export` пишет выгрузку без ключа, с ключом — `byway export
  --with-key`. Выгрузка и отчёт создаются сразу с правами `600`.
- **Файлы byway не подписаны.** Установка и обновление доверяют HTTPS до
  GitHub и тегу выпуска. Если GitHub недоступен, установщик переходит на
  чужое зеркало gh-proxy и предупреждает об этом; запретить — `NO_MIRROR=1`.
- **Архив Xray-core сверяется с суммой SHA2-256** из того же выпуска XTLS. Это
  защита от битой загрузки, но не от подмены: через зеркало и архив, и сумма
  приходят с самого зеркала, а напрямую от посредника защищает HTTPS до GitHub.
  Подписей XTLS не выпускает.
- **Резервная копия OpenWrt и sysupgrade несут ключ:** в них входят
  `/etc/config/byway` и `/etc/byway/config.json`. Архив «Система → Резервная
  копия» хранить как пароль.

---

# Security policy

byway runs on the router as root, touches the whole household's firewall and
DNS, and stores your VPN key. So please report a vulnerability privately, not
in a public issue.

## How to report

Any of the three:

- **GitHub** — a [private report](https://github.com/tomon-one/byway/security/advisories/new)
  (Security tab → "Report a vulnerability"). Only the author sees it;
- **email** — tomon.one0@gmail.com;
- **Telegram** — [@toomonn](https://t.me/toomonn).

What to include:

- the byway version (`byway version`) and OpenWrt version
  (`grep DISTRIB_RELEASE /etc/openwrt_release`);
- how to reproduce it and what happens as a result;
- the impact: who can exploit it and what they get.

⚠️ **Do not send your VPN key** — neither a `vless://…` link nor an export with
the key. `byway report` and `byway export` collect everything needed without
it.

The project is run by one person. A vulnerability fix ships as its own
release, without waiting for other changes; the release notes will say to
update right away.

## Supported versions

The latest release only. Fixes are not backported: update with `byway update`.

## What counts as a vulnerability

- the VPN key leaking: into a log, a report, a key-less export, a file served
  over http, a web UI response;
- command execution through outside data: the key, a subscription, ready-made
  lists, an export being imported, GitHub responses;
- actions through the LuCI web UI beyond what its ACL allows
  (`/usr/share/rpcd/acl.d/luci-app-byway.json`);
- traffic leaving outside the VPN when "If the VPN does not come up" is set
  to "Block";
- files replaced during install or update without byway noticing, where it
  promises a check.

## What is not a vulnerability

These limitations are documented in the README and known:

- a device with Private DNS or DoH goes around byway;
- with "If the VPN does not come up" → "Go direct", list traffic goes direct
  while the tunnel is down;
- IPv6 is experimental and has not been verified with real traffic;
- vulnerabilities in Xray-core, OpenWrt or LuCI themselves — report those to
  their authors: [XTLS/Xray-core](https://github.com/XTLS/Xray-core/security),
  [OpenWrt](https://openwrt.org/docs/guide-developer/security).

## Worth knowing up front

- **The key is stored in `/etc/config/byway`**, like other OpenWrt settings: it
  is readable by root and by a LuCI user with access to byway's settings.
  `byway export` writes an export without the key, with the key —
  `byway export --with-key`. Exports and reports are created with mode `600`
  from the start.
- **byway's files are not signed.** Install and update trust HTTPS to GitHub
  and the release tag. If GitHub is unreachable, the installer switches to the
  third-party gh-proxy mirror and warns about it; to forbid that — `NO_MIRROR=1`.
- **The Xray-core archive is checked against the SHA2-256 sum** from the same
  XTLS release. That protects against a broken download, not against
  tampering: through the mirror both the archive and the sum come from the
  mirror itself, and directly HTTPS to GitHub already stops a middleman. XTLS
  publishes no signatures.
- **An OpenWrt backup and sysupgrade carry the key:** they include
  `/etc/config/byway` and `/etc/byway/config.json`. Treat the
  "System → Backup" archive like a password.
