# shellcheck shell=bash
# Общие функции для скриптов arch-forest (вывод, вопросы, повторы).

if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

STEP_NUM=0
STEP_TOTAL=${STEP_TOTAL:-0}

step() {
    STEP_NUM=$((STEP_NUM + 1))
    CURRENT_STEP="$*"
    echo
    if (( STEP_TOTAL > 0 )); then
        echo "${C_BOLD}${C_GREEN}==> [${STEP_NUM}/${STEP_TOTAL}] $*${C_RESET}"
    else
        echo "${C_BOLD}${C_GREEN}==> $*${C_RESET}"
    fi
}

info()  { echo "${C_CYAN}  ->${C_RESET} $*"; }
ok()    { echo "${C_GREEN}  ✔${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}  ⚠ $*${C_RESET}" >&2; }
err()   { echo "${C_RED}${C_BOLD}  ✖ $*${C_RESET}" >&2; }

die() {
    err "$*"
    if [[ -n "${LOG_HINT:-}" ]]; then
        echo "${C_YELLOW}  Подробности в журнале: ${LOG_HINT}${C_RESET}" >&2
    fi
    exit 1
}

# retry <попыток> <команда...> — повторяет команду при ошибке (сеть бывает нестабильной)
retry() {
    local tries=$1; shift
    local n=1 delay=3
    until "$@"; do
        if (( n >= tries )); then
            err "Команда не удалась после ${tries} попыток: $*"
            return 1
        fi
        warn "Не получилось (попытка ${n}/${tries}). Повторяю через ${delay} с..."
        sleep "$delay"
        n=$((n + 1)); delay=$((delay * 2))
    done
}

# ask "Вопрос" "значение по умолчанию" -> печатает ответ
ask() {
    local prompt=$1 default=${2:-} answer
    if [[ -n "$default" ]]; then
        read -r -p "${C_BOLD}${prompt}${C_RESET} [${default}]: " answer
        echo "${answer:-$default}"
    else
        read -r -p "${C_BOLD}${prompt}${C_RESET}: " answer
        echo "$answer"
    fi
}

# confirm_word "Текст" "СЛОВО" -> 0 если пользователь ввёл именно СЛОВО
confirm_word() {
    local prompt=$1 word=$2 answer
    read -r -p "${C_BOLD}${prompt}${C_RESET} " answer
    [[ "$answer" == "$word" ]]
}

# Без пустых строк и комментариев: выводит пакеты из файлов-списков
read_pkg_list() {
    local f
    for f in "$@"; do
        sed -e 's/#.*//' -e 's/[[:space:]]\+/\n/g' "$f" | sed '/^$/d'
    done
}
