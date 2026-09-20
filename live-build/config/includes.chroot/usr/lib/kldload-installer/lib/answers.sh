#!/usr/bin/env bash
# Sourced by kldload-install-target — k_answers_load_env_file (--config mode), k_save_effective_config
set -Eeuo pipefail

# k_answers_load_env_file <file> — read an answers file into exported variables.
#
# Line by line, NOT sourced: the file comes off the network or a USB stick and is
# read as root before a disk wipe. The format is therefore narrower than shell:
#   KEY=value           one per line; surrounding "" or '' are stripped
#   # comment           a line whose first non-blank character is #
# A comment on the SAME line as a value is refused, not stripped. The value may
# legitimately contain a # (a password), so the loader cannot tell a comment from
# data; before 2026-09-13 it kept the comment as part of the value, and the shipped
# TEMPLATE.env loaded as KLDLOAD_DISTRO="fedora   # fedora debian ubuntu ...".
# Quote the value when a # really belongs to it.
# Dies (k_die) on anything else, naming the line.
k_answers_load_env_file() {
    local env_file="${1:?missing env file}"
    [[ -f "${env_file}" ]] || k_die "answers file not found: ${env_file}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # HISTORY 2026-09-13: indented comment lines (continuations of a comment
        # block in TEMPLATE.env) were "invalid line" and stopped the install.
        [[ "${line}" =~ ^[[:space:]]*(#.*)?$ ]] && continue

        [[ "${line}" == *=* ]] || k_die "invalid line in answers file: ${line}"

        local key="${line%%=*}"
        local value="${line#*=}"

        key="$(printf '%s' "${key}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        value="$(printf '%s' "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || k_die "invalid variable name in answers file: ${key}"

        if [[ "${value}" =~ ^\".*\"$ ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "${value}" =~ ^\'.*\'$ ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "${value}" =~ [[:space:]]# ]]; then
            k_die "answers file ${env_file}: ${key} has a comment on the same line (\"${value}\"). Put the comment on its own line, or quote the value if the # is part of it."
        fi

        printf -v "${key}" '%s' "${value}"
        # shellcheck disable=SC2163
        export "${key}"
    done <"${env_file}"
}

k_save_effective_config() {
    local out="${KLDLOAD_LOG_DIR:-/var/log/installer}/effective-config.env"
    mkdir -p "$(dirname "${out}")"

    # Snapshot env to a temp file first, then read it back. The previous
    # `done < <(env | sort)` process-substitution pattern races with the
    # child's exit under `set -Eeuo pipefail`: bash opens /dev/fd/63 AFTER
    # the child closes, yielding "/dev/fd/63: No such file or directory"
    # and aborting the whole install. Observed on CentOS 9 and Fedora
    # desktop-profile installs where the env set is larger (more exported
    # vars) and the timing window widens. Temp-file roundtrip can't race.
    local _envfile
    _envfile="$(mktemp 2>/dev/null || echo /tmp/k_env.$$)"
    env | sort >"${_envfile}" || true

    {
        echo "# kldload effective config"
        echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

        while IFS='=' read -r name _; do
            [[ "${name}" == KLDLOAD_* ]] || continue
            # Redacted by NAME PATTERN, not a list. The list missed
            # KLDLOAD_EXPORT_SCP_PASS, KLDLOAD_MOK_PASSWORD and KLDLOAD_RHEL_KEY
            # (it named a KLDLOAD_RHEL_ACTIVATION_KEY nothing sets), and this file
            # is copied to the installed system's /root/kldload-install-logs
            # (audit, 2026-09-13). *_KEY_FILE and *_PUBKEY are paths and public
            # keys, which autodeploy may need, so they stay readable.
            case "${name}" in
            *_PUBKEY | *_KEY_FILE | *_CERT_FILE)
                printf '%s=%q\n' "${name}" "${!name:-}"
                ;;
            # *RHEL_USERNAME too: a Red Hat login is half of a credential, and
            # this file is copied to the installed system's
            # /root/kldload-install-logs and gets read on camera (operator,
            # 2026-09-19, filming a RHEL install). NOT a bare *_USERNAME: that
            # also caught KLDLOAD_USERNAME, the local admin account, which is not
            # a secret and which kldload-autodeploy reads back out of this file.
            *PASS | *PASSWORD | *PASSPHRASE | *PSK | *SECRET | *TOKEN | *_KEY | *PRIVATE_KEY | *PRESHARED_KEY | *RHEL_USERNAME)
                printf '%s=%q\n' "${name}" "__REDACTED__"
                ;;
            *)
                printf '%s=%q\n' "${name}" "${!name:-}"
                ;;
            esac
        done <"${_envfile}"
    } >"${out}"
    rm -f "${_envfile}"
}
