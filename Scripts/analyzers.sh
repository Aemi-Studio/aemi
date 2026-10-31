#!/bin/sh
# The g-cqd static analyzers (arcleak, deadwood, dolly, fcheck, modeler) for any package of the family, from their
# release archives (analyzerkit roadmap 0031).
#
#   analyzers.sh            install the pinned releases if absent, then run the selected tools
#   analyzers.sh install    install only
#
# Each tool is pinned in the lock to a version and to the SHA-256 of its archive for macOS arm64 and Linux x86_64, and
# the hash and the binary's --version are checked before anything runs: baseline fingerprints move between versions,
# so an unpinned tool would turn a gate red with no change of the package's. Each tool runs with
# `--strict --no-cache --relative-to .`, its committed `.<tool>-baseline.json` when there is one, and its own
# configuration file as it finds it.
#
# Environment:
#   ANALYZERS_TOOLS     the tools to run, in order (default: deadwood dolly arcleak)
#   ANALYZERS_CORPUS    the paths they analyze (default: Sources Tests)
#   ANALYZERS_LOCK      the lock (default: analyzers.lock beside this script)
#   ANALYZERS_CACHE     where archives are installed (default: the user cache, g-cqd-analyzers)
#   ANALYZERS_BASE_URL  where releases are downloaded from (default: https://github.com/g-cqd)
#
# Exit: 0 clean, 1 a tool found something, 2 a tool could not be installed or run, or is not in the lock.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
LOCK="${ANALYZERS_LOCK:-$here/analyzers.lock}"
TOOLS="${ANALYZERS_TOOLS:-deadwood dolly arcleak}"
CORPUS="${ANALYZERS_CORPUS:-Sources Tests}"
BASE_URL="${ANALYZERS_BASE_URL:-https://github.com/g-cqd}"

fail() { printf '[FAIL] %s\n' "$1" >&2; exit "${2:-1}"; }

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) PLATFORM=macos-arm64 COLUMN=3 CACHE_ROOT="$HOME/Library/Caches" ;;
    Linux-x86_64) PLATFORM=linux-x86_64 COLUMN=4 CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}" ;;
    *) fail "only macOS arm64 and Linux x86_64 archives are published" 2 ;;
esac
# Outside the repository, so a verification worktree reuses the download instead of repeating it.
CACHE="${ANALYZERS_CACHE:-$CACHE_ROOT/g-cqd-analyzers}"
[ -f "$LOCK" ] || fail "no lock at $LOCK" 2

# `field TOOL N`: the lock's Nth column for TOOL (2: version, 3: macOS hash, 4: Linux hash), empty when absent.
field() { awk -v tool="$1" -v column="$2" '$1 == tool { print $column; exit }' "$LOCK"; }

digest() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

install_tool() {
    tool=$1
    version=$(field "$tool" 2)
    sha=$(field "$tool" "$COLUMN")
    [ -n "$version" ] && [ -n "$sha" ] || fail "$tool is not in the lock $LOCK" 2
    dir="$CACHE/$tool-$version"
    [ -x "$dir/$tool" ] && return 0
    name="$tool-$version-$PLATFORM"
    scratch=$(mktemp -d)
    printf '==> installing %s %s (%s)\n' "$tool" "$version" "$PLATFORM"
    if ! curl -fsSL --retry 3 -o "$scratch/$name.tar.gz" "$BASE_URL/$tool/releases/download/v$version/$name.tar.gz"; then
        rm -rf "$scratch"
        fail "$tool: download failed" 2
    fi
    actual=$(digest "$scratch/$name.tar.gz")
    if [ "$actual" != "$sha" ]; then
        rm -rf "$scratch"
        fail "$tool: archive hash $actual is not the pinned $sha" 2
    fi
    tar -xzf "$scratch/$name.tar.gz" -C "$scratch"
    mkdir -p "$dir"
    # The whole directory: the Linux archive carries the Swift runtime libraries beside the binary.
    cp -R "$scratch/$name/." "$dir/"
    rm -rf "$scratch"
    reported=$("$dir/$tool" --version 2>/dev/null || true)
    [ "$reported" = "$version" ] || { rm -rf "$dir"; fail "$tool reports '$reported', not $version" 2; }
}

for tool in $TOOLS; do install_tool "$tool"; done
[ "${1:-}" = "install" ] && exit 0

failed=0
for tool in $TOOLS; do
    version=$(field "$tool" 2)
    printf '==> %s %s\n' "$tool" "$version"
    command=analyze
    [ "$tool" = modeler ] && command=check
    # A committed baseline holds the findings that predate the gate; only a finding it does not hold fails.
    # Fingerprints hash the path relative to --relative-to, so the baseline matches on any machine.
    baseline=""
    [ -f ".$tool-baseline.json" ] && baseline="--baseline .$tool-baseline.json"
    # shellcheck disable=SC2086
    "$CACHE/$tool-$version/$tool" $command --strict --no-cache --relative-to . $baseline $CORPUS || failed=1
done
[ "$failed" -eq 0 ] || fail "a static analyzer reported findings (accept one with a directive and a reason, never silently)"
printf '[OK] analyzers clean\n'
