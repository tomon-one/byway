# Готовые наборы (presets): загрузка, проверка, пересечения -- в ucode
# (uc/presets.uc). Каталог -- здесь: его читают склейка, doctor, экспорт.
PRESETS_DIR=$LISTS/presets

cmd_presets() {
    BW_LISTS=$LISTS BW_ROUTES=$ROUTES_DIR BW_PRESETS=$PRESETS_DIR BW_BADLIST=$BADLIST bw_uc presets
}
