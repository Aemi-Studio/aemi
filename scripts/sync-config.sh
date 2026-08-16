#!/bin/sh
# Copy the canonical lint/format configs into a consumer repo, so every package formats AND gates
# size/complexity identically: `.swift-format` (style, driven by swift-format) + `.swiftlint.yml`
# (the size/complexity metrics swift-format cannot express, driven by SwiftLint).
#
# Usage:   scripts/sync-config.sh /path/to/consumer-repo
# The reusable CI workflow runs the equivalent diffs and fails on drift.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

dest="${1:-}"
if [ -z "$dest" ] || [ ! -d "$dest" ]; then
    printf 'usage: sync-config.sh <consumer-repo-dir>\n' >&2
    exit 2
fi

for cfg in .swift-format .swiftlint.yml; do
    cp "$here/$cfg" "$dest/$cfg"
    printf 'synced %s -> %s/%s\n' "$cfg" "$dest" "$cfg"
done
