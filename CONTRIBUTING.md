# Contributing to Aemi

## Requirements

- Swift 6.3+ on macOS 15+ (full suite) or Linux (non-UI targets)

## Workflow

1. Fork or branch from `main`.
2. Keep changes focused and covered by tests.
3. Run formatting and tests before opening a pull request:

```sh
swift format lint --strict --recursive Sources Tests Package.swift
swift test
```

## Standards

- Strict Swift 6 concurrency and strict memory safety where enabled in `Package.swift`.
- Warnings are treated as errors on package targets; keep public APIs documented and minimal.
- Every bug fix or behavioural change includes a regression test.
