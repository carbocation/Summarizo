#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/ZoteroPlugin"
RESOURCE_DIR="$ROOT/Sources/Summarizo/Resources/Zotero"
OUTPUT_NAME="Summarizo Zotero Importer.xpi"
OUTPUT="${1:-$RESOURCE_DIR/$OUTPUT_NAME}"

required_files=(
  "manifest.json"
  "bootstrap.js"
  "summarizo-plugin.js"
  "summarizo-core.js"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$PLUGIN_DIR/$file" ]]; then
    echo "Missing Zotero plugin file: $PLUGIN_DIR/$file" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"

(
  cd "$PLUGIN_DIR"
  /usr/bin/zip -q -X "$OUTPUT" "${required_files[@]}"
)

echo "Built $OUTPUT"
