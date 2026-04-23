#!/usr/bin/env bash
# Sourced by kldload-install-target — k_answers_load_env_file (--config mode), k_save_effective_config
set -Eeuo pipefail

k_answers_load_env_file() {
  local env_file="${1:?missing env file}"
  [[ -f "${env_file}" ]] || k_die "answers file not found: ${env_file}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      ''|'#'*)
        continue
        ;;
    esac

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
    fi

    printf -v "${key}" '%s' "${value}"
    # shellcheck disable=SC2163
    export "${key}"
  done < "${env_file}"
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
  local _envfile; _envfile="$(mktemp 2>/dev/null || echo /tmp/k_env.$$)"
  env | sort > "${_envfile}" || true

  {
    echo "# kldload effective config"
    echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    while IFS='=' read -r name _; do
      [[ "${name}" == KLDLOAD_* ]] || continue
      case "${name}" in
        KLDLOAD_PASSWORD|KLDLOAD_ROOT_PASSWORD|KLDLOAD_ZFS_PASSPHRASE|KLDLOAD_WIREGUARD_PRIVATE_KEY|KLDLOAD_WIREGUARD_PRESHARED_KEY|KLDLOAD_WIFI_PSK|KLDLOAD_RHEL_PASSWORD|KLDLOAD_RHEL_ACTIVATION_KEY)
          printf '%s=%q\n' "${name}" "__REDACTED__"
          ;;
        *)
          printf '%s=%q\n' "${name}" "${!name:-}"
          ;;
      esac
    done < "${_envfile}"
  } > "${out}"
  rm -f "${_envfile}"
}
