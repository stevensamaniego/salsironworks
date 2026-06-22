#!/bin/bash
# site-admin.sh — Sal's Ironworks gallery manager
# Usage:
#   ./site-admin.sh list                          — List all gallery items with numbers
#   ./site-admin.sh add <file> <category> <label> [<label_es>] — Add image/video to gallery
#   ./site-admin.sh remove <number>               — Remove gallery item by number
#   ./site-admin.sh remove <n1,n2,n3,...>          — Remove multiple items by number
#
# Categories: gates, railings, structural, fences, custom
# Videos are auto-detected from file extension (.mp4, .mov)
#
# All changes auto-commit and push to GitHub (live on salsironworks.com)

set -euo pipefail
cd "$(dirname "$0")"

HTML="index.html"
# Match gallery items but NOT gallery-item-overlay
ITEM_PAT='class="gallery-item"'
ITEM_PAT2='class="gallery-item '

grep_items() {
  grep -n "$ITEM_PAT\|$ITEM_PAT2" "$HTML"
}

count_items() {
  grep -c "$ITEM_PAT\|$ITEM_PAT2" "$HTML"
}

list_items() {
  echo "=== Sal's Ironworks Gallery Items ==="
  echo ""
  local n=0
  grep_items | while IFS= read -r line; do
    n=$((n + 1))
    cat_match=$(echo "$line" | grep -o 'data-cat="[^"]*"' | sed 's/data-cat="//;s/"//' || echo "?")
    label_match=$(echo "$line" | grep -o 'data-label="[^"]*"' | sed 's/data-label="//;s/"//' || echo "?")
    img_match=$(echo "$line" | grep -o 'data-src="[^"]*"' | sed 's/data-src="//;s/"//' || echo "")
    vid_match=$(echo "$line" | grep -o 'data-video="[^"]*"' | sed 's/data-video="//;s/"//' || echo "")
    src="${img_match:-$vid_match}"
    printf "%3d. [%-12s] %-45s %s\n" "$n" "$cat_match" "$label_match" "$src"
  done || true
  echo ""
  echo "Total: $(count_items) items"
}

add_item() {
  local file="$1"
  local category="$2"
  local label="$3"
  local label_es="${4:-$label}"

  if [ ! -f "$file" ]; then
    echo "ERROR: File not found: $file"
    exit 1
  fi

  local ext="${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
  local basename=$(basename "$file")
  local dest="images/$basename"

  # Copy file to images/ if not already there
  if [ "$(realpath "$file" 2>/dev/null)" != "$(realpath "$dest" 2>/dev/null)" ]; then
    cp "$file" "$dest"
    echo "Copied $basename to images/"
  fi

  local is_video=false
  if [[ "$ext" == "mp4" || "$ext" == "mov" || "$ext" == "webm" ]]; then
    is_video=true
  fi

  local block
  if [ "$is_video" = true ]; then
    local mp4_dest="$dest"
    if [[ "$ext" != "mp4" ]]; then
      mp4_dest="images/${basename%.*}.mp4"
      ffmpeg -i "$dest" -c:v libx264 -preset fast -crf 23 -c:a aac -movflags +faststart "$mp4_dest" -y -loglevel error
      echo "Converted to mp4"
    fi

    local thumb="images/${basename%.*}_thumb.jpg"
    ffmpeg -i "$mp4_dest" -ss 1 -vframes 1 -q:v 2 "$thumb" -y -loglevel error
    echo "Generated thumbnail"

    block="      <div class=\"gallery-item gallery-video\" data-cat=\"${category},video\" data-video=\"${mp4_dest}\" data-label=\"${label}\" data-label-es=\"${label_es}\">
        <img src=\"${thumb}\" alt=\"${label}\" loading=\"lazy\">
        <div class=\"gallery-video-icon\">
          <svg width=\"48\" height=\"48\" viewBox=\"0 0 48 48\" fill=\"none\"><circle cx=\"24\" cy=\"24\" r=\"23\" fill=\"rgba(0,0,0,.6)\" stroke=\"#c4952b\" stroke-width=\"2\"/><polygon points=\"20,15 36,24 20,33\" fill=\"#c4952b\"/></svg>
        </div>
        <div class=\"gallery-item-overlay\"><span data-en=\"Video\" data-es=\"Video\">Video</span></div>
      </div>"
  else
    local overlay_en overlay_es
    case "$category" in
      gates) overlay_en="Gate"; overlay_es="Portón" ;;
      railings) overlay_en="Railing"; overlay_es="Barandal" ;;
      structural) overlay_en="Structural"; overlay_es="Estructural" ;;
      fences) overlay_en="Fence"; overlay_es="Cerca" ;;
      custom) overlay_en="Custom"; overlay_es="Personalizado" ;;
      *) overlay_en="$category"; overlay_es="$category" ;;
    esac

    block="      <div class=\"gallery-item\" data-cat=\"${category}\" data-src=\"${dest}\" data-label=\"${label}\" data-label-es=\"${label_es}\">
        <img src=\"${dest}\" alt=\"${label}\" loading=\"lazy\">
        <div class=\"gallery-item-overlay\"><span data-en=\"${overlay_en}\" data-es=\"${overlay_es}\">${overlay_en}</span></div>
      </div>"
  fi

  # Insert before CUSTOM FABRICATION comment
  local insert_line
  insert_line=$(grep -n "<!-- CUSTOM FABRICATION -->" "$HTML" | tail -1 | cut -d: -f1)

  if [ -z "$insert_line" ]; then
    echo "ERROR: Could not find insertion point in HTML"
    exit 1
  fi

  local tmpfile
  tmpfile=$(mktemp)
  head -n $((insert_line - 1)) "$HTML" > "$tmpfile"
  echo "$block" >> "$tmpfile"
  tail -n +$insert_line "$HTML" >> "$tmpfile"
  mv "$tmpfile" "$HTML"

  echo "✅ Added: $label ($category)"

  git add -A
  git commit -m "Add gallery item: $label ($category)"
  git push
  echo "🚀 Live on salsironworks.com!"
}

remove_items() {
  local numbers="$1"
  IFS=',' read -ra nums <<< "$numbers"

  # Sort descending
  local sorted=($(printf '%s\n' "${nums[@]}" | tr -d ' ' | sort -rn | uniq))

  local total
  total=$(count_items)
  local removed=()

  for n in "${sorted[@]}"; do
    if [ "$n" -lt 1 ] || [ "$n" -gt "$total" ]; then
      echo "WARNING: Item #$n out of range (1-$total), skipping"
      continue
    fi

    # Find the nth gallery-item opening div line number
    local lineno
    lineno=$(grep_items | sed -n "${n}p" | cut -d: -f1)

    if [ -z "$lineno" ]; then
      echo "WARNING: Could not find item #$n"
      continue
    fi

    local label
    label=$(sed -n "${lineno}p" "$HTML" | grep -o 'data-label="[^"]*"' | sed 's/data-label="//;s/"//' || echo "unknown")

    # Find end of this block — next gallery-item or HTML comment
    local next_line
    next_line=$(tail -n +$((lineno + 1)) "$HTML" | grep -n -m1 "$ITEM_PAT\|$ITEM_PAT2\|<!-- " | cut -d: -f1 || echo "")

    local end_line
    if [ -n "$next_line" ]; then
      end_line=$((lineno + next_line - 1))
    else
      end_line=$((lineno + 6))
    fi

    local tmpfile
    tmpfile=$(mktemp)
    sed "${lineno},${end_line}d" "$HTML" > "$tmpfile"
    mv "$tmpfile" "$HTML"

    removed+=("#$n: $label")
    total=$(count_items)
  done

  if [ ${#removed[@]} -eq 0 ]; then
    echo "No items removed."
    exit 1
  fi

  echo "✅ Removed ${#removed[@]} item(s):"
  printf '   %s\n' "${removed[@]}"

  git add -A
  git commit -m "Remove ${#removed[@]} gallery item(s): ${removed[*]}"
  git push
  echo "🚀 Live on salsironworks.com!"
}

case "${1:-}" in
  list)
    list_items
    ;;
  add)
    if [ $# -lt 4 ]; then
      echo "Usage: $0 add <file> <category> <label> [<label_es>]"
      echo "Categories: gates, railings, structural, fences, custom"
      exit 1
    fi
    add_item "$2" "$3" "$4" "${5:-$4}"
    ;;
  remove)
    if [ $# -lt 2 ]; then
      echo "Usage: $0 remove <number|n1,n2,n3>"
      exit 1
    fi
    remove_items "$2"
    ;;
  *)
    echo "Sal's Ironworks Site Admin"
    echo ""
    echo "Usage:"
    echo "  $0 list                              — List all gallery items"
    echo "  $0 add <file> <category> <label>     — Add image/video"
    echo "  $0 remove <number>                   — Remove item by number"
    echo "  $0 remove <n1,n2,n3>                 — Remove multiple items"
    echo ""
    echo "Categories: gates, railings, structural, fences, custom"
    ;;
esac
