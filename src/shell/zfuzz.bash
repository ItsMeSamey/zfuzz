# zfuzz shell integration for bash
# Source this file after zfuzz is on PATH.

__zfuzz_file__() {
  local selected
  selected="$(command find . -type f -not -path '*/.git/*' 2>/dev/null | zfuzz --height=40% --reverse --query="${READLINE_LINE:0:READLINE_POINT}")" || return
  READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${selected}${READLINE_LINE:READLINE_POINT}"
  READLINE_POINT=$(( READLINE_POINT + ${#selected} ))
}

__zfuzz_history__() {
  local selected
  selected="$(builtin history | sed 's/^ *[0-9]\+ *//' | zfuzz --tac --height=40% --reverse)" || return
  READLINE_LINE="$selected"
  READLINE_POINT=${#READLINE_LINE}
}

__zfuzz_cd__() {
  local selected
  selected="$(command find . -type d -not -path '*/.git/*' 2>/dev/null | zfuzz --height=40% --reverse)" || return
  builtin cd -- "$selected"
  READLINE_LINE=
  READLINE_POINT=0
}

bind -x '"\C-t":__zfuzz_file__'
bind -x '"\C-r":__zfuzz_history__'
bind -x '"\ec":__zfuzz_cd__'
