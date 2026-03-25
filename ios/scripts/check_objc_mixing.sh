#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET_DIR="$ROOT_DIR/ios/GBAEmuApp"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "target directory not found: $TARGET_DIR" >&2
  exit 1
fi

# C++-like tokens that should not appear in pure Objective-C (.m/.h) files.
CPP_TOKENS='std::|\bgba::|\bnamespace\b|\btemplate\s*<|<vector>|<string>|\bnew\s+\w+::|\bdelete\b|\bnullptr\b'

failed=0

if find "$TARGET_DIR" -type f -name "*.mm" | rg -n "." >/dev/null; then
  echo "[NG] Objective-C++ (.mm) file found under ios app sources." >&2
  find "$TARGET_DIR" -type f -name "*.mm"
  exit 3
fi

while IFS= read -r file; do
  if rg -n -e "$CPP_TOKENS" "$file" >/dev/null; then
    echo "[NG] C++ token found in Objective-C file: ${file#$ROOT_DIR/}"
    rg -n -e "$CPP_TOKENS" "$file"
    failed=1
  fi
done < <(find "$TARGET_DIR" -type f \( -name '*.m' -o -name '*.h' \))


if [[ "$failed" -ne 0 ]]; then
  echo "Objective-C/Objective-C++ extension mixing check failed." >&2
  exit 2
fi

echo "OK: No C++ token leakage into .m/.h files under ios/GBAEmuApp"
