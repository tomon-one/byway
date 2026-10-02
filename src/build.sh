#!/bin/sh
# Собирает byway из файлов src/ в порядке ORDER; строка «#@include ФАЙЛ»
# заменяется содержимым файла (разборщик keys/parse.uc). Правится src/, а не
# byway: собранный файл перезаписывается целиком. --check -- только сверка
# (код 1, если byway отстал от src/).
set -e
cd "$(dirname "$0")"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
inc() {
    while IFS= read -r _l || [ -n "$_l" ]; do
        case "$_l" in
          '#@include '*) cat "${_l#\#@include }" ;;
          *) printf '%s\n' "$_l" ;;
        esac
    done < "$1"
}
_first=1
grep -v '^[[:space:]]*\(#\|$\)' ORDER | while IFS= read -r f; do
    if [ "$_first" = 1 ]; then
        head -n 1 "$f"
        echo "# Собран из src/ (порядок -- src/ORDER) командой src/build.sh -- правка здесь пропадёт при сборке."
        tail -n +2 "$f"
        _first=0
    else
        echo
        inc "$f"
    fi
done > "$out"
if [ "${1:-}" = --check ]; then
    cmp -s "$out" ../byway && exit 0
    echo "byway отстал от src/ -- запустите src/build.sh" >&2
    exit 1
fi
cp "$out" ../byway.new
chmod 755 ../byway.new
mv ../byway.new ../byway
