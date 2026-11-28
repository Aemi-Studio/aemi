---
status: accepted
date: 2026-11-28
---

# 0035 — Contrast and ink in `AemiColor`

## Context

Sunset computed relative luminance three times over (its accent colour, whether a pane's backdrop is dark, a test's
contrast check), each its own way, and now picks text inks from what is behind them: AemiSDR's `BackdropLumaView`
(AemiSDR's ADR-0010) reads the luma under a view, and the colours Sunset draws itself (a tint over a material, a terminal
background at an opacity) are known exactly. Both want the same arithmetic, which has no platform in it.

## Decision

- **`AemiColor`, a product of its own**, standard library only (`pow` from the platform's C library), so Linux builds it.
- **`RGB`**: gamma-encoded sRGB components, clamped so every value is a colour; from components, bytes or hex. The sRGB
  transfer function both ways; WCAG 2's relative luminance; Rec. 709 luma on the encoded values, which is what a backdrop
  reports, and the relative luminance of the grey with a given luma (exact for greys).
- **`Contrast`**: WCAG 2's ratio, from colours or luminances; APCA-W3 0.0.98G-4g's Lc, checked against its published test
  values.
- **`Layer`**: a colour at an opacity over another, mixed on encoded values as Core Animation and browsers composite by
  default; a stack laid from the bottom up.
- **`Ink`**: of candidate inks, the first to reach a contrast ratio, else the best; whether dark text reads better than
  light on a luminance.

## Consequences

The ink a host picks is as good as what it knows of the background: exact over its own colours, an estimate over a
luma read from the screen (a colour's luma is not its luminance). Hosts keep the band that stops text flickering
between inks (AemiSDR's `LumaLevel`).
