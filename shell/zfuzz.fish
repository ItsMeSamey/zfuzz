# zfuzz shell integration for fish
function __zfuzz_file
    set -l selected (command find . -type f -not -path '*/.git/*' 2>/dev/null | zfuzz --height=40% --reverse)
    or return
    commandline -i -- $selected
end

function __zfuzz_history
    set -l selected (builtin history | zfuzz --tac --height=40% --reverse)
    or return
    commandline -r -- $selected
end

function __zfuzz_cd
    set -l selected (command find . -type d -not -path '*/.git/*' 2>/dev/null | zfuzz --height=40% --reverse)
    or return
    cd -- $selected
    commandline -f repaint
end

bind \ct __zfuzz_file
bind \cr __zfuzz_history
bind \ec __zfuzz_cd
