#!/usr/bin/env bash
# ============================================================================
#  arch-forest — установщик Arch Linux + KDE Plasma (этап 1, с флешки)
#
#  Запускается из live-образа Arch Linux (обычно через boot.sh):
#     curl -sL https://raw.githubusercontent.com/stxvysh-code/ClaudeCode/HEAD/boot.sh | bash
#
#  Что делает: задаёт пару вопросов → размечает диски → ставит систему,
#  драйверы, KDE Plasma, программы и игры → настраивает загрузчик, снимки,
#  оформление. Дальше всё доделается само при первом входе в систему.
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TARGET=/mnt
LOG_FILE="${ARCH_FOREST_LOG:-/root/arch-forest-install.log}"
LOG_HINT="$LOG_FILE"
STEP_TOTAL=9
TEST_MODE="${ARCH_FOREST_TEST:-0}"   # 1 = тестовый прогон (без проверки live-образа/UEFI)

on_error() {
    local code=$? line=${1:-?}
    err "Установка остановилась на шаге: ${CURRENT_STEP:-подготовка} (строка ${line}, код ${code})."
    echo "${C_YELLOW}  Ничего страшного: просто запусти установку ещё раз той же командой."
    echo "  Если ошибка повторяется — сфотографируй экран и журнал: ${LOG_FILE}${C_RESET}"
}
trap 'on_error $LINENO' ERR

cleanup_secrets() { rm -f "$TARGET/root/.arch-forest-pass" 2>/dev/null || true; }
trap cleanup_secrets EXIT

# ----------------------------------------------------------------------------
# Вспомогательные функции для дисков
# ----------------------------------------------------------------------------
# Имя раздела: /dev/sda + 1 -> /dev/sda1 ; /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
part_name() {
    local disk=$1 num=$2
    if [[ "$disk" =~ [0-9]$ ]]; then echo "${disk}p${num}"; else echo "${disk}${num}"; fi
}

# Диск, с которого загружен live-образ (его трогать нельзя)
iso_disk() {
    local src
    src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
    [[ -n "$src" ]] || return 0
    lsblk -npdo PKNAME "$src" 2>/dev/null || true
}

disk_desc() {
    local d=$1
    local size model rota tran
    size=$(lsblk -dno SIZE "$d" | xargs)
    model=$(lsblk -dno MODEL "$d" | xargs)
    rota=$(lsblk -dno ROTA "$d" | xargs)
    tran=$(lsblk -dno TRAN "$d" | xargs)
    local kind="SSD"; [[ "$rota" == "1" ]] && kind="HDD"
    [[ "$tran" == "nvme" ]] && kind="NVMe SSD"
    echo "$d  ${size}  ${kind}  ${model:-без названия}"
}

disk_size_gb() { echo $(( $(lsblk -bdno SIZE "$1") / 1024 / 1024 / 1024 )); }

# ----------------------------------------------------------------------------
preflight() {
    step "Проверка компьютера и интернета"
    [[ $EUID -eq 0 ]] || die "Запусти от root (в live-образе ты и так root)."

    if [[ "$TEST_MODE" != "1" ]]; then
        [[ -d /run/archiso ]] || die "Этот скрипт запускается только с установочной флешки Arch Linux."
        [[ -d /sys/firmware/efi/efivars ]] || die "Компьютер загружен НЕ в режиме UEFI. В BIOS выбери загрузку флешки с пометкой «UEFI:»."
        ok "Режим загрузки: UEFI"
    fi

    # Крупный шрифт с кириллицей для экрана установщика
    setfont ter-v22b 2>/dev/null || setfont cyr-sun16 2>/dev/null || true

    info "Проверяю интернет..."
    local i
    for i in $(seq 1 30); do
        if curl -fsS --max-time 5 -o /dev/null https://archlinux.org 2>/dev/null; then break; fi
        sleep 2
        if (( i == 30 )); then
            die "Нет интернета. Проверь, что кабель подключён к компьютеру и роутеру, и запусти установку снова."
        fi
    done
    ok "Интернет есть"

    if [[ "$TEST_MODE" != "1" ]]; then
        timedatectl set-ntp true 2>/dev/null || true
        info "Синхронизирую часы..."
        for i in $(seq 1 30); do
            [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && break
            sleep 2
        done
        info "Жду готовности ключей pacman..."
        for i in $(seq 1 90); do
            systemctl is-active --quiet pacman-init.service && break
            sleep 2
        done
    fi
    ok "Подготовка завершена"
}

# ----------------------------------------------------------------------------
ask_user() {
    step "Пара вопросов (дальше всё будет автоматически)"

    if [[ -n "${ARCH_FOREST_PASS:-}" ]]; then        # только для автоматических тестов
        USERNAME=$DEFAULT_USERNAME; HOSTNAME_NEW=$DEFAULT_HOSTNAME; USER_PASS=$ARCH_FOREST_PASS
        return 0
    fi
    [[ -t 0 ]] || die "Нет доступа к клавиатуре. Запускай так: curl -sL <адрес>/boot.sh | bash"

    echo
    echo "  Имя пользователя: только маленькие латинские буквы, цифры, '-' и '_'."
    while true; do
        USERNAME=$(ask "Имя пользователя" "$DEFAULT_USERNAME")
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$USERNAME" != "root" ]]; then break; fi
        warn "Так нельзя. Пример правильного имени: styx"
    done

    while true; do
        HOSTNAME_NEW=$(ask "Имя компьютера" "$DEFAULT_HOSTNAME")
        if [[ "$HOSTNAME_NEW" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]; then break; fi
        warn "Только латиница, цифры и дефис. Пример: styx-pc"
    done

    echo
    echo "  Пароль понадобится для установки программ и настроек (вход будет без пароля)."
    echo "  ${C_YELLOW}Пиши его ЛАТИНИЦЕЙ (английская раскладка) и запомни!${C_RESET}"
    echo "  При вводе символы не отображаются — это нормально."
    while true; do
        read -r -s -p "${C_BOLD}Придумай пароль${C_RESET}: " USER_PASS; echo
        read -r -s -p "${C_BOLD}Повтори пароль${C_RESET}: " USER_PASS2; echo
        if [[ -z "$USER_PASS" ]]; then warn "Пароль не может быть пустым."; continue; fi
        if [[ "$USER_PASS" != "$USER_PASS2" ]]; then warn "Пароли не совпали, попробуй ещё раз."; continue; fi
        if [[ "$USER_PASS" == *:* || "$USER_PASS" =~ [^[:print:]] ]]; then
            warn "Не используй двоеточие ':' и нестандартные символы."; continue
        fi
        break
    done
    unset USER_PASS2
}

# ----------------------------------------------------------------------------
choose_disks() {
    step "Выбор дисков"
    local skip_disk
    skip_disk=$(iso_disk)

    mapfile -t ALL_DISKS < <(lsblk -dpno NAME,TYPE,TRAN,RO | awk '$2=="disk" && $NF=="0" {print $1" "$3}' |
        while read -r name tran; do
            [[ "$name" == "$skip_disk" ]] && continue
            [[ "$tran" == "usb" ]] && continue
            [[ "$name" =~ ^/dev/(loop|sr|zram|fd) ]] && continue
            echo "$name"
        done)

    if [[ -n "${ARCH_FOREST_SYS_DISK:-}" ]]; then   # для тестов
        SYS_DISK=$ARCH_FOREST_SYS_DISK; DATA_DISK=${ARCH_FOREST_DATA_DISK:-}
    else
        (( ${#ALL_DISKS[@]} > 0 )) || die "Не нашёл ни одного внутреннего диска."

        # Предложение по умолчанию: SSD — под систему, HDD — под данные
        SYS_DISK=""; DATA_DISK=""
        local d
        for d in "${ALL_DISKS[@]}"; do
            [[ "$(lsblk -dno ROTA "$d" | xargs)" == "0" && -z "$SYS_DISK" ]] && SYS_DISK=$d
        done
        [[ -n "$SYS_DISK" ]] || SYS_DISK=${ALL_DISKS[0]}
        for d in "${ALL_DISKS[@]}"; do
            [[ "$d" != "$SYS_DISK" && "$(lsblk -dno ROTA "$d" | xargs)" == "1" && -z "$DATA_DISK" ]] && DATA_DISK=$d
        done

        echo
        echo "  Найдены диски:"
        local i=1
        for d in "${ALL_DISKS[@]}"; do echo "    $i) $(disk_desc "$d")"; i=$((i + 1)); done
        echo
        echo "  Предлагаю так:"
        echo "    ${C_BOLD}Система (Arch Linux):${C_RESET} $(disk_desc "$SYS_DISK")"
        if [[ -n "$DATA_DISK" ]]; then
            echo "    ${C_BOLD}Игры и файлы (HDD):${C_RESET}   $(disk_desc "$DATA_DISK")"
        else
            echo "    ${C_BOLD}Второй диск:${C_RESET} не используется"
        fi
        echo
        local ans
        ans=$(ask "Всё верно? (y = да, n = выбрать вручную)" "y")
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            local n
            while true; do
                n=$(ask "Номер диска для СИСТЕМЫ" "1")
                [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#ALL_DISKS[@]} )) && break
                warn "Введи номер из списка."
            done
            SYS_DISK=${ALL_DISKS[$((n - 1))]}
            DATA_DISK=""
            while true; do
                n=$(ask "Номер диска для ИГР/ФАЙЛОВ (0 = не использовать)" "0")
                if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n > ${#ALL_DISKS[@]} )); then
                    warn "Введи номер из списка."; continue
                fi
                if (( n == 0 )); then break; fi
                if [[ "${ALL_DISKS[$((n - 1))]}" == "$SYS_DISK" ]]; then warn "Это уже системный диск."; continue; fi
                DATA_DISK=${ALL_DISKS[$((n - 1))]}; break
            done
        fi
    fi

    (( $(disk_size_gb "$SYS_DISK") >= 60 )) || die "Системный диск слишком маленький (нужно от 60 ГБ)."

    echo
    echo "${C_RED}${C_BOLD}  ВНИМАНИЕ! ВСЕ ДАННЫЕ НА ЭТИХ ДИСКАХ БУДУТ УДАЛЕНЫ НАВСЕГДА:${C_RESET}"
    echo "${C_RED}    - $(disk_desc "$SYS_DISK")${C_RESET}"
    [[ -n "$DATA_DISK" ]] && echo "${C_RED}    - $(disk_desc "$DATA_DISK")${C_RESET}"
    echo "  Windows и все файлы на них исчезнут."
    echo
    if [[ -z "${ARCH_FOREST_YES:-}" ]]; then
        confirm_word "Чтобы продолжить, напиши YES большими буквами:" "YES" || die "Отменено. Диски не тронуты."
    fi

    echo
    echo "  ${C_GREEN}Дальше всё идёт автоматически, примерно 20–60 минут (зависит от интернета).${C_RESET}"
    echo "  Можно отойти. Если по пути что-то пойдёт не так, на экране будет понятное сообщение."
    sleep 3
}

# ----------------------------------------------------------------------------
setup_mirrors() {
    step "Ищу быстрые зеркала для скачивания"
    # multilib (32-битные библиотеки для Steam/Wine) + параллельная загрузка
    sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/[multilib]\nInclude/}' /etc/pacman.conf
    if grep -q '^#\?ParallelDownloads' /etc/pacman.conf; then
        sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
    else
        sed -i '/^\[options\]/a ParallelDownloads = 8' /etc/pacman.conf
    fi

    local tmp=/tmp/mirrorlist.new
    if [[ -n "${ARCH_FOREST_SKIP_REFLECTOR:-}" ]]; then      # только для тестов
        cp /etc/pacman.d/mirrorlist "$tmp"
    elif timeout 120 reflector --country "$MIRROR_COUNTRIES" --protocol https --age 24 \
            --fastest 6 --download-timeout 5 --save "$tmp" 2>/dev/null &&
            grep -q '^Server' "$tmp"; then
        ok "Нашёл быстрые зеркала"
    else
        warn "reflector не справился — беру проверенный список зеркал"
        : > "$tmp"
    fi
    cat >> "$tmp" <<'EOF'

## Запасные зеркала (arch-forest)
Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch
Server = https://repository.su/archlinux/$repo/os/$arch
Server = https://mirror.truenetwork.ru/archlinux/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://frankfurt.mirror.pkgbuild.com/$repo/os/$arch
EOF
    cp "$tmp" /etc/pacman.d/mirrorlist
    grep '^Server' /etc/pacman.d/mirrorlist | head -3 | sed 's/^/     /'

    info "Обновляю ключи подписи пакетов..."
    retry 3 pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null
    ok "Зеркала готовы"
}

# ----------------------------------------------------------------------------
partition_disks() {
    step "Разметка дисков"
    # На случай повторного запуска: отмонтировать всё старое
    umount -R "$TARGET" 2>/dev/null || true
    swapoff -a 2>/dev/null || true

    local d p
    for d in "$SYS_DISK" ${DATA_DISK:+"$DATA_DISK"}; do
        for p in $(lsblk -lnpo NAME "$d" | tail -n +2); do umount -q "$p" 2>/dev/null || true; done
    done

    info "Очищаю системный диск $SYS_DISK"
    wipefs -af "$SYS_DISK" >/dev/null
    sgdisk --zap-all "$SYS_DISK" >/dev/null
    if [[ "$(lsblk -dno ROTA "$SYS_DISK" | xargs)" == "0" ]]; then
        blkdiscard -f "$SYS_DISK" >/dev/null 2>&1 || true   # TRIM всего SSD — как новый
    fi
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI \
           -n 2:0:0   -t 2:8300 -c 2:ARCH "$SYS_DISK" >/dev/null
    partprobe "$SYS_DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    ESP=$(part_name "$SYS_DISK" 1)
    ROOT_PART=$(part_name "$SYS_DISK" 2)
    for _ in $(seq 1 10); do [[ -b "$ROOT_PART" ]] && break; sleep 1; done
    [[ -b "$ROOT_PART" ]] || die "Раздел $ROOT_PART не появился."

    wipefs -af "$ESP" "$ROOT_PART" >/dev/null
    mkfs.fat -F 32 -n EFI "$ESP" >/dev/null
    mkfs.btrfs -f -L ARCH "$ROOT_PART" >/dev/null
    ok "Системный диск: EFI 1 ГБ + Btrfs (остальное)"

    if [[ -n "$DATA_DISK" ]]; then
        info "Очищаю второй диск $DATA_DISK"
        wipefs -af "$DATA_DISK" >/dev/null
        sgdisk --zap-all "$DATA_DISK" >/dev/null
        sgdisk -n 1:0:0 -t 1:8300 -c 1:"$DATA_LABEL" "$DATA_DISK" >/dev/null
        partprobe "$DATA_DISK" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        DATA_PART=$(part_name "$DATA_DISK" 1)
        for _ in $(seq 1 10); do [[ -b "$DATA_PART" ]] && break; sleep 1; done
        [[ -b "$DATA_PART" ]] || die "Раздел $DATA_PART не появился."
        wipefs -af "$DATA_PART" >/dev/null
        mkfs.ext4 -F -q -L "$DATA_LABEL" -m 1 "$DATA_PART"
        ok "Второй диск: ext4 «$DATA_LABEL» (будет в $DATA_MOUNT)"
    fi

    info "Создаю подтома Btrfs (для снимков системы)"
    mount "$ROOT_PART" "$TARGET"
    local sv
    for sv in @ @home @snapshots @var_log @pkg; do
        btrfs subvolume create "$TARGET/$sv" >/dev/null
    done
    umount "$TARGET"

    local o="noatime,compress=zstd:1"
    mount -o "$o,subvol=@" "$ROOT_PART" "$TARGET"
    mkdir -p "$TARGET"/{efi,home,.snapshots,var/log,var/cache/pacman/pkg}
    mount -o "$o,subvol=@home"      "$ROOT_PART" "$TARGET/home"
    mount -o "$o,subvol=@snapshots" "$ROOT_PART" "$TARGET/.snapshots"
    mount -o "$o,subvol=@var_log"   "$ROOT_PART" "$TARGET/var/log"
    mount -o "$o,subvol=@pkg"       "$ROOT_PART" "$TARGET/var/cache/pacman/pkg"
    if [[ "$TEST_MODE" == "1" ]] && ! grep -qw vfat /proc/filesystems; then
        warn "ТЕСТ: ядро без поддержки FAT — вместо EFI-раздела временная папка"
        mount -t tmpfs tmpfs "$TARGET/efi"
    else
        mount -o fmask=0077,dmask=0077 "$ESP" "$TARGET/efi"
    fi
    if [[ -n "$DATA_DISK" ]]; then
        mkdir -p "$TARGET$DATA_MOUNT"
        mount -o noatime "$DATA_PART" "$TARGET$DATA_MOUNT"
    fi
    ok "Диски размечены и подключены"
}

# ----------------------------------------------------------------------------
install_base() {
    step "Установка системы, KDE Plasma, драйверов и программ (самый долгий шаг)"
    local pkgs
    mapfile -t pkgs < <(echo "$KERNEL"; read_pkg_list \
        "$SCRIPT_DIR/packages/base.txt" "$SCRIPT_DIR/packages/desktop.txt" \
        "$SCRIPT_DIR/packages/apps.txt" "$SCRIPT_DIR/packages/gaming.txt")
    info "Пакетов в списке: ${#pkgs[@]} (вместе с зависимостями ~950, ~3 ГБ)"
    retry 3 pacstrap -K "$TARGET" "${pkgs[@]}"
    if [[ -n "${ARCH_FOREST_TEST_CA:-}" ]]; then              # только для тестов (прокси с своим сертификатом)
        cp "$ARCH_FOREST_TEST_CA" "$TARGET/etc/ca-certificates/trust-source/anchors/arch-forest-test.crt"
        arch-chroot "$TARGET" update-ca-trust
    fi
    ok "Основные пакеты установлены"
}

# ----------------------------------------------------------------------------
write_fstab() {
    step "Таблица дисков (fstab)"
    genfstab -U "$TARGET" > "$TARGET/etc/fstab"
    if [[ "$TEST_MODE" == "1" ]] && grep -qE '^tmpfs[[:space:]]+/efi[[:space:]]' "$TARGET/etc/fstab"; then
        sed -i -E '\#^tmpfs[[:space:]]+/efi[[:space:]]#d' "$TARGET/etc/fstab"
        echo "UUID=$(blkid -s UUID -o value "$ESP") /efi vfat rw,fmask=0077,dmask=0077 0 2" >> "$TARGET/etc/fstab"
    fi
    # subvolid мешает откату снимков — убираем, оставляем только subvol=
    sed -i -E 's/,?subvolid=[0-9]+//' "$TARGET/etc/fstab"
    if [[ -n "${DATA_DISK:-}" ]]; then
        # nofail: система загрузится, даже если HDD однажды сломается
        sed -i -E "\\#[[:space:]]${DATA_MOUNT}[[:space:]]# s#(ext4[[:space:]]+)([^[:space:]]+)#\\1\\2,nofail,x-systemd.device-timeout=10s#" "$TARGET/etc/fstab"
    fi
    grep -v '^#' "$TARGET/etc/fstab" | sed '/^$/d' | sed 's/^/     /'
    grep -qE '^UUID=[^[:space:]]+[[:space:]]+/[[:space:]]+btrfs[[:space:]]+[^[:space:]]*subvol=/@([[:space:],]|$)' "$TARGET/etc/fstab" ||
        die "fstab выглядит неправильно (нет корневого подтома)."
    ok "fstab готов"
}

# ----------------------------------------------------------------------------
configure_system() {
    step "Настройка системы, загрузчика, оформления, AUR и Flatpak"
    rm -rf "$TARGET/opt/arch-forest"
    mkdir -p "$TARGET/opt/arch-forest"
    cp -a "$SCRIPT_DIR/." "$TARGET/opt/arch-forest/"
    rm -rf "$TARGET/opt/arch-forest/.git"

    # Пароль передаём через временный файл (только для root, удаляется сразу)
    install -m 600 /dev/null "$TARGET/root/.arch-forest-pass"
    printf '%s' "$USER_PASS" > "$TARGET/root/.arch-forest-pass"
    unset USER_PASS

    arch-chroot "$TARGET" /usr/bin/env \
        AF_USERNAME="$USERNAME" AF_HOSTNAME="$HOSTNAME_NEW" \
        AF_DATA_DISK="${DATA_DISK:+yes}" AF_TEST_MODE="$TEST_MODE" \
        bash /opt/arch-forest/lib/chroot-setup.sh
    ok "Система настроена"
}

# ----------------------------------------------------------------------------
finish() {
    step "Завершение"
    mkdir -p "$TARGET/var/log/arch-forest"
    cp -f "$LOG_FILE" "$TARGET/var/log/arch-forest/install.log" 2>/dev/null || true
    sync
    local failed="$TARGET/var/log/arch-forest/failed.txt"
    if [[ -s "$failed" ]]; then
        warn "Не всё поставилось автоматически (поставишь потом одной командой, см. README):"
        sed 's/^/       /' "$failed"
    fi
    if [[ "$TEST_MODE" == "1" ]]; then
        ok "Тестовый прогон завершён (диски остаются смонтированными в $TARGET)."
        return 0
    fi
    umount -R "$TARGET" || warn "Не всё отмонтировалось — не страшно."
    echo
    echo "${C_GREEN}${C_BOLD}  ✔ Установка завершена!${C_RESET}"
    echo
    echo "  1. Вынь флешку."
    echo "  2. Нажми Enter — компьютер перезагрузится."
    echo "  3. Система загрузится и сама войдёт в KDE Plasma. Первые ~30 секунд"
    echo "     она доводит оформление — просто подожди уведомления «Готово»."
    echo
    read -r -p "  Нажми Enter для перезагрузки..." _ || true
    reboot
}

# ----------------------------------------------------------------------------
main() {
    echo "${C_BOLD}${C_GREEN}"
    echo "   ┌──────────────────────────────────────────────┐"
    echo "   │   arch-forest · Arch Linux + KDE Plasma 6    │"
    echo "   └──────────────────────────────────────────────┘${C_RESET}"
    preflight
    ask_user
    choose_disks
    setup_mirrors
    partition_disks
    install_base
    write_fstab
    configure_system
    finish
}

main "$@"
