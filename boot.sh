#!/usr/bin/env bash
# ============================================================================
#  arch-forest — запуск установки с флешки Arch Linux.
#  Набери в установщике Arch (после подключения интернета):
#
#     curl -sL https://raw.githubusercontent.com/stxvysh-code/ClaudeCode/HEAD/boot.sh | bash
#
#  Скрипт скачает установщик целиком и запустит его. Журнал установки:
#  /root/arch-forest-install.log
# ============================================================================
set -uo pipefail

REPO="${ARCH_FOREST_REPO:-stxvysh-code/ClaudeCode}"
REF="${ARCH_FOREST_REF:-HEAD}"
DIR=/root/arch-forest
LOG=/root/arch-forest-install.log

# Шрифт с кириллицей, иначе вместо русских букв будут квадраты
setfont ter-v22b 2>/dev/null || setfont cyr-sun16 2>/dev/null || true

echo
echo "==> Скачиваю установщик arch-forest ($REPO)..."
ok=0
for url in "https://github.com/$REPO/archive/$REF.tar.gz" \
           "https://codeload.github.com/$REPO/tar.gz/$REF"; do
    for attempt in 1 2 3; do
        rm -rf "$DIR"; mkdir -p "$DIR"
        if curl -fsSL --connect-timeout 20 --retry 2 "$url" | tar -xz -C "$DIR" --strip-components=1 2>/dev/null &&
           [[ -f "$DIR/install.sh" ]]; then
            ok=1; break 2
        fi
        echo "    попытка $attempt не удалась, пробую ещё..."
        sleep 3
    done
done

if [[ $ok != 1 ]]; then
    echo
    echo "!! Не удалось скачать установщик."
    echo "   1) Проверь интернет:  ping -c 3 archlinux.org"
    echo "   2) Репозиторий $REPO должен быть ПУБЛИЧНЫМ (Settings → Danger Zone → Change visibility)."
    exit 1
fi

chmod +x "$DIR/install.sh"
echo "==> Запускаю установку..."
sleep 1
# script — пишет всё, что видно на экране, в журнал (и сохраняет полосы прогресса)
exec script -q -e -f -a -c "bash $DIR/install.sh" "$LOG" < /dev/tty
