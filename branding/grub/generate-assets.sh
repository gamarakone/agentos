#!/usr/bin/env bash
#
# Generate GRUB theme image assets for AgentOS
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-${SCRIPT_DIR}/images}"

mkdir -p "$OUTPUT_DIR"

# ── Background (1920x1080 dark gradient) ──────────────────────────
cat > "${OUTPUT_DIR}/background.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0.5" y2="1">
      <stop offset="0%" stop-color="#0f0c29"/>
      <stop offset="50%" stop-color="#1a1845"/>
      <stop offset="100%" stop-color="#24243e"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
</svg>
SVG

# ── Menu background (9-slice: menu_c.png center, menu_n/s/e/w borders) ──
for part in c n s e w ne nw se sw; do
    size="4x4"
    color="#1a1a3e"
    case "$part" in
        c) size="4x4"; color="#12122aee" ;;
        n|s) size="4x2"; color="#2a2a5588" ;;
        e|w) size="2x4"; color="#2a2a5588" ;;
        *) size="2x2"; color="#3a3a6688" ;;
    esac
    cat > "${OUTPUT_DIR}/menu_${part}.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="${size%%x*}" height="${size##*x}">
  <rect width="${size%%x*}" height="${size##*x}" fill="${color}" rx="1"/>
</svg>
SVG
done

# ── Selection highlight (9-slice) ─────────────────────────────────
for part in c n s e w ne nw se sw; do
    size="4x4"
    color="#7c6ff7"
    case "$part" in
        c) size="4x4"; color="#7c6ff730" ;;
        n|s) size="4x2"; color="#7c6ff750" ;;
        e|w) size="2x4"; color="#7c6ff750" ;;
        *) size="2x2"; color="#7c6ff770" ;;
    esac
    cat > "${OUTPUT_DIR}/select_${part}.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="${size%%x*}" height="${size##*x}">
  <rect width="${size%%x*}" height="${size##*x}" fill="${color}" rx="1"/>
</svg>
SVG
done

# ── Scrollbar thumb ───────────────────────────────────────────────
for part in c n s; do
    cat > "${OUTPUT_DIR}/scrollbar_thumb_${part}.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="6" height="6">
  <rect width="6" height="6" rx="3" fill="#7c6ff7"/>
</svg>
SVG
done

# ── Convert SVGs to PNGs ─────────────────────────────────────────
if command -v rsvg-convert &>/dev/null; then
    for svg in "${OUTPUT_DIR}"/*.svg; do
        png="${svg%.svg}.png"
        rsvg-convert "$svg" -o "$png"
    done
    rm -f "${OUTPUT_DIR}"/*.svg
    echo "Generated $(ls "${OUTPUT_DIR}"/*.png | wc -l) GRUB theme assets"
elif command -v convert &>/dev/null; then
    for svg in "${OUTPUT_DIR}"/*.svg; do
        png="${svg%.svg}.png"
        convert -background none "$svg" "$png"
    done
    rm -f "${OUTPUT_DIR}"/*.svg
    echo "Generated $(ls "${OUTPUT_DIR}"/*.png | wc -l) GRUB theme assets"
else
    echo "WARNING: No SVG converter found — SVG files left in ${OUTPUT_DIR}"
fi
