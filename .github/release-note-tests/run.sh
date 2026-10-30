#!/usr/bin/env bash
# The release-note lint of swift-tool.yml's publish job, run on fixtures (analyzerkit roadmap 0030). The lint lives
# inline in the workflow, between its `release-note-lint` markers, so callers that pin the workflow get it with no
# other fetch; this extracts it from there.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
workflow="$here/../workflows/swift-tool.yml"
lint="$(mktemp)"
trap 'rm -f "$lint"' EXIT
awk '/# release-note-lint:begin/{on=1; next} /# release-note-lint:end/{on=0} on' "$workflow" \
    | python3 -c 'import sys, textwrap; sys.stdout.write(textwrap.dedent(sys.stdin.read()))' > "$lint"
if [ ! -s "$lint" ]; then echo "no release-note lint in $workflow" >&2; exit 1; fi

failures=0
expect() { # expect pass|fail NOTE [needle in the output]
    local want="$1" note="$here/notes/$2" needle="${3:-}" out status=0
    out="$(python3 "$lint" "$note" "$here/assets" /dev/stdout 2>&1)" || status=$?
    if { [ "$want" = pass ] && [ $status -ne 0 ]; } || { [ "$want" = fail ] && [ $status -eq 0 ]; }; then
        echo "FAIL $2: expected $want, status $status"; echo "$out" | sed 's/^/    /'; failures=$((failures + 1))
    elif [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
        echo "FAIL $2: output lacks '$needle'"; echo "$out" | sed 's/^/    /'; failures=$((failures + 1))
    else
        echo "ok   $2 ($want)"
    fi
}
expect pass good.md "\`tool-1.2.0-macos-arm64.tar.gz\`: \`$(printf a%.0s {1..64})\`"
expect pass good.md "SwiftPM checksum (\`swift package compute-checksum\`): \`$(printf c%.0s {1..64})\`"
expect fail freeform.md "missing section: Archives"
expect fail empty-section.md "empty section: Report"
expect fail missing-section.md "missing section: Cache"
expect fail wrong-checksum.md "does not match a published .sha256"
expect pass right-checksum.md
exit $failures
