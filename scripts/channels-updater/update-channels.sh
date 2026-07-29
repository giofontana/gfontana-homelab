#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <folder-path> <input-file>"
  exit 1
fi

if [ ! -d "$1" ]; then
  echo "Error: '$1' is not a valid directory"
  exit 1
fi

if [ ! -f "$2" ]; then
  echo "Error: '$2' is not a valid file"
  exit 1
fi

folder="$1"
input_file="$2"
changed_files=()

while IFS= read -r line; do
  [ -z "$line" ] && continue

  operator=$(echo "$line" | cut -d',' -f1 | xargs)
  new_channel=$(echo "$line" | cut -d',' -f2 | xargs)

  patch_file=$(find "$folder" -path "*/${operator}/operator/patch-version.yaml" -print -quit)

  if [ -z "$patch_file" ]; then
    echo "WARN: No patch-version.yaml found for '$operator', skipping"
    continue
  fi

  current_channel=$(grep 'value:' "$patch_file" | head -1 | sed 's/^.*value: *//')

  if [ "$current_channel" != "$new_channel" ]; then
    sed -i "s|value: ${current_channel}|value: ${new_channel}|" "$patch_file"
    changed_files+=("$patch_file")
    echo "UPDATED: $operator ($current_channel -> $new_channel)"
  fi
done < "$input_file"

echo ""
if [ ${#changed_files[@]} -eq 0 ]; then
  echo "No changes needed — all channels are up to date."
else
  echo "=== Changed files (${#changed_files[@]}) ==="
  for f in "${changed_files[@]}"; do
    echo "  $f"
  done
fi
