#!/bin/sh
# Собирает byway из модулей NN-*.sh по порядку номеров. Правится src/, а не
# byway: собранный файл перезаписывается целиком. --check -- только сверка
# (код 1, если byway отстал от src/).
set -e
cd "$(dirname "$0")"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
{
    head -n 1 00-head.sh
    echo "# Собран из src/*.sh командой src/build.sh -- правка здесь пропадёт при сборке."
    tail -n +2 00-head.sh
    for f in [0-9][0-9]-*.sh; do
        [ "$f" = 00-head.sh ] && continue
        echo
        cat "$f"
    done
} > "$out"
if [ "${1:-}" = --check ]; then
    cmp -s "$out" ../byway && exit 0
    echo "byway отстал от src/ -- запустите src/build.sh" >&2
    exit 1
fi
cp "$out" ../byway.new
chmod 755 ../byway.new
mv ../byway.new ../byway
