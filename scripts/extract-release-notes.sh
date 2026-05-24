#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <tag-name> <output-file>" >&2
  exit 2
fi

TAG_NAME="$1"
OUTPUT_FILE="$2"
VERSION="${TAG_NAME#v}"
CHANGELOG="${CHANGELOG:-CHANGELOG.md}"

if [[ ! -f "$CHANGELOG" ]]; then
  echo "Missing changelog: $CHANGELOG" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

awk -v tag="$TAG_NAME" -v version="$VERSION" '
  /^##[[:space:]]+/ {
    if (found) {
      exit
    }
    heading = $0
    sub(/^##[[:space:]]+/, "", heading)
    split(heading, parts, /[[:space:]]+/)
    release = parts[1]
    found = (release == tag || release == version || release == "v" version)
    next
  }
  found {
    print
  }
' "$CHANGELOG" > "$OUTPUT_FILE"

if [[ ! -s "$OUTPUT_FILE" ]]; then
  echo "No release notes found for $TAG_NAME in $CHANGELOG" >&2
  exit 1
fi
