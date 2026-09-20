#!/usr/bin/env bash
# =============================================================================
# package-and-stage.sh — turn this chart into a workload the installer deploys
# =============================================================================
#
# WHAT IT DOES
#   1. helm package the chart next door into a .tgz
#   2. drops it in /root/darksite/helm-charts/workloads/, which kldload-autodeploy
#      installs at first boot — release and namespace taken from the filename
#   3. copies values.yaml beside it as <name>.values.yaml if you pass --values,
#      which the installer picks up automatically
#
# WHY: this is the whole "bring your own workload" story in one command. No
# registry to reach, no pipeline, no cluster required at the time you run it —
# the machine deploys it the next time it boots.
#
# USAGE: package-and-stage.sh [--values] [--dest DIR]
# EXIT:  0 staged · 1 helm package failed · 2 the destination is not writable.
# =============================================================================
set -Eeuo pipefail
trap 'echo "package-and-stage.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${HERE}/../chart"
DEST=/root/darksite/helm-charts/workloads
WITH_VALUES=0

while (($#)); do
    case "$1" in
    -h | --help)
        sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
        exit 0
        ;;
    --values)
        WITH_VALUES=1
        shift
        ;;
    --dest)
        DEST="${2:?--dest needs a directory}"
        shift 2
        ;;
    *)
        echo "unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

command -v helm >/dev/null || {
    echo "helm is not installed" >&2
    exit 1
}
mkdir -p "$DEST" 2>/dev/null || {
    echo "cannot write ${DEST} — run as root, or pass --dest" >&2
    exit 2
}

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
helm package "$CHART" -d "$_tmp" >/dev/null

# helm names the file <chart>-<version>.tgz; the installer keys the release
# name off the bare filename, so pod-inspector-1.0.0.tgz would become a release
# called "pod-inspector-1-0-0". Rename to the bare chart name.
_built="$(find "$_tmp" -maxdepth 1 -name '*.tgz' | head -1)"
_name="$(helm show chart "$CHART" | sed -n 's/^name: *//p' | head -1)"
install -m 0644 "$_built" "${DEST}/${_name}.tgz"

if ((WITH_VALUES)); then
    install -m 0644 "${CHART}/values.yaml" "${DEST}/${_name}.values.yaml"
fi

# Outcome, not exit code: the file has to be there, and helm has to accept it.
[[ -s "${DEST}/${_name}.tgz" ]] || {
    echo "nothing landed in ${DEST}" >&2
    exit 1
}
helm show chart "${DEST}/${_name}.tgz" >/dev/null || {
    echo "${DEST}/${_name}.tgz is not a chart helm can read" >&2
    exit 1
}
echo "staged ${DEST}/${_name}.tgz ($(stat -c %s "${DEST}/${_name}.tgz") bytes)"
((WITH_VALUES)) && echo "staged ${DEST}/${_name}.values.yaml"
echo "It installs on the next boot. To do it now:"
echo "  helm upgrade --install ${_name} ${DEST}/${_name}.tgz --create-namespace -n ${_name}"
