#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MOD_DIR="$ROOT_DIR/src/core/gba_core_modules"

required_files=(
  core_bootstrap.c
  core_reset_state.c
  core_save_debug.c
  core_backup_runtime.c
  cpu_helpers.c
  cpu_swi.c
  cpu_arm_execute.c
  cpu_thumb_run.c
  memory_bus.c
  ppu_common.c
  ppu_bitmap_obj.c
  ppu_tile_modes.c
  timing_dma.c
  apu_interrupts.c
  render_debug.c
  hlebios.s
)

for file in "${required_files[@]}"; do
  path="$MOD_DIR/$file"
  if [[ ! -f "$path" ]]; then
    echo "[ERROR] missing required migrated file: $path" >&2
    exit 1
  fi
  if [[ ! -s "$path" ]]; then
    echo "[ERROR] empty required migrated file: $path" >&2
    exit 1
  fi
done

import_count=$(rg -n "Imported from reference implementation" "$MOD_DIR"/*.c | wc -l | tr -d ' ')
if [[ "$import_count" != "29" ]]; then
  echo "[ERROR] import marker count mismatch: expected=29 actual=$import_count" >&2
  exit 1
fi

echo "[OK] migration lock verified (required files exist, non-empty, markers=29)"
