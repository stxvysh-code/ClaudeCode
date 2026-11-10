# ~/.zshrc — arch-forest
# ---------------------------------------------------------------------------
# История команд
HISTFILE=~/.zsh_history
HISTSIZE=20000
SAVEHIST=20000
setopt HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE SHARE_HISTORY
setopt AUTO_CD INTERACTIVE_COMMENTS NO_BEEP

# Умное автодополнение (Tab), без учёта регистра
[[ -d ~/.cache ]] || mkdir -p ~/.cache
autoload -Uz compinit && compinit -d ~/.cache/zcompdump
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# Привычные клавиши: Home/End/Delete, Ctrl+стрелки — по словам
bindkey -e
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word
bindkey '^H' backward-kill-word

# Подсказки из истории (серым) и подсветка команд
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#5c6a60'

# Удобные сокращения
alias ls='eza --icons=auto --group-directories-first'
alias ll='eza -l --icons=auto --group-directories-first --git'
alias la='eza -la --icons=auto --group-directories-first'
alias tree='eza --tree --icons=auto'
alias update='update-system'
alias cls='clear'
alias please='sudo $(fc -ln -1)'

# Красивая строка приглашения (в чёрной текстовой консоли — простая, там нет значков)
if [[ "$TERM" == "linux" ]]; then
    PROMPT='%F{green}%n@%m%f %F{cyan}%~%f %# '
else
    eval "$(starship init zsh)"
fi

# Информация о системе при открытии терминала
if [[ -o interactive && -z "${FASTFETCH_SHOWN:-}" && "$TERM" != "linux" ]]; then
    export FASTFETCH_SHOWN=1
    fastfetch
fi
