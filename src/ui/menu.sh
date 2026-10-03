# Текстовое меню (byway menu) поверх тех же команд.

m_line()  { printf '  \033[2m──────────────────────────────────────────\033[0m\n'; }

m_item()  { printf '   \033[1m%s\033[0m  %s\n' "$1" "$(_t "$2")"; }

m_head()  { clear 2>/dev/null || printf '\n\n'; printf '\n  \033[1m%s\033[0m\n\n' "$(_t "$1")"; }

m_pause() { printf "$(_t '\n  \033[2mEnter — назад\033[0m')"; read -r _ || true; echo; }

m_ask()   { printf '  %s: ' "$(_t "$1")"; read -r REPLY || REPLY=""; }

m_yes()   {
    # Подсказка [y/N] латиницей в обоих языках: терминал обычно на английской
    # раскладке. Принимается и «д».
    printf '  \033[1;33m%s\033[0m [y/N]: ' "$(_t "$1")"
    read -r _a || _a=""
    case "$_a" in [yYдД]*) return 0 ;; *) return 1 ;; esac
}

# Пересборка и перезапуск после правки: без неё настройка сохранена, но
# не действует.
m_apply() {
    echo
    if (cmd_gen); then
        # restart на выключенной службе ничего не поднимает, а включить её
        # из меню нельзя (enabled только через uci): сказать об этом.
        if [ "$(u enabled)" != "1" ]; then
            printf "$(_t '\n  \033[1;33mсобрано, но byway ВЫКЛЮЧЕН\033[0m — туннеля не будет\n')"
            printf "$(_t '  включить: uci set byway.main.enabled=1 && uci commit byway && /etc/init.d/byway restart\n')"
            return 0
        fi
        /etc/init.d/byway restart >/dev/null 2>&1 || true
        printf "$(_t '\n  \033[1;32mприменено\033[0m — движок стартует до 15 секунд\n')"
    else
        printf "$(_t '\n  \033[1;31mне применилось\033[0m — работает прежняя настройка\n')"
    fi
}

# Строка состояния в шапке: без обращений в сеть, меню открывается сразу.
m_state() {
    if [ -n "$(xray_pid)" ]; then
        # ESC разворачивается здесь: в %s ниже escape-последовательности
        # не обрабатываются.
        _s=$(printf '\033[32m%s\033[0m' "$(_t работает)")
    else
        _s=$(printf '\033[31m%s\033[0m' "$(_t "не запущена")")
    fi
    if [ "$(u list_mode)" = "all" ]; then _m=$(_t "всё через VPN")
    else _m=$(_t "по спискам"); fi
    printf '  %s\n' "$(_f 'служба: %s     режим: %s' "$_s" "$_m")"
}

m_connection() {
    while :; do
        m_head "Подключение к VPN"
        m_item 1 "Показать текущее"
        m_item 2 "Вписать ключ"
        m_item 3 "Загрузить из подписки"
        m_item 4 "Проверить ключ отдельно, не трогая работающий туннель"
        m_line
        m_item 0 "Назад"
        echo
        m_ask "Выбор"
        case "$REPLY" in
          1) echo
             # Грепать по переведённым словам: cmd_status печатает через
             # словарь, русские литералы в английском режиме не совпадут.
             _mf="$(_t 'подключение')|$(_t 'транспорт')|$(_t 'ключ')"
             cmd_status 2>&1 | grep -E "$_mf" |
                 sed "s/^/    /" || printf "    $(_t 'подключение не настроено\n')"
             m_pause ;;
          2) echo
             printf "$(_t "  Ссылка целиком: vless://… trojan://… ss://… vmess://… hy2://… wireguard://…\n")"
             printf "$(_t "  Ключ никуда не отправляется и в журнал не пишется.\n\n")"
             m_ask "Ключ"
             if [ -n "$REPLY" ]; then
                 echo
                 # Проверка до записи: неразобранный ключ в настройках
                 # оставит без туннеля и без понятной причины.
                 if (cmd_check "$REPLY" >/dev/null 2>&1); then
                     uci set byway.main.node_url="$REPLY"
                     uci set byway.main.conn_mode=key
                     uci commit byway
                     printf "$(_t "  \033[1;32mключ принят\033[0m\n")"
                     m_apply
                 else
                     printf "$(_t "  \033[1;31mключ не разобран\033[0m, вот что говорит проверка:\n\n")"
                     cmd_check "$REPLY" 2>&1 | tail -6 | sed "s/^/    /" || true
                 fi
             fi
             m_pause ;;
          3) echo
             m_ask "Адрес подписки"
             if [ -n "$REPLY" ]; then
                 uci set byway.main.sub_url="$REPLY"; uci commit byway
                 echo
                 cmd_sub "$REPLY" 2>&1 | sed "s/^/    /" || true
                 printf "$(_t "\n  Ключи выше. Вписать нужный — пункт 2.\n")"
             fi
             m_pause ;;
          4) echo; cmd_probe 2>&1 | sed "s/^/    /" || true; m_pause ;;
          0|"") return 0 ;;
        esac
    done
}

m_mode() {
    while :; do
        m_head "Режим работы"
        if [ "$(u list_mode)" = "all" ]; then _now=$(_t "всё через VPN"); else _now=$(_t "по спискам"); fi
        printf "$(_t "  Сейчас: \033[1m%s\033[0m\n\n")" "$_now"
        m_item 1 "По спискам — через VPN только перечисленное"
        m_item 2 "Всё через VPN"
        if [ "$(u ru_direct)" = "1" ]; then _rd=$(_t включено); else _rd=$(_t выключено); fi
        m_item 3 "$(_f 'Русские сайты мимо VPN: %s' "$_rd")"
        m_line
        m_item 0 "Назад"
        echo
        m_ask "Выбор"
        case "$REPLY" in
          1) uci set byway.main.list_mode=lists; uci commit byway; m_apply; m_pause ;;
          2) echo
             printf "$(_t "  Через VPN пойдёт весь трафик, включая загрузки и обновления.\n")"
             if m_yes "Включить?"; then
                 uci set byway.main.list_mode=all; uci commit byway; m_apply
             fi
             m_pause ;;
          3) if [ "$(u ru_direct)" = "1" ]; then uci set byway.main.ru_direct=0
             else uci set byway.main.ru_direct=1; fi
             uci commit byway; m_apply; m_pause ;;
          0|"") return 0 ;;
        esac
    done
}

m_lists() {
    # Объединённый список, не только свой: в режиме «всё через VPN» своего
    # нет по построению, и health писал бы «dns не выдаёт адрес».
    _dl=$(merged_domains)
    _sl=$LISTS/subnets.lst
    while :; do
        # Кэш пересобирается при каждом обращении: после добавления домена
        # проверка «уже есть» и счёт судили по прежнему содержимому.
        _dl=$(merged_domains)
        m_head "Списки"
        printf "$(_t "  доменов %s, подсетей %s\n\n")" \
            "$(count_list "$_dl" 2>/dev/null || echo 0)" \
            "$(count_list "$_sl" 2>/dev/null || echo 0)"
        m_item 1 "Показать домены"
        m_item 2 "Добавить домен"
        m_item 3 "Убрать домен"
        m_item 4 "Обновить готовые списки"
        m_line
        m_item 0 "Назад"
        echo
        m_ask "Выбор"
        case "$REPLY" in
          1) echo; grep -vE "^[[:space:]]*$" "$_dl" 2>/dev/null | more || true; m_pause ;;
          2) echo; m_ask "Домен"
             if [ -n "$REPLY" ]; then
                 # Проверка -- по объединённому списку, запись -- в свой файл:
                 # объединённый кэш пересобирается из своего и пресетов, и
                 # дописанное в него пропадало при первой же сборке.
                 if grep -qxF "$REPLY" "$_dl" 2>/dev/null; then
                     printf "$(_t "\n  уже есть\n")"
                 else
                     [ ! -s "$LISTS/domains.lst" ] || [ -z "$(tail -c1 "$LISTS/domains.lst")" ] ||
                         printf '\n' >> "$LISTS/domains.lst"
                     printf "%s\n" "$REPLY" >> "$LISTS/domains.lst"
                     printf "$(_t "\n  добавлено\n")"; m_apply
                 fi
             fi
             m_pause ;;
          3) echo; m_ask "Домен"
             if [ -n "$REPLY" ]; then
                 if grep -qxF "$REPLY" "$LISTS/domains.lst" 2>/dev/null; then
                     grep -vxF "$REPLY" "$LISTS/domains.lst" > "$LISTS/domains.lst.new" &&
                         mv "$LISTS/domains.lst.new" "$LISTS/domains.lst"
                     printf "$(_t "\n  убрано\n")"; m_apply
                 else
                     printf "$(_t "\n  такой записи нет\n")"
                 fi
             fi
             m_pause ;;
          4) echo; cmd_presets 2>&1 | sed "s/^/    /" || true; m_apply; m_pause ;;
          0|"") return 0 ;;
        esac
    done
}

# Итог после запуска службы: движок ждём (до 12 с) и судим по нему, а не по
# коду init -- он при procd всегда 0.
m_svc_done() {   # 1 -- «запущена» либо «перезапущена»
    if [ "$(u enabled)" != "1" ]; then
        printf "$(_t '\n  byway ВЫКЛЮЧЕН настройкой — служба не запускается\n')"
        printf "$(_t '  включить: uci set byway.main.enabled=1 && uci commit byway && /etc/init.d/byway restart\n')"
        return 0
    fi
    _mw=0
    while [ "$_mw" -lt 12 ] && [ -z "$(xray_pid)" ]; do _mw=$((_mw + 1)); sleep 1; done
    if [ -n "$(xray_pid)" ]; then printf "\n  %s\n" "$1"
    else printf "$(_t '\n  движок не поднялся — смотреть: logread -e byway\n')"; fi
}

m_service() {
    while :; do
        m_head "Служба"
        m_state
        echo
        m_item 1 "Перезапустить"
        m_item 2 "Остановить"
        m_item 3 "Запустить"
        if ls /etc/rc.d/S*byway >/dev/null 2>&1; then _au=$(_t включён); else _au=$(_t выключен); fi
        m_item 4 "$(_f 'Автозапуск: %s' "$_au")"
        m_line
        m_item 0 "Назад"
        echo
        m_ask "Выбор"
        case "$REPLY" in
          1) echo; /etc/init.d/byway restart; m_svc_done "$(_t перезапущена)"; m_pause ;;
          2) echo
             printf "$(_t "  Туннеля не станет, интернет продолжит работать напрямую.\n")"
             if m_yes "Остановить?"; then
                 /etc/init.d/byway stop; printf "$(_t "\n  остановлена\n")"
             fi
             m_pause ;;
          3) echo; /etc/init.d/byway start; m_svc_done "$(_t запущена)"; m_pause ;;
          4) if ls /etc/rc.d/S*byway >/dev/null 2>&1; then
                 /etc/init.d/byway disable; printf "$(_t "\n  автозапуск выключен\n")"
             else
                 /etc/init.d/byway enable; printf "$(_t "\n  автозапуск включён\n")"
             fi
             m_pause ;;
          0|"") return 0 ;;
        esac
    done
}

m_logs() {
    while :; do
        m_head "Журнал и статистика"
        m_item 1 "Журнал состояния — что и когда менялось"
        m_item 2 "Чем пользуются"
        m_item 3 "Журнал движка"
        m_line
        m_item 0 "Назад"
        echo
        m_ask "Выбор"
        case "$REPLY" in
          1) echo
             tail -30 "$LISTS/health.log" 2>/dev/null | sed "s/^/    /" ||
                 printf "    $(_t 'пока пусто\n')"
             m_pause ;;
          2) echo; cmd_top 25 2>&1 | sed "s/^/    /" || true; m_pause ;;
          3) echo
             logread -e xray 2>/dev/null | tail -30 | sed "s/^/    /" ||
                 printf "    $(_t 'пусто\n')"
             m_pause ;;
          0|"") return 0 ;;
        esac
    done
}

m_transfer() {
    while :; do
        m_head "Экспорт и импорт настроек"
        printf "$(_t "  Все настройки и списки одним текстом: перенести на другой\n")"
        printf "$(_t "  роутер, сохранить перед опытами, приложить к вопросу.\n\n")"
        m_item 1 "Выгрузить без ключа — такой файл можно показывать"
        m_item 2 "Выгрузить вместе с ключом"
        m_item 3 "Принять из файла"
        m_line
        m_item 4 "Собрать отчёт для обращения — без ключа, но с диагностикой"
        m_line
        m_item 0 "Назад"
        echo
        m_ask "Выбор"
        case "$REPLY" in
          1) echo; m_ask "Куда сохранить [/tmp/settings-byway.txt]"
             echo; cmd_export "${REPLY:-/tmp/settings-byway.txt}" --no-key || true
             m_pause ;;
          2) echo; m_ask "Куда сохранить [/tmp/settings-byway.txt]"
             echo; cmd_export "${REPLY:-/tmp/settings-byway.txt}" --with-key || true
             m_pause ;;
          3) echo; m_ask "Файл"
             if [ -n "$REPLY" ]; then
                 _f=$REPLY
                 echo
                 printf "$(_t "  Настройки и списки будут заменены содержимым файла.\n")"
                 printf "$(_t "  Прежние сохраняются в %s/before-import/\n\n")" "$LISTS"
                 if m_yes "Принять?"; then
                     echo
                     if (cmd_import "$_f"); then
                         /etc/init.d/byway restart >/dev/null 2>&1 || true
                     fi
                 fi
             fi
             m_pause ;;
          4) echo; m_ask "Куда сохранить [/tmp/report-byway.txt]"
             echo; cmd_report "${REPLY:-/tmp/report-byway.txt}" || true
             m_pause ;;
          0|"") return 0 ;;
        esac
    done
}

cmd_menu() {
    [ -t 0 ] || die "меню работает только с терминала: byway menu"
    while :; do
        m_head "byway $BYWAY_VERSION"
        m_state
        echo
        m_item 1 "Что сейчас происходит"
        m_item 2 "Проверка связи"
        m_item 3 "Проверка окружения"
        m_line
        m_item 4 "Подключение к VPN"
        m_item 5 "Режим работы"
        m_item 6 "Списки"
        m_line
        m_item 7 "Служба"
        m_item 8 "Журнал и статистика"
        m_item 9 "Экспорт и импорт настроек"
        m_line
        m_item 0 "Выход"
        echo
        m_ask "Выбор"
        case "$REPLY" in
          1) echo; cmd_status 2>&1 | sed "s/^/    /" || true; m_pause ;;
          2) echo; printf "$(_t "    проверка занимает несколько секунд…\n\n")"
             cmd_health 2>&1 | tr "\t" " " | sed "s/^/    /" || true; m_pause ;;
          3) echo; cmd_doctor 2>&1 | sed "s/^/    /" || true; m_pause ;;
          4) m_connection ;;
          5) m_mode ;;
          6) m_lists ;;
          7) m_service ;;
          8) m_logs ;;
          9) m_transfer ;;
          0|"") clear 2>/dev/null || true; return 0 ;;
        esac
    done
}
