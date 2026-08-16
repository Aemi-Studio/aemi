#!/bin/sh
# check-manifest-settings.sh — fail if a package manifest is missing any canonical AD-family
# swiftSetting. This is the manifest analogue of the `.swift-format` / `.swiftlint.yml` drift checks:
# SwiftPM cannot share manifest code across packages, so this gate keeps the per-package
# `strictSettings` blocks from silently diverging (the drift that left ADConcurrency / ADTestKit
# without the import-visibility upcoming features). Run per-package by the reusable swift-quality.yml.
#
# Usage: scripts/check-manifest-settings.sh [path/to/Package.swift]   (defaults to ./Package.swift)
set -eu

manifest="${1:-Package.swift}"
if [ ! -f "$manifest" ]; then
    printf '::error::manifest not found: %s\n' "$manifest" >&2
    exit 2
fi

missing=0
check() {
    # `--` terminates option parsing so patterns that begin with `-` (e.g. `-warnings-as-errors`)
    # are treated as a pattern, not a grep flag.
    if ! grep -qF -- "$1" "$manifest"; then
        printf '::error::%s missing canonical setting: %s\n' "$manifest" "$1" >&2
        missing=1
    fi
}

# The canonical strict set every first-party target compiles under (safe SwiftSettings, so they never
# block version-based resolution). Aligned with ADFoundation / ADJSON / ADSQL / ADServe / apple-docs.
check 'swiftLanguageMode(.v6)'
check 'enableUpcomingFeature("ExistentialAny")'
check 'enableUpcomingFeature("InferIsolatedConformances")'
check 'enableUpcomingFeature("InternalImportsByDefault")'
check 'enableUpcomingFeature("MemberImportVisibility")'

# warnings-as-errors: most packages set `treatAllWarnings(as: .error)` always-on; ADDB / ADSQL instead
# gate `-warnings-as-errors` behind *_WERROR while the SE-0458 unsafe-construct shrink is in progress.
# Accept either form, but require one to be present.
if ! grep -qF -- 'treatAllWarnings(as: .error)' "$manifest" && ! grep -qF -- '-warnings-as-errors' "$manifest"; then
    printf '::error::%s has no warnings-as-errors policy (treatAllWarnings or -warnings-as-errors)\n' "$manifest" >&2
    missing=1
fi

if [ "$missing" -eq 0 ]; then
    printf 'manifest settings OK: %s\n' "$manifest"
fi
exit "$missing"
