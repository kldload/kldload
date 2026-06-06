# kldload-help-banner — one-line nudge on shell login.
#
# Print only on interactive shells, only once per session, only when stdout
# is a real TTY. Skips noisy contexts (scripts, scp, rsync) so it never
# breaks automation. Output is two lines + blank line so it doesn't bury
# the prompt.

# Interactive guard
case $- in
*i*) ;;
*) return 0 ;;
esac

# TTY guard (skip for piped logins, sftp, etc.)
[[ -t 1 ]] || return 0

# Once-per-session guard
[[ -n "${KLDLOAD_BANNER_SHOWN:-}" ]] && return 0
export KLDLOAD_BANNER_SHOWN=1

# Skip inside the kldload-mgmt console (which already prints help itself)
[[ -n "${KLDLOAD_MGMT_CONSOLE:-}" ]] && return 0

# Skip on the live ISO if the user is `live` and was auto-logged-in — the
# live env already drops a GNOME session with the webui open; a CLI banner
# is noise there.
if [[ "$USER" == "live" ]] && [[ -n "${XDG_SESSION_TYPE:-}" ]]; then
    return 0
fi

# Pick colors only if TERM looks capable.
if [[ "${TERM:-}" == xterm* ]] || [[ "${TERM:-}" == screen* ]] ||
    [[ "${TERM:-}" == tmux* ]] || [[ "${TERM:-}" == *-256color ]]; then
    _kld_c=$'\e[38;5;117m'
    _kld_g=$'\e[38;5;85m'
    _kld_d=$'\e[38;5;240m'
    _kld_n=$'\e[0m'
else
    _kld_c= _kld_g= _kld_d= _kld_n=
fi

printf '\n  %skldload%s — type %skldload-help%s (or %shelp%s in the mgmt console) for the operator catalog.\n' \
    "$_kld_g" "$_kld_n" "$_kld_c" "$_kld_n" "$_kld_c" "$_kld_n"
printf '  %sWeb UI:%s https://$(hostname -I | awk %s{print %s1}%s):8443/   %sk9s tab:%s open the terminal in the browser for the full management console\n\n' \
    "$_kld_d" "$_kld_n" "'" '$' "'" "$_kld_d" "$_kld_n"

unset _kld_c _kld_g _kld_d _kld_n
