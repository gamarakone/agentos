#!/usr/bin/env bash
#
# Generate Plymouth theme image assets for AgentOS
# Requires: rsvg-convert (librsvg2-bin) and ImageMagick (convert)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-${SCRIPT_DIR}/images}"

mkdir -p "$OUTPUT_DIR"

# ── Logo (text-based SVG rendered to PNG) ─────────────────────────
cat > "${OUTPUT_DIR}/logo.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="80">
  <text x="160" y="55" text-anchor="middle" fill="#ffffff" font-family="sans-serif"
        font-size="48" font-weight="300" letter-spacing="8">AgentOS</text>
</svg>
SVG

# ── Tagline ───────────────────────────────────────────────────────
cat > "${OUTPUT_DIR}/tagline.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="30">
  <text x="120" y="20" text-anchor="middle" fill="#8888aa" font-family="sans-serif"
        font-size="16" font-weight="300">Your AI, your machine</text>
</svg>
SVG

# ── Spinner frames (36 frames of a rotating arc) ─────────────────
for i in $(seq 0 35); do
    angle=$((i * 10))
    cat > "${OUTPUT_DIR}/spinner-${i}.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
  <circle cx="16" cy="16" r="12" fill="none" stroke="#333355" stroke-width="2"/>
  <path d="M16 4 A12 12 0 0 1 28 16" fill="none" stroke="#7c6ff7" stroke-width="2.5"
        stroke-linecap="round" transform="rotate(${angle} 16 16)"/>
</svg>
SVG
done

# ── Progress bar background ───────────────────────────────────────
cat > "${OUTPUT_DIR}/progress-bg.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="8">
  <rect width="400" height="8" rx="4" fill="#1a1a3e"/>
</svg>
SVG

# ── Progress bar fill ────────────────────────────────────────────
cat > "${OUTPUT_DIR}/progress-bar.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="396" height="4">
  <rect width="396" height="4" rx="2" fill="#7c6ff7"/>
</svg>
SVG

# ── Bullet for password entry ────────────────────────────────────
cat > "${OUTPUT_DIR}/bullet.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12">
  <circle cx="6" cy="6" r="5" fill="#7c6ff7"/>
</svg>
SVG

# ── Convert SVGs to PNGs ─────────────────────────────────────────
if command -v rsvg-convert &>/dev/null; then
    for svg in "${OUTPUT_DIR}"/*.svg; do
        png="${svg%.svg}.png"
        rsvg-convert "$svg" -o "$png"
    done
    # Clean up SVGs
    rm -f "${OUTPUT_DIR}"/*.svg
    echo "Generated $(ls "${OUTPUT_DIR}"/*.png | wc -l) PNG assets in ${OUTPUT_DIR}"
elif command -v convert &>/dev/null; then
    for svg in "${OUTPUT_DIR}"/*.svg; do
        png="${svg%.svg}.png"
        convert -background none "$svg" "$png"
    done
    rm -f "${OUTPUT_DIR}"/*.svg
    echo "Generated $(ls "${OUTPUT_DIR}"/*.png | wc -l) PNG assets in ${OUTPUT_DIR}"
else
    echo "WARNING: No SVG converter found (need rsvg-convert or ImageMagick)"
    echo "SVG files left in ${OUTPUT_DIR} — convert manually before building"
fi
