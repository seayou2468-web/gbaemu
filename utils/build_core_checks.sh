#!/usr/bin/env bash
set -euo pipefail

g++ -std=c++17 -I. -fsyntax-only src/core/gba_core.cpp
g++ -std=c++17 -I. -fsyntax-only src/core/gba_core_c_api.cpp
gcc -std=gnu11 -DPC_BUILD -I. -fsyntax-only src/core/gba_core_modules/core_input_runtime.c
gcc -std=gnu11 -DPC_BUILD -I. -fsyntax-only src/core/gba_core_modules/core_io_runtime.c

echo "core build checks: OK"
