# zfuzz shell integration for zsh
__zfuzz_file() {
  local selected
  selected=$(command find . -type f -not -path '*/.git/*' 2>/dev/null | zfuzz --height=40% --reverse) || return
  LBUFFER+=$selected
  zle redisplay
}
__zfuzz_history() {
  local selected
  selected=$(fc -rl 1 | sed 's/^ *[0-9]\+ *//' | zfuzz --tac --height=40% --reverse) || return
  BUFFER=$selected
  CURSOR=${#BUFFER}
  zle redisplay
}
__zfuzz_cd() {
  local selected
  selected=$(command find . -type d -not -path '*/.git/*' 2>/dev/null | zfuzz --height=40% --reverse) || return
  builtin cd -- "$selected"
  zle reset-prompt
}
zle -N __zfuzz_file
zle -N __zfuzz_history
zle -N __zfuzz_cd
bindkey '^T' __zfuzz_file
bindkey '^R' __zfuzz_history
bindkey '^[c' __zfuzz_cd
