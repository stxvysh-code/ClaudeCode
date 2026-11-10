#!/usr/bin/env bash
# ============================================================================
#  arch-forest — первый вход в KDE Plasma (этап 2). Запускается автоматически
#  один раз: применяет оформление, панели, обои, частоту монитора и т.д.
#  Можно запустить повторно вручную:  /opt/arch-forest/firstboot.sh --force
# ============================================================================
set -u

STATE_DIR="$HOME/.local/state/arch-forest"
DONE="$STATE_DIR/firstboot.done"
LOG="$STATE_DIR/firstboot.log"
AUTOSTART="$HOME/.config/autostart/arch-forest-firstboot.desktop"
LNF=org.archforest.desktop
WALLPAPER=/usr/share/wallpapers/Path

mkdir -p "$STATE_DIR"
exec >>"$LOG" 2>&1
echo "===== $(date '+%F %T') firstboot $*"

if [[ -f "$DONE" && "${1:-}" != "--force" ]]; then
    echo "уже выполнено"; rm -f "$AUTOSTART"; exit 0
fi

QDBUS=$(command -v qdbus6 || command -v qdbus || echo qdbus6)
notify() { notify-send -a "arch-forest" -i "${3:-preferences-desktop-theme}" "$1" "$2" 2>/dev/null || true; }

# 1. Ждём, пока Plasma полностью запустится
for _ in $(seq 1 120); do
    "$QDBUS" org.kde.plasmashell /PlasmaShell >/dev/null 2>&1 && break
    sleep 1
done
sleep 4
notify "Настраиваю оформление" "Пара секунд — экран может моргнуть, это нормально 🌲"

# 2. Иконки: Colloid, если установились, иначе Papirus
ICONS=Colloid-Green-Everforest-Dark
if [[ ! -d /usr/share/icons/$ICONS ]]; then
    ICONS=Papirus-Dark
    [[ -d /usr/share/icons/$ICONS ]] || ICONS=breeze-dark
fi

# 3. Глобальная тема «Лесная ночь»: цвета, Kvantum, иконки, курсор, панели, виджеты
if ! plasma-apply-lookandfeel --apply "$LNF" --resetLayout; then
    echo "!! plasma-apply-lookandfeel не сработал — применяю по частям"
fi
sleep 2

# Подстраховка по отдельным компонентам (на случай, если что-то не применилось)
plasma-apply-colorscheme Forest || true
kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle kvantum
kwriteconfig6 --file kdeglobals --group Icons --key Theme "$ICONS"
[[ -x /usr/lib/plasma-changeicons ]] && /usr/lib/plasma-changeicons "$ICONS" || true
if [[ -d /usr/share/icons/Bibata-Modern-Classic ]]; then
    plasma-apply-cursortheme Bibata-Modern-Classic || true
fi
plasma-apply-wallpaperimage "$WALLPAPER" || true

# Экран блокировки — те же обои
kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General \
    --key Image "file://$WALLPAPER/"
kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General \
    --key PreviewImage "file://$WALLPAPER/"

# 4. Максимальная частота обновления монитора (например 60 → 75 Гц)
if command -v kscreen-doctor >/dev/null && command -v jq >/dev/null; then
    kscreen-doctor -j 2>/dev/null | jq -r '
        .outputs[] | select(.connected and .enabled) | . as $o
        | ([$o.modes[] | select(.id == $o.currentModeId)] | first) as $cur
        | select($cur != null)
        | ([$o.modes[] | select(.size.width == $cur.size.width and .size.height == $cur.size.height)]
           | max_by(.refreshRate)) as $best
        | select($best.refreshRate > ($cur.refreshRate + 0.5))
        | "\($o.name) \($best.id) \($best.refreshRate)"' 2>/dev/null |
    while read -r out mode hz; do
        echo "монитор $out: режим $mode (${hz} Гц)"
        kscreen-doctor "output.$out.mode.$mode" || true
    done
fi

# 5. Браузер по умолчанию — Vivaldi
xdg-settings set default-web-browser vivaldi-stable.desktop 2>/dev/null || true

# 6. Значок обновлений в трее (arch-update) + проверка обновлений каждые 6 часов
if command -v arch-update >/dev/null; then
    arch-update --tray --enable || true
    arch-update --check --enable || true
fi

# 7. Применить настройки окон (размытие, эффекты, тайлинг)
"$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
"$QDBUS" org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1 || true

# 8. Готово — больше не запускаемся
touch "$DONE"
rm -f "$AUTOSTART"
echo "===== готово"

notify "Готово! Добро пожаловать в Arch 🌲" \
    "Меню — кнопка Arch слева вверху (или клавиша Win). Тайлинг: Win+Shift+T. Обновление: значок в трее." \
    "start-here"
