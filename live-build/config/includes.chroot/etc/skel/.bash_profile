# kldload .bash_profile — login shells (e.g. kldload-term's `bash -l`) must
# source the interactive config so the terminal comes up with the FULL kldload
# environment: prompt, aliases, KUBECONFIG, greeting. Without this a login
# shell skips ~/.bashrc and the terminal is "just plain bash" (10.100.10.119,
# 2026-06-14).
[ -f ~/.bashrc ] && . ~/.bashrc

# user-local bins on PATH
PATH="$PATH:$HOME/.local/bin:$HOME/bin"
export PATH
