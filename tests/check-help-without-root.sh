#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-help-without-root.sh — `--help` must not need root.
#
# WHAT IT DOES, IN ORDER:
#   1. selects every tracked shell file by SHEBANG (most shipped tools have no
#      extension, so a *.sh glob misses the majority of them)
#   2. keeps the ones that re-exec themselves as root
#   3. runs each with `--help` and a STUB sudo first on PATH
#   4. fails if a tool outside the baseline called sudo, exited non-zero, or
#      printed nothing
#
# WHY IT EXISTS: rule 9 says --help answers first, needs no root, and exits 0.
# On 2026-09-16 `klab --help` asked for a password to print text, because its
# help lived in the dispatcher a hundred lines past the re-exec. Sweeping for
# more found eight others. On a machine where the operator has no sudo rights,
# those tools could not describe themselves at all.
#
# WHY A STUB RATHER THAN READING THE CODE: line numbers cannot answer this. A
# re-exec inside a function body sits above the help case in the file and below
# it at runtime. The only honest test is to run the thing and watch whether it
# reaches for root.
#
# THE BASELINE is a ratchet. tests/help-without-root-baseline.txt lists tools
# that do not yet handle --help at all; they are allowed to fail and the list
# may only ever shrink. Removing a name is the fix. Adding one is a regression
# and this gate says so.
#
# INPUT:  the git worktree. OUTPUT: a report on stdout.
# EXIT:   0 all good, 1 a regression, 2 the gate could not run.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "check-help-without-root: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

cd "$(dirname "${BASH_SOURCE[0]}")/.."
BASELINE="tests/help-without-root-baseline.txt"

command -v git >/dev/null 2>&1 || {
    echo "check-help-without-root: git not available — THIS CHECK DID NOT RUN" >&2
    exit 2
}

# The stub has to live somewhere executable: /tmp is noexec on the build host
# (onyx, ZFS), which silently skips a PATH shim and makes every tool look clean.
STUBDIR="$(mktemp -d "${TMPDIR:-/var/tmp}/helpgate.XXXXXX")"
trap 'rm -rf "$STUBDIR"' EXIT
cat >"$STUBDIR/sudo" <<'STUB'
#!/usr/bin/env bash
echo "__SUDO_WAS_CALLED__: $*" >&2
exit 97
STUB
chmod +x "$STUBDIR/sudo"
# Prove the stub actually runs before trusting a clean result. Its exit 97 is
# deliberate, so the status is captured and discarded -- checking the pipeline
# status under pipefail reads the stub's own 97 as "the stub is broken", which
# is how this gate first reported that /var/tmp was noexec when it is not.
_probe="$("$STUBDIR/sudo" -n true 2>&1 || true)" # 97 is the stub doing its job
if ! grep -q __SUDO_WAS_CALLED__ <<<"$_probe"; then
    echo "check-help-without-root: the stub does not execute from ${STUBDIR} (noexec?) — THIS CHECK DID NOT RUN" >&2
    exit 2
fi

mapfile -t baseline < <(grep -vE '^\s*(#|$)' "$BASELINE" 2>/dev/null || true) # absent baseline = nothing exempt
is_baselined() {
    local n=$1 b
    for b in ${baseline[@]+"${baseline[@]}"}; do [[ "$n" == "$b" ]] && return 0; done
    return 1
}

mapfile -t tracked < <(git ls-files)
checked=0 bad=0 exempt=0
declare -a FAILED=() FIXED=()

for f in "${tracked[@]}"; do
    [[ -f "$f" ]] || continue
    IFS= read -r first <"$f" || continue # empty file: nothing to classify
    [[ "$first" =~ ^#!.*(bash|/bin/sh) ]] || continue
    grep -qE 'exec sudo|sudo +-E +"?\$0' "$f" || continue # no re-exec: out of scope

    name="$(basename "$f")"
    out="$(PATH="$STUBDIR:$PATH" timeout 20 bash "$f" --help 2>&1 </dev/null)" && rc=0 || rc=$?
    lines="$(printf '%s' "$out" | grep -c . || true)"

    ok=1
    grep -q '__SUDO_WAS_CALLED__' <<<"$out" && ok=0
    ((rc == 0)) || ok=0
    ((lines >= 3)) || ok=0

    checked=$((checked + 1))
    if ((ok == 1)); then
        is_baselined "$name" && FIXED+=("$name")
    else
        if is_baselined "$name"; then
            exempt=$((exempt + 1))
        else
            FAILED+=("${name}: exit=${rc} lines=${lines}$(grep -q '__SUDO_WAS_CALLED__' <<<"$out" && echo ' ASKED-FOR-ROOT' || true)")
            bad=$((bad + 1))
        fi
    fi
done

printf 'help-without-root: %d tool(s) re-exec as root — %d pass, %d known-bad (baseline), %d REGRESSED\n' \
    "$checked" "$((checked - exempt - bad))" "$exempt" "$bad"

if ((${#FIXED[@]})); then
    printf '\n  these are in the baseline but now PASS — remove them from %s:\n' "$BASELINE"
    printf '    %s\n' "${FIXED[@]}"
fi

if ((bad > 0)); then
    printf '\n  REGRESSION — --help must answer without root and exit 0:\n'
    printf '    %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
