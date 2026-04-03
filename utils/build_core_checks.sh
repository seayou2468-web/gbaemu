#!/usr/bin/env bash
set -euo pipefail

g++ -std=c++17 -fsyntax-only src/core/gba_core.cpp
g++ -std=c++17 -fsyntax-only src/core/gba_core_modules/core_overrides_runtime.c
for module in src/core/gba_core_modules/*.c; do
  clang -std=c11 -I. -fsyntax-only "$module"
done

g++ -std=c++17 -I. utils/gba_test_runner.cpp src/core/gba_core_c_api.c -o /tmp/gba_test_runner
g++ -std=c++17 -I. utils/linux_core_smoke.cpp src/core/gba_core_c_api.c -o /tmp/linux_core_smoke
g++ -std=c++17 -I. utils/rom_trace_smoke.cpp src/core/gba_core_c_api.c -o /tmp/rom_trace_smoke

echo "core build checks: OK"
