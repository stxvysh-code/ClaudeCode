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
[[ "${1:-}" == "--force" ]] && rm -f "$STATE_DIR/attempts"

QDBUS=$(command -v qdbus6 || command -v qdbus || echo qdbus6)
notify() { notify-send -a "arch-forest" -i "${3:-preferences-desktop-theme}" "$1" "$2" 2>/dev/null || true; }

# 1. Ждём, пока Plasma полностью запустится
for _ in $(seq 1 120); do
    "$QDBUS" org.kde.plasmashell /PlasmaShell >/dev/null 2>&1 && break
    sleep 1
done
sleep 4

# 2. Оформление. Обычно оно уже на месте: установщик заранее прописал глобальную
#    тему «Лесная ночь», и Plasma при первом запуске сама создала наши панели,
#    виджеты и обои. Пересоздаём раскладку, только если её почему-то нет
#    (так безопаснее, чем пересобирать панели на работающем рабочем столе).
APPLETSRC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
if ! grep -q 'vivaldi-stable.desktop\|org.kde.dolphin.desktop' "$APPLETSRC" 2>/dev/null; then
    echo "раскладки нет — применяю глобальную тему с раскладкой"
    notify "Настраиваю оформление" "Пара секунд — экран может моргнуть, это нормально 🌲"
    plasma-apply-lookandfeel --apply "$LNF" --resetLayout || echo "!! plasma-apply-lookandfeel не сработал"
    sleep 3
fi

# Подстраховка по отдельным компонентам (каждая команда безопасна при повторе)
ICONS=Colloid-Green-Everforest-Dark
if [[ ! -d /usr/share/icons/$ICONS ]]; then
    ICONS=Papirus-Dark
    [[ -d /usr/share/icons/$ICONS ]] || ICONS=breeze-dark
fi
plasma-apply-colorscheme Forest || true
kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle kvantum
if [[ "$(kreadconfig6 --file kdeglobals --group Icons --key Theme)" != "$ICONS" ]]; then
    kwriteconfig6 --file kdeglobals --group Icons --key Theme "$ICONS"
    if [[ -x /usr/lib/plasma-changeicons ]]; then /usr/lib/plasma-changeicons "$ICONS" || true; fi
fi
if [[ -d /usr/share/icons/Bibata-Modern-Classic ]]; then
    plasma-apply-cursortheme Bibata-Modern-Classic || true
else
    plasma-apply-cursortheme breeze_cursors || true      # курсор Bibata не установился — стандартный
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

# 8. Проверяем, что оформление действительно применилось
applied=1
[[ "$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)" == "$LNF" ]] || applied=0
grep -q 'vivaldi-stable.desktop\|org.kde.dolphin.desktop' \
    "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null || applied=0

ATTEMPTS_FILE="$STATE_DIR/attempts"
attempts=$(( $(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$attempts" > "$ATTEMPTS_FILE"

if (( applied == 0 && attempts < 3 )); then
    echo "!! оформление применилось не полностью — повторю при следующем входе (попытка $attempts)"
    notify "Оформление применилось не полностью" \
        "Ничего страшного: выйди из системы и войди снова (или перезагрузись) — настройка повторится." \
        "dialog-warning"
    exit 0
fi

# 9. Готово — больше не запускаемся
touch "$DONE"
rm -f "$AUTOSTART"
echo "===== готово (попыток: $attempts, применено: $applied)"

if (( applied == 1 )); then
    notify "Готово! Добро пожаловать в Arch 🌲" \
        "Меню — кнопка Arch слева вверху (или клавиша Win). Тайлинг: Win+Shift+T. Обновление: значок в трее." \
        "start-here"
else
    notify "Оформление: не всё получилось" \
        "Запусти в терминале:  /opt/arch-forest/firstboot.sh --force  и перезайди в систему." \
        "dialog-warning"
fi
