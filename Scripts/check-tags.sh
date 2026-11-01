#!/bin/sh
# Internal-tag lint gate for the g-cqd Swift family.
#
# Two checks over Swift sources:
#   1. TODO / FIXME markers — must stay at zero. Track work in issues/commits,
#      not in shipped comments.
#   2. Internal provenance citations — RFC 00xx / Review NNNN / milestone-finding
#      shorthand (M5/F5, F6c, …). These leak planning vocabulary into the code;
#      the surrounding technical sentence should stand on its own. Real IETF
#      references (e.g. RFC 7396, JSON Merge Patch) are deliberately NOT matched.
#
# Modes:
#   staged   Examine only newly *added* lines in the git index (pre-commit use).
#            Flags regressions regardless of citations still present in the tree,
#            so it is safe to enforce before the tree-wide strip lands.
#   all      Examine every tracked Swift source. TODO/FIXME is always enforced;
#            the provenance scan is enforced only when STRICT_TAGS=1 (CI sets it
#            once the tree-wide strip has landed), so this mode is safe early too.
#
# Prints offending locations and exits non-zero on any violation.

set -eu

mode="${1:-staged}"

# Extended-regex patterns. Keep in sync with the tree-wide strip.
todo_re='(TODO|FIXME)'
# High-confidence provenance: essentially no legitimate use in Swift comments.
# `RFC ?00[0-9]{2}` matches the internal 00xx series only (not RFC 7396 etc.).
prov_re='(RFC ?00[0-9]{2}|Review ?[0-9]{4}|[MF][0-9]+/[MFA][0-9]+[a-z]?)'
# Bare milestone/finding/appendix tags (M5, F6c, A2) are ambiguous on their own — the same shapes
# occur legitimately as hex bytes ("C3 A9", "F0 9F 98 80"), spec/label prose ("the A3 gate",
# "M2: lenient relaxes the grammar"), and URLs in string literals ("caf%C3%A9"). So a bare tag is
# flagged only inside a comment (`//` not preceded by `:`, so `https://…` never counts, and with no
# `"` between the comment marker and the tag; or a `*` doc line) AND only with citation context:
# a provenance keyword (see/per/cf/milestone/finding/appendix/review) immediately before the tag,
# or the tag parenthesized alone (`(F6c)`). The high-confidence paired/numbered forms above stay
# matched unconditionally.
bare_re='((^|[^:])//|^[[:space:]]*[*])[^"]*(\b([Ss]ee|[Pp]er|cf\.?|[Mm]ilestone|[Ff]inding|[Aa]ppendix|[Rr]eview)[[:space:]]+[MFA][0-9]+[a-z]?\b|\([MFA][0-9]+[a-z]?\))'

report() { printf '%s\n' "$1" >&2; }

scan_text() {
    # $1 = label, $2 = text (added lines or file contents, one per line)
    text="$2"
    hits=0

    todo_hits=$(printf '%s\n' "$text" | grep -nE "$todo_re" || true)
    if [ -n "$todo_hits" ]; then
        report "✗ TODO/FIXME markers are not allowed:"
        printf '%s\n' "$todo_hits" | sed 's/^/    /' >&2
        hits=1
    fi

    if [ "$mode" = "staged" ] || [ "${STRICT_TAGS:-0}" = "1" ]; then
        prov_hits=$(printf '%s\n' "$text" | grep -nE "$prov_re" || true)
        bare_hits=$(printf '%s\n' "$text" | grep -nE "$bare_re" || true)
        all_prov=$(printf '%s\n%s\n' "$prov_hits" "$bare_hits" | grep -v '^$' | sort -u || true)
        if [ -n "$all_prov" ]; then
            report "✗ internal provenance citations are not allowed (keep the sentence, drop the tag):"
            printf '%s\n' "$all_prov" | sed 's/^/    /' >&2
            hits=1
        fi
    fi

    return $hits
}

status=0

case "$mode" in
staged)
    added=$(git diff --cached --unified=0 --no-color -- '*.swift' \
        | grep '^+' | grep -v '^+++' | sed 's/^+//' || true)
    if [ -z "$added" ]; then
        exit 0
    fi
    scan_text "staged" "$added" || status=1
    ;;
all)
    files=$(git ls-files '*.swift')
    for f in $files; do
        contents=$(cat "$f")
        if ! scan_text "$f" "$contents"; then
            report "  (in $f)"
            status=1
        fi
    done
    ;;
*)
    report "usage: check-tags.sh [staged|all]"
    exit 2
    ;;
esac

if [ "$status" -ne 0 ]; then
    report ""
    report "tag check failed (mode: $mode)."
fi
exit "$status"
