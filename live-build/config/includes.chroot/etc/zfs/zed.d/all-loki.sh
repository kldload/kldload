#!/bin/bash
# zed event → Loki push. Every zpool event triggers this (checksum errors,
# resilver start/end, trim, spare activation, vdev state changes, etc.)
# Envs set by zed: ZEVENT_CLASS, ZEVENT_POOL, ZEVENT_VDEV_PATH,
# ZEVENT_VDEV_STATE_STR, ZEVENT_HISTORY_INTERNAL_STR, ZEVENT_EID, ...
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100/loki/api/v1/push}"

# Build a compact, grep-friendly log line.
_line="class=${ZEVENT_CLASS:-?} pool=${ZEVENT_POOL:-?}"
[[ -n "${ZEVENT_VDEV_PATH}" ]] && _line+=" vdev=${ZEVENT_VDEV_PATH}"
[[ -n "${ZEVENT_VDEV_STATE_STR}" ]] && _line+=" vdev_state=${ZEVENT_VDEV_STATE_STR}"
[[ -n "${ZEVENT_HISTORY_INTERNAL_STR}" ]] && _line+=" hist=${ZEVENT_HISTORY_INTERNAL_STR}"
[[ -n "${ZEVENT_EID}" ]] && _line+=" eid=${ZEVENT_EID}"
[[ -n "${ZEVENT_CKSUM_ERRORS}" ]] && _line+=" cksum_errs=${ZEVENT_CKSUM_ERRORS}"
[[ -n "${ZEVENT_READ_ERRORS}" ]] && _line+=" read_errs=${ZEVENT_READ_ERRORS}"
[[ -n "${ZEVENT_WRITE_ERRORS}" ]] && _line+=" write_errs=${ZEVENT_WRITE_ERRORS}"

# Push to Loki. Timestamp is ns-epoch. Labels are the high-cardinality
# safe ones: host, job=zed, class, pool. Everything else goes in the log.
_ts="$(date +%s%N)"
_host="$(hostname -s 2>/dev/null || echo unknown)"
_class="${ZEVENT_CLASS:-unknown}"
_pool="${ZEVENT_POOL:-none}"

# Single-stream push — one entry per event.
# Escape backslashes and double quotes in the line for JSON safety.
_esc="$(printf '%s' "$_line" | sed 's/\\/\\\\/g; s/"/\\"/g')"
curl -s -m 5 -o /dev/null \
    -H 'Content-Type: application/json' \
    -XPOST "$LOKI_URL" \
    -d "{\"streams\":[{\"stream\":{\"job\":\"zed\",\"host\":\"$_host\",\"class\":\"$_class\",\"pool\":\"$_pool\"},\"values\":[[\"$_ts\",\"$_esc\"]]}]}" ||
    true
