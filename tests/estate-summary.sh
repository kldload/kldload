#!/usr/bin/env bash
# =============================================================================
# estate-summary.sh — one table across every sweep run on this machine
# =============================================================================
#
# WHAT IT DOES
#   Walks estate-results/<run-id>/<edition>/ and prints one markdown table:
#   every edition ever swept, its verdict, its suite tally, whether the
#   lifecycle ran, and what is missing. Newest run last, so the table reads
#   like a history.
#
# WHY: a sweep that is interrupted starts a NEW run directory, so one night's
# work can be spread across three of them. Reading three SUMMARY.md files and
# holding the difference in your head is exactly the sort of thing that makes
# somebody declare a profile "verified" from memory (2026-09-20).
#
# OUTPUT: markdown on stdout. Writes nothing.
# EXIT:   0 always — this is a reader, and an empty estate-results is a fact,
#         not an error.
# =============================================================================
set -Eeuo pipefail
trap 'echo "estate-summary.sh: line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="${ROOT}/estate-results"

case "${1:-}" in
-h | --help | help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
esac

[[ -d "$RESULTS" ]] || {
    echo "no estate-results directory yet"
    exit 0
}

echo "# Estate sweep results — $(date -Is)"
echo
echo '| run | edition | verdict | pass | fail | warn | lifecycle | notes |'
echo '|---|---|---|---|---|---|---|---|'

shopt -s nullglob
for run in "$RESULTS"/*/; do
    run_id="$(basename "$run")"
    for ed in "$run"*/; do
        ed_id="$(basename "$ed")"
        rep="${ed}report.md"
        note=""
        if [[ ! -f "$rep" ]]; then
            # A truncated report is filed under its own name by the sweep, and
            # the README beside it says why. Say so rather than showing a gap.
            rep="$(ls "${ed}"report-*.md 2>/dev/null | head -1 || true)"
            [[ -n "$rep" ]] && note="report truncated"
        fi
        [[ -n "$rep" && -f "$rep" ]] || continue

        verdict="$(grep -oE '\*\*(PASS|FAIL)[^*]*\*\*' "$rep" 2>/dev/null | head -1 | tr -d '*' || true)"
        [[ -n "$verdict" ]] || verdict="(none)"
        read -r p f w < <(sed -n 's/^PASS \([0-9]*\)   FAIL \([0-9]*\)   WARN \([0-9]*\)$/\1 \2 \3/p' "$rep" | head -1)

        lc="—"
        if [[ -f "${ed}estate-lifecycle.txt" ]]; then
            if grep -q 'estate lifecycle:' "${ed}estate-lifecycle.txt" 2>/dev/null; then
                lc="$(grep -oE 'estate lifecycle: [0-9]+ passed, [0-9]+ failed' "${ed}estate-lifecycle.txt" | tail -1 |
                    sed 's/estate lifecycle: //; s/ passed,/p/; s/ failed/f/')"
            else
                lc="truncated"
            fi
        fi
        [[ -f "${ed}bundle.tar.gz" ]] || note="${note:+$note; }no bundle"

        printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
            "$run_id" "$ed_id" "$verdict" "${p:-}" "${f:-}" "${w:-}" "$lc" "$note"
    done
done

echo
echo "## Recurring failures across editions"
echo
echo '```'
# The same failure on several editions is a product defect; one that appears
# once is usually the machine. Sorting by count says which is which.
grep -hoE '✗ FAIL  [a-z ]+—[^|]*' "$RESULTS"/*/*/report*.md 2>/dev/null |
    sed 's/[0-9]\+/N/g; s/  */ /g' | sort | uniq -c | sort -rn | head -12 || echo "none recorded"
echo '```'
