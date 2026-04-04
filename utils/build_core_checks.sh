#!/usr/bin/env bash
set -euo pipefail

g++ -std=c++17 -I. -fsyntax-only src/core/gba_core.cpp
g++ -std=c++17 -I. -fsyntax-only src/core/gba_core_modules/core_overrides_runtime.c
for module in src/core/gba_core_modules/*.c; do
  clang -std=c11 -I. -fsyntax-only "$module"
done

g++ -std=c++17 -no-pie -I. \
  utils/gba_test_runner.cpp \
  src/core/gba_core.cpp \
  src/core/gba_core_c_api.cpp \
  src/core/gba_core_modules/apu_blip_buffer.cpp \
  src/core/gba_core_modules/apu_multi_buffer.cpp \
  src/core/gba_core_modules/apu_effects_buffer.cpp \
  src/core/gba_core_modules/apu_gb_oscs.cpp \
  src/core/gba_core_modules/apu_gb_apu.cpp \
  src/core/gba_core_modules/apu_gb_apu_state.cpp \
  -o /tmp/gba_test_runner
g++ -std=c++17 -no-pie -I. \
  utils/linux_core_smoke.cpp \
  src/core/gba_core.cpp \
  src/core/gba_core_c_api.cpp \
  src/core/gba_core_modules/apu_blip_buffer.cpp \
  src/core/gba_core_modules/apu_multi_buffer.cpp \
  src/core/gba_core_modules/apu_effects_buffer.cpp \
  src/core/gba_core_modules/apu_gb_oscs.cpp \
  src/core/gba_core_modules/apu_gb_apu.cpp \
  src/core/gba_core_modules/apu_gb_apu_state.cpp \
  -o /tmp/linux_core_smoke
g++ -std=c++17 -no-pie -I. \
  utils/rom_trace_smoke.cpp \
  src/core/gba_core.cpp \
  src/core/gba_core_c_api.cpp \
  src/core/gba_core_modules/apu_blip_buffer.cpp \
  src/core/gba_core_modules/apu_multi_buffer.cpp \
  src/core/gba_core_modules/apu_effects_buffer.cpp \
  src/core/gba_core_modules/apu_gb_oscs.cpp \
  src/core/gba_core_modules/apu_gb_apu.cpp \
  src/core/gba_core_modules/apu_gb_apu_state.cpp \
  -o /tmp/rom_trace_smoke

echo "core build checks: OK"
