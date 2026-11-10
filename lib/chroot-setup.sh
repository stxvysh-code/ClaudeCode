#!/usr/bin/env bash
# ============================================================================
#  arch-forest — настройка установленной системы (выполняется внутри arch-chroot)
#  Запускается автоматически из install.sh. Вручную запускать не нужно.
# ============================================================================
set -Eeuo pipefail

AF_DIR=/opt/arch-forest
# shellcheck source=config.sh disable=SC1091
source "$AF_DIR/config.sh"
# shellcheck source=lib/common.sh disable=SC1091
source "$AF_DIR/lib/common.sh"

USERNAME=${AF_USERNAME:?}
HOSTNAME_NEW=${AF_HOSTNAME:?}
HAS_DATA_DISK=${AF_DATA_DISK:-}
TEST_MODE=${AF_TEST_MODE:-0}
USER_HOME="/home/$USERNAME"
FAILED=/var/log/arch-forest/failed.txt
BUILD_SUDOERS=/etc/sudoers.d/99-arch-forest-build

mkdir -p /var/log/arch-forest
: > "$FAILED"
export SNAP_PAC_SKIP=y          # не делать снимки на каждый pacman во время установки

trap 'err "Ошибка в chroot-setup.sh (строка $LINENO): $BASH_COMMAND"' ERR
trap 'rm -f "$BUILD_SUDOERS" /root/.arch-forest-pass' EXIT

note_failed() { grep -qxF -- "$*" "$FAILED" 2>/dev/null || echo "$*" >> "$FAILED"; warn "Не получилось: $*"; }

# copy_tree SRC DST — копирует файлы по одному (права 644), не трогая права существующих папок
copy_tree() {
    local src=$1 dst=$2 f
    while IFS= read -r -d '' f; do
        install -D -m 644 "$src/$f" "$dst/$f"
    done < <(cd "$src" && find . -type f -printf '%P\0')
}

# ----------------------------------------------------------------------------
setup_basics() {
    info "Часовой пояс, язык, раскладка, имя компьютера"
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc 2>/dev/null || true

    local l esc
    for l in "${LOCALES[@]}"; do
        esc=${l//./\\.}
        sed -i "s/^#[[:space:]]*${esc} UTF-8/${l} UTF-8/" /etc/locale.gen
        grep -q "^${esc} UTF-8" /etc/locale.gen || echo "${l} UTF-8" >> /etc/locale.gen
    done
    locale-gen >/dev/null
    echo "LANG=$LANG_MAIN" > /etc/locale.conf

    printf 'KEYMAP=%s\nFONT=%s\n' "$CONSOLE_KEYMAP" "$CONSOLE_FONT" > /etc/vconsole.conf
    echo "$HOSTNAME_NEW" > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_NEW.localdomain $HOSTNAME_NEW
EOF

    # Раскладка для экрана входа (Plasma Login берёт её из настроек X11)
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$XKB_LAYOUTS"
        Option "XkbOptions" "$XKB_OPTIONS"
EndSection
EOF
}

# ----------------------------------------------------------------------------
setup_pacman() {
    info "Настройка pacman (32-бит для игр, цвет, параллельная загрузка)"
    sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/[multilib]\nInclude/}' /etc/pacman.conf
    sed -i 's/^#Color/Color/; s/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
    if grep -q '^#\?ParallelDownloads' /etc/pacman.conf; then
        sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
    fi
    grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
    grep -q '^\[multilib\]' /etc/pacman.conf || die "Не удалось включить multilib"
    retry 3 pacman -Sy --noconfirm >/dev/null
}

# ----------------------------------------------------------------------------
install_overlay_files() {
    info "Системные настройки (zram, звук, планировщик дисков, обновления GRUB)"
    copy_tree "$AF_DIR/files" ""
    chmod 755 /usr/local/bin/arch-forest-* /usr/local/bin/update-system

    # Чёткие шрифты: субпиксельное сглаживание
    local f
    for f in 10-sub-pixel-rgb.conf 11-lcdfilter-default.conf; do
        [[ -e /usr/share/fontconfig/conf.default/$f ]] && ln -sf "/usr/share/fontconfig/conf.default/$f" "/etc/fonts/conf.d/$f"
        [[ -e /usr/share/fontconfig/conf.avail/$f ]] && ln -sf "/usr/share/fontconfig/conf.avail/$f" "/etc/fonts/conf.d/$f"
    done
    return 0
}

# ----------------------------------------------------------------------------
setup_user() {
    info "Пользователь $USERNAME"
    if ! id "$USERNAME" &>/dev/null; then
        useradd -m -G wheel -s /bin/zsh -c "${USERNAME^}" "$USERNAME"
    fi

    local pass
    pass=$(cat /root/.arch-forest-pass)
    rm -f /root/.arch-forest-pass
    printf '%s:%s\n' "$USERNAME" "$pass" | chpasswd
    printf 'root:%s\n' "$pass" | chpasswd
    unset pass

    cat > /etc/sudoers.d/10-arch-forest <<'EOF'
# Пользователи группы wheel могут выполнять команды от администратора (sudo)
%wheel ALL=(ALL:ALL) ALL
# Показывать звёздочки при вводе пароля
Defaults pwfeedback
Defaults passwd_tries=5
EOF
    chmod 440 /etc/sudoers.d/10-arch-forest
    visudo -cf /etc/sudoers.d/10-arch-forest >/dev/null || die "Ошибка в sudoers"
}

# ----------------------------------------------------------------------------
setup_initramfs() {
    info "Заставка загрузки и initramfs"
    # bgrt = логотип материнской платы + аккуратный индикатор загрузки
    plymouth-set-default-theme bgrt 2>/dev/null || warn "Не удалось выбрать тему заставки"
    mkinitcpio -P
}

# ----------------------------------------------------------------------------
set_grub_var() {   # set_grub_var KEY VALUE  (в /etc/default/grub)
    local key=$1 val=$2
    if grep -qE "^#?[[:space:]]*${key}=" /etc/default/grub; then
        sed -i -E "s|^#?[[:space:]]*${key}=.*|${key}=${val}|" /etc/default/grub
    else
        echo "${key}=${val}" >> /etc/default/grub
    fi
}

# Генерация меню GRUB. Если не сработало только меню снимков (grub-btrfs) —
# создаём обычное меню, чтобы система гарантированно загружалась.
make_grub_cfg() {
    mkdir -p /boot/grub
    if grub-mkconfig -o /boot/grub/grub.cfg; then
        return 0
    fi
    warn "Меню снимков не сгенерировалось — создаю меню загрузки без него"
    chmod -x /etc/grub.d/41_snapshots-btrfs 2>/dev/null || true
    if ! grub-mkconfig -o /boot/grub/grub.cfg; then
        chmod +x /etc/grub.d/41_snapshots-btrfs 2>/dev/null || true
        return 1
    fi
    chmod +x /etc/grub.d/41_snapshots-btrfs 2>/dev/null || true
    note_failed "меню снимков GRUB: выполни  sudo grub-mkconfig -o /boot/grub/grub.cfg"
}

setup_bootloader() {
    info "Загрузчик GRUB с меню снимков системы"
    set_grub_var GRUB_DEFAULT 0
    set_grub_var GRUB_TIMEOUT 3
    set_grub_var GRUB_TIMEOUT_STYLE menu
    set_grub_var GRUB_DISTRIBUTOR '"Arch"'
    set_grub_var GRUB_CMDLINE_LINUX_DEFAULT '"loglevel=3 quiet splash zswap.enabled=0 nowatchdog modprobe.blacklist=sp5100_tco"'
    set_grub_var GRUB_GFXMODE '"1920x1080,auto"'
    set_grub_var GRUB_GFXPAYLOAD_LINUX keep
    set_grub_var GRUB_DISABLE_RECOVERY true
    set_grub_var GRUB_DISABLE_OS_PROBER true
    set_grub_var GRUB_DISABLE_BOOTNEXT true      # без лишних пунктов «(EFI BootNext)» от прошивки

    # Тема GRUB (шрифты генерируем из установленных TTF)
    local theme=/usr/share/grub/themes/forest
    rm -rf "$theme"; mkdir -p "$theme"
    cp -a "$AF_DIR/theme/grub/forest/." "$theme/"
    local reg=/usr/share/fonts/noto/NotoSans-Regular.ttf bold=/usr/share/fonts/noto/NotoSans-Bold.ttf
    local mono=/usr/share/fonts/TTF/DejaVuSansMono.ttf
    [[ -f $reg ]] || reg=/usr/share/fonts/TTF/DejaVuSans.ttf
    [[ -f $bold ]] || bold=/usr/share/fonts/TTF/DejaVuSans-Bold.ttf
    # -n задаёт семейство; полное имя = «семейство стиль размер», напр. «Forest Bold 22»
    if grub-mkfont -s 22 -n Forest -o "$theme/forest-regular-22.pf2" "$reg" 2>/dev/null &&
       grub-mkfont -s 18 -n Forest -o "$theme/forest-regular-18.pf2" "$reg" 2>/dev/null &&
       grub-mkfont -s 22 -n Forest -o "$theme/forest-bold-22.pf2" "$bold" 2>/dev/null &&
       grub-mkfont -s 18 -n "Forest Mono" -o "$theme/forest-mono-18.pf2" "$mono" 2>/dev/null; then
        set_grub_var GRUB_THEME "\"$theme/theme.txt\""
    else
        warn "Не удалось подготовить шрифты темы GRUB — будет стандартное меню"
    fi

    if [[ "$TEST_MODE" == "1" ]] && ! grep -qw vfat /proc/filesystems; then
        warn "ТЕСТ: нет FAT — пропускаю grub-install"
    else
        if [[ "$TEST_MODE" != "1" ]]; then
            grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB ||
                warn "Не удалось записать загрузочную запись в UEFI — будет работать запасной загрузчик"
        fi
        # Запасной загрузчик по стандартному пути EFI/BOOT/BOOTX64.EFI (на случай сброса BIOS)
        grub-install --target=x86_64-efi --efi-directory=/efi --removable
    fi
    make_grub_cfg
}

# ----------------------------------------------------------------------------
setup_snapper() {
    info "Снимки системы (snapper): автоматически до/после каждого обновления"
    install -d /etc/snapper/configs
    cp /usr/share/snapper/config-templates/default /etc/snapper/configs/root
    local cfg=/etc/snapper/configs/root kv k v
    for kv in 'SUBVOLUME="/"' 'FSTYPE="btrfs"' 'ALLOW_GROUPS="wheel"' 'SYNC_ACL="yes"' \
              'TIMELINE_CREATE="no"' 'TIMELINE_CLEANUP="yes"' 'NUMBER_CLEANUP="yes"' \
              'NUMBER_LIMIT="10"' 'NUMBER_LIMIT_IMPORTANT="5"' 'EMPTY_PRE_POST_CLEANUP="yes"'; do
        k=${kv%%=*}; v=${kv#*=}
        if grep -q "^${k}=" "$cfg"; then sed -i "s|^${k}=.*|${k}=${v}|" "$cfg"; else echo "${k}=${v}" >> "$cfg"; fi
    done
    if grep -q '^SNAPPER_CONFIGS=' /etc/conf.d/snapper; then
        sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' /etc/conf.d/snapper
    else
        echo 'SNAPPER_CONFIGS="root"' >> /etc/conf.d/snapper
    fi
    chown root:wheel /.snapshots
    chmod 750 /.snapshots
    snapper --no-dbus -c root list >/dev/null || die "snapper не работает"
}

# ----------------------------------------------------------------------------
setup_login() {
    info "Автоматический вход в KDE Plasma"
    mkdir -p /etc/plasmalogin.conf.d
    if [[ "$AUTOLOGIN" == "1" ]]; then
        cat > /etc/plasmalogin.conf.d/autologin.conf <<EOF
[Autologin]
User=$USERNAME
Session=plasma.desktop
EOF
    fi
}

# ----------------------------------------------------------------------------
setup_services() {
    info "Службы: сеть, вход, TRIM, снимки, очистка кэша, файрвол"
    sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
    systemctl enable NetworkManager.service plasmalogin.service systemd-timesyncd.service \
        fstrim.timer snapper-cleanup.timer grub-btrfsd.service paccache.timer ufw.service >/dev/null
    systemctl set-default graphical.target >/dev/null
}

# ----------------------------------------------------------------------------
install_flatpaks() {
    info "Программы из Flathub (офис, Bottles)"
    if ! retry 3 flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        note_failed "flatpak: не удалось подключить Flathub"
        return 0
    fi
    local app
    while read -r app; do
        [[ -n "$app" ]] || continue
        retry 3 flatpak install --system -y --noninteractive flathub "$app" >/dev/null ||
            note_failed "flatpak install flathub $app"
    done < <(read_pkg_list "$AF_DIR/packages/flatpak.txt")
}

# ----------------------------------------------------------------------------
as_user() {
    sudo -u "$USERNAME" -H env HOME="$USER_HOME" \
        ${https_proxy:+https_proxy="$https_proxy"} ${HTTPS_PROXY:+HTTPS_PROXY="$HTTPS_PROXY"} "$@"
}

install_aur() {
    info "Программы из AUR (Happ, Heroic, Proton-GE, курсор, arch-update)"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\nDefaults:%s env_keep += "https_proxy HTTPS_PROXY http_proxy HTTP_PROXY"\n' \
        "$USERNAME" "$USERNAME" > "$BUILD_SUDOERS"
    chmod 440 "$BUILD_SUDOERS"
    visudo -cf "$BUILD_SUDOERS" >/dev/null || { rm -f "$BUILD_SUDOERS"; note_failed "AUR: ошибка sudoers"; return 0; }

    if ! command -v paru >/dev/null; then
        local build="$USER_HOME/.cache/arch-forest-build"
        as_user mkdir -p "$build"
        clone_paru() {
            as_user rm -rf "$build/paru-bin"
            as_user git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$build/paru-bin"
        }
        if ! retry 3 clone_paru ||
           ! (cd "$build/paru-bin" && retry 2 as_user makepkg -si --noconfirm --needed); then
            note_failed "paru (помощник AUR) — все AUR-программы ставь вручную, см. README"
            rm -f "$BUILD_SUDOERS"
            return 0
        fi
    fi
    # Настройки paru: новости Arch перед обновлением, сборка снизу вверх
    sed -i 's/^#\?BottomUp/BottomUp/; s/^#\?NewsOnUpgrade/NewsOnUpgrade/; s/^#\?RemoveMake/RemoveMake/' /etc/paru.conf

    local pkg
    while read -r pkg; do
        [[ -n "$pkg" ]] || continue
        info "AUR: $pkg"
        retry 2 as_user paru -S --noconfirm --needed --skipreview --removemake "$pkg" ||
            note_failed "paru -S $pkg"
    done < <(read_pkg_list "$AF_DIR/packages/aur.txt")
    rm -rf "$USER_HOME/.cache/arch-forest-build" "$USER_HOME/.cache/paru/clone"
    rm -f "$BUILD_SUDOERS"
}

# ----------------------------------------------------------------------------
# Vision — официальный AppImage с сайта разработчика (ссылка всегда ведёт на последнюю
# версию). Лежит в ~/Applications, поэтому встроенное автообновление может его заменять.
install_vision() {
    info "Vision (антидетект-браузер, официальная сборка для Linux)"
    local dir="$USER_HOME/Applications" app="$USER_HOME/Applications/Vision.AppImage"
    install -d -o "$USERNAME" -g "$USERNAME" "$dir"
    if ! retry 3 curl -fL --connect-timeout 20 -o "$app.part" https://v1.empr.cloud/get/linux-appimage; then
        rm -f "$app.part"
        note_failed "Vision: скачай «Linux AppImage» с https://browser.vision/download и положи в ~/Applications"
        return 0
    fi
    mv -f "$app.part" "$app"
    chmod 755 "$app"

    # Значок достаём из AppImage как из архива (ничего не запуская)
    local off tmp=/tmp/vision-icon
    off=$(python3 -c 'import struct,sys
d=open(sys.argv[1],"rb").read(65536)
print(struct.unpack_from("<Q",d,0x28)[0]+struct.unpack_from("<H",d,0x3A)[0]*struct.unpack_from("<H",d,0x3C)[0])' "$app" 2>/dev/null || true)
    rm -rf "$tmp"
    if [[ -n "$off" ]] && unsquashfs -q -o "$off" -d "$tmp" "$app" \
            usr/share/icons/hicolor/128x128/apps/Vision.png >/dev/null 2>&1; then
        install -D -m 644 "$tmp/usr/share/icons/hicolor/128x128/apps/Vision.png" \
            "$USER_HOME/.local/share/icons/hicolor/128x128/apps/vision-browser.png"
    fi
    rm -rf "$tmp"

    mkdir -p "$USER_HOME/.local/share/applications"
    cat > "$USER_HOME/.local/share/applications/vision-browser.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Vision
Comment=Antidetect browser
Comment[ru]=Антидетект-браузер
Exec=$app %U
Icon=vision-browser
StartupWMClass=Vision
Categories=Network;WebBrowser;
Terminal=false
DESKTOP
    ok "Vision установлен"
}

# ----------------------------------------------------------------------------
install_theme_system() {
    info "Оформление: цвета, Kvantum, Konsole, глобальная тема"
    install -d /usr/share/color-schemes /usr/share/Kvantum /usr/share/konsole /usr/share/plasma/look-and-feel
    cp -a "$AF_DIR/theme/color-schemes/." /usr/share/color-schemes/
    rm -rf /usr/share/Kvantum/Forest
    cp -a "$AF_DIR/theme/kvantum/Forest" /usr/share/Kvantum/
    cp -a "$AF_DIR/theme/konsole/." /usr/share/konsole/
    rm -rf /usr/share/plasma/look-and-feel/org.archforest.desktop
    cp -a "$AF_DIR/theme/look-and-feel/org.archforest.desktop" /usr/share/plasma/look-and-feel/

    info "Тайлинг окон: Krohnkite 0.9.11 (KWin-скрипт, MIT)"
    rm -rf /usr/share/kwin/scripts/krohnkite
    install -d /usr/share/kwin/scripts/krohnkite
    bsdtar -xf "$AF_DIR/theme/kwin/krohnkite.kwinscript" -C /usr/share/kwin/scripts/krohnkite
    [[ -f /usr/share/kwin/scripts/krohnkite/metadata.json ]] || note_failed "Krohnkite (тайлинг)"

    info "Иконки Colloid (зелёные, Everforest)"
    local tmp=/tmp/colloid-icons
    rm -rf "$tmp"
    if retry 3 git clone --depth 1 --branch "$COLLOID_ICONS_TAG" https://github.com/vinceliuice/Colloid-icon-theme.git "$tmp" >/dev/null 2>&1 &&
       (cd "$tmp" && ./install.sh -d /usr/share/icons -s everforest -t green >/dev/null); then
        gtk-update-icon-cache -qf /usr/share/icons/Colloid-Green-Everforest-Dark 2>/dev/null || true
        ok "Иконки установлены"
    else
        note_failed "иконки Colloid (вместо них будут Papirus)"
        retry 3 pacman -S --noconfirm --needed papirus-icon-theme >/dev/null || true
    fi
    rm -rf "$tmp"
}

# ----------------------------------------------------------------------------
setup_user_home() {
    info "Личные настройки пользователя (панели, терминал, тайлинг, раскладки)"
    # Английские имена папок (надёжнее для игр и программ); в Dolphin подписи будут на русском
    local d
    for d in Desktop Documents Downloads Music Pictures Pictures/Screenshots Pictures/Wallpapers Videos Templates Public Projects; do
        install -d -o "$USERNAME" -g "$USERNAME" "$USER_HOME/$d"
    done

    copy_tree "$AF_DIR/home" "$USER_HOME"
    # Подстановки в конфигах
    local tiling=false icons=Colloid-Green-Everforest-Dark cursor=Bibata-Modern-Classic
    [[ "$TILING_ENABLED" == "1" ]] && tiling=true
    [[ -d /usr/share/icons/$icons ]] || icons=Papirus-Dark
    [[ -d /usr/share/icons/$icons ]] || icons=breeze-dark
    [[ -d /usr/share/icons/$cursor ]] || cursor=breeze_cursors
    { grep -rlZ '@USERNAME@\|@DATA_MOUNT@\|@TILING@\|@ICONS@\|@CURSOR@' "$USER_HOME/.config" "$USER_HOME/.local" 2>/dev/null || true; } |
        xargs -0 -r sed -i -e "s|@USERNAME@|$USERNAME|g" -e "s|@DATA_MOUNT@|$DATA_MOUNT|g" -e "s|@TILING@|$tiling|g" \
            -e "s|@ICONS@|$icons|g" -e "s|@CURSOR@|$cursor|g"
    # Цвета «Лесная ночь» сразу в kdeglobals — Plasma стартует уже в нужных цветах
    python3 "$AF_DIR/tools/merge-colors.py" /usr/share/color-schemes/Forest.colors "$USER_HOME/.config/kdeglobals" ||
        warn "Не удалось заранее прописать цвета (применятся при первом входе)"

    if [[ -n "$HAS_DATA_DISK" ]]; then
        install -d "$DATA_MOUNT"
        chown "$USERNAME:$USERNAME" "$DATA_MOUNT"
        install -d -o "$USERNAME" -g "$USERNAME" "$DATA_MOUNT/SteamLibrary" "$DATA_MOUNT/Games" \
            "$DATA_MOUNT/Videos" "$DATA_MOUNT/Torrents"
        ln -sfn "$DATA_MOUNT" "$USER_HOME/HDD"
    fi
    chown -R "$USERNAME:$USERNAME" "$USER_HOME"

    # GameMode (ускорение игр) требует группы gamemode. Добавляем ПОСЛЕ сборки AUR:
    # её лимит nice (pam_limits) не должен мешать sudo во время установки.
    # Группы audio/video не нужны — доступ к звуку и видео даёт logind.
    if getent group gamemode >/dev/null; then usermod -aG gamemode "$USERNAME"; fi
}

# ----------------------------------------------------------------------------
finalize() {
    info "Снимок «чистая система» (к нему всегда можно вернуться)"
    # Описание латиницей: GRUB показывает кириллицу из snapper как &#x...;
    snapper --no-dbus -c root create -t single -d "arch-forest clean install" --userdata important=yes || true
    make_grub_cfg >/dev/null 2>&1 || true

    info "Очистка кэша пакетов"
    paccache -rk0 >/dev/null 2>&1 || true
    pacman -Sc --noconfirm >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
main() {
    setup_basics
    setup_pacman
    install_overlay_files
    setup_user
    setup_initramfs
    setup_login
    setup_services
    install_theme_system
    # Сбой в программах из интернета (Flathub/AUR) НЕ должен останавливать установку:
    # записываем в список «поставить потом» и идём дальше
    install_flatpaks || note_failed "Flatpak: шаг завершился с ошибкой (см. журнал)"
    install_aur || note_failed "AUR: шаг завершился с ошибкой (см. журнал)"
    install_vision || note_failed "Vision: скачай с https://browser.vision/download"
    rm -f "$BUILD_SUDOERS"
    setup_user_home
    setup_snapper
    setup_bootloader
    finalize
    ok "Настройка внутри системы завершена"
}

main "$@"
