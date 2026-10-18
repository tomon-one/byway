# Проверки ключа без боевого конфига: check (разбор и run -test) и probe
# (соединение через ноду) -- в ucode (uc/probe.uc). Здесь окружение и уборка:
# ucode сигналы не ловит, и прерванная проба оставила бы движок и черновик с uuid.

pr_env() {
    PR_MARK=$(ob_env_mark)
}

cmd_check() {
    pr_env
    BW_SELFMARK=$PR_MARK bw_uc check "$@"
}

# PROBE_URL -- проверить через ноду конкретный сайт, а не только выход;
# PROBE_PORT -- порт временного socks-входа. --all -- каждый ключ автовыбора.
cmd_probe() {
    trap '_pp=$(cat /var/run/byway/probe.pid 2>/dev/null || true)
          [ -z "$_pp" ] || kill "$_pp" 2>/dev/null || true
          rm -f /var/run/byway/probe.pid 2>/dev/null || true
          for _pf in /tmp/byway-probe.json /tmp/byway-probe.log /tmp/byway-probe.out; do
              [ ! -f "$_pf" ] || : > "$_pf"
          done' EXIT INT TERM
    pr_env
    BW_SELFMARK=$PR_MARK bw_uc probe "$@"
}
