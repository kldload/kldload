#!/usr/bin/env bash
# =============================================================================
# check-comment-in-command.sh — a comment inside a multi-line command ends it
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Selects every tracked shell script by shebang (most shipped tools have
#      no extension), the same way smoke-build's syntax gates do.
#   2. Flags a comment line that sits where the command before it is still
#      going, in either of the two shapes that have shipped:
#        A  the previous line ends in `\`   — the comment terminates the
#           command, and the lines after it run as a NEW command
#        B  the next line starts with `/`, `-` or a redirect, and the previous
#           line does not end a statement — an argument orphaned from its
#           command, which then runs as a command of its own
#   3. Prints file:line for each and exits by what it found.
#
# WHY IT EXISTS: the silent-failure sweep of 2026-09-15 (bbaf6f54) put its
# "# swallow:" explanations directly above the `2>/dev/null || true` they
# explained — which, in three places, was the middle of a command. bash -n,
# the shellcheck error tier and shfmt were all green, and every one of the three
# broke silently:
#   - kldload-install-target: awk read stdin instead of /etc/kldload/VERSION,
#     so every install for a week stamped KLDLOAD_INSTALLER_VERSION="1.1.0"
#     (a 1.5.0 ISO, build 56, fiend 2026-09-22)
#   - the DKMS sign_helper.sh, written twice: `-name sign-file` never reached
#     find, SIGN_FILE held the whole kernel tree (25,287 lines on onyx), and
#     kupgrade / the kernel postinst hook re-signed nothing, exit 0
#
# Shape B is a heuristic and knows it: it is tuned to the tree as it stood on
# 2026-09-22, where it fires on exactly the one real case. A false positive is
# fixed by moving the comment — which is always the better layout anyway.
#
# OUTPUT: file:line:shape on stdout, one per finding; a summary on stderr.
# EXIT:   0 none found · 1 found at least one · 2 the gate could not run
#         (a check that cannot run is not a check — core rules §3).
# =============================================================================
set -Eeuo pipefail
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

case "${1:-}" in
-h | --help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "check-comment-in-command: $ROOT is not a git work tree — DID NOT RUN" >&2
    exit 2
}

scripts=()
while IFS= read -r -d '' f; do
    [[ -f "$ROOT/$f" && ! -L "$ROOT/$f" ]] || continue
    head -n 1 "$ROOT/$f" 2>/dev/null | grep -qE '^#!.*(bash|/bin/sh)' && scripts+=("$f")
done < <(git -C "$ROOT" ls-files -z)

if ((${#scripts[@]} == 0)); then
    echo "check-comment-in-command: found no shell scripts — DID NOT RUN" >&2
    exit 2
fi

found=0
for f in "${scripts[@]}"; do
    # </dev/null: awk takes its file as an argument; nothing here may read the
    # caller's stdin (smoke-build runs this inside a loop).
    hits="$(awk -v F="$f" '
        { line[NR] = $0 }
        END {
            for (i = 2; i < NR; i++) {
                if (line[i] !~ /^[[:space:]]*#/) continue
                prev = line[i - 1]; next_ = line[i + 1]
                if (prev ~ /\\[[:space:]]*$/ && prev !~ /^[[:space:]]*#/) {
                    print F ":" i ":A"
                } else if (next_ ~ /^[[:space:]]*(\/|-[-a-zA-Z]|[0-9]?>|<)/ &&
                    prev !~ /^[[:space:]]*(#|$)/ &&
                    prev !~ /([;{}(]|then|do|else|in|\|\||&&|\||\))[[:space:]]*$/) {
                    print F ":" i ":B"
                }
            }
        }' "$ROOT/$f" </dev/null)"
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits"
        found=$((found + $(printf '%s\n' "$hits" | wc -l)))
    fi
done

echo "check-comment-in-command: ${#scripts[@]} scripts scanned, $found comment(s) inside a command" >&2
((found == 0)) || exit 1
