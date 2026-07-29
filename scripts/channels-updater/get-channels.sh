#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <folder-path>"
  exit 1
fi

if [ ! -d "$1" ]; then
  echo "Error: '$1' is not a valid directory"
  exit 1
fi

output_file="operators-current-channels.out"
> "$output_file"

find "$1" -name 'patch-version.yaml' -print0 | while IFS= read -r -d '' file; do
  operator=$(basename "$(dirname "$(dirname "$file")")")
  channel=$(grep 'value:' "$file" | head -1 | sed 's/^.*value: *//')
  echo "$operator, $channel" >> "$output_file"
done

sort -o "$output_file" "$output_file"

echo "Output written to $output_file ($(wc -l < "$output_file") operators found)"
