#!/bin/sh
# Scripts/analyzers.sh on fake releases served from a file:// URL (analyzerkit roadmap 0031): an archive whose SHA-256
# is the lock's installs and runs; a tampered one is refused before anything runs, with status 2.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=macos-arm64 ;;
    Linux-x86_64) platform=linux-x86_64 ;;
    *) echo "skipped: no archive platform for $(uname -s)-$(uname -m)"; exit 0 ;;
esac
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

# A fake `faketool` 1.0.0: prints its version, and for `analyze` records its arguments and succeeds.
name="faketool-1.0.0-$platform"
mkdir -p "$work/build/$name" "$work/releases/faketool/releases/download/v1.0.0"
cat > "$work/build/$name/faketool" <<'TOOL'
#!/bin/sh
[ "$1" = "--version" ] && { echo 1.0.0; exit 0; }
echo "$@" > "$FAKETOOL_LOG"
TOOL
chmod +x "$work/build/$name/faketool"
tar -czf "$work/releases/faketool/releases/download/v1.0.0/$name.tar.gz" -C "$work/build" "$name"
good=$(sha "$work/releases/faketool/releases/download/v1.0.0/$name.tar.gz")

failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }

# The lock's hash: installed, run with the shared flags and the corpus.
printf 'faketool 1.0.0 %s %s\n' "$good" "$good" > "$work/good.lock"
mkdir -p "$work/repo" && cd "$work/repo"
status=0
FAKETOOL_LOG="$work/args" ANALYZERS_BASE_URL="file://$work/releases" ANALYZERS_LOCK="$work/good.lock" \
    ANALYZERS_CACHE="$work/cache-good" ANALYZERS_TOOLS=faketool ANALYZERS_CORPUS="Sources Tests" \
    sh "$here/analyzers.sh" > "$work/good.out" 2>&1 || status=$?
check "a matching archive installs and runs" '[ "$status" -eq 0 ]'
check "the run gets the shared flags and the corpus" \
    'grep -q -- "analyze --strict --no-cache --relative-to . Sources Tests" "$work/args"'

# A tampered archive: refused with status 2, nothing installed, nothing run.
printf 'faketool 1.0.0 %s %s\n' "$(printf '0%.0s' $(seq 1 64))" "$(printf '0%.0s' $(seq 1 64))" > "$work/bad.lock"
rm -f "$work/args"
status=0
FAKETOOL_LOG="$work/args" ANALYZERS_BASE_URL="file://$work/releases" ANALYZERS_LOCK="$work/bad.lock" \
    ANALYZERS_CACHE="$work/cache-bad" ANALYZERS_TOOLS=faketool sh "$here/analyzers.sh" > "$work/bad.out" 2>&1 || status=$?
check "a tampered archive is refused with status 2" '[ "$status" -eq 2 ]'
check "the refusal names the hash" 'grep -q "is not the pinned" "$work/bad.out"'
check "nothing was installed or run" '[ ! -e "$work/cache-bad/faketool-1.0.0" ] && [ ! -e "$work/args" ]'

# A tool the lock does not pin is a usage error, not a silent skip.
status=0
ANALYZERS_BASE_URL="file://$work/releases" ANALYZERS_LOCK="$work/good.lock" ANALYZERS_CACHE="$work/cache-good" \
    ANALYZERS_TOOLS=unpinned sh "$here/analyzers.sh" > "$work/unpinned.out" 2>&1 || status=$?
check "an unpinned tool is refused" '[ "$status" -eq 2 ] && grep -q "not in the lock" "$work/unpinned.out"'

# The family's lock pins every tool for both platforms.
check "the lock pins the five tools with two hashes each" \
    '[ "$(grep -cE "^(arcleak|deadwood|dolly|fcheck|modeler) [0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]{64} [0-9a-f]{64}$" "$here/analyzers.lock")" -eq 5 ]'
exit "$failures"
