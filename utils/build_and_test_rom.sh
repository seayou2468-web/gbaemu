#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OBJ_DIR="${ROOT_DIR}/.tmp/gbaobj"
OUT_BIN="${ROOT_DIR}/.tmp/gba_test_runner"
OUT_PNG="${ROOT_DIR}/.tmp/testrom_frame.png"

mkdir -p "${ROOT_DIR}/.tmp" "${OBJ_DIR}"
rm -f "${OBJ_DIR}"/*.o "${OUT_BIN}" "${OUT_PNG}"

for f in "${ROOT_DIR}"/src/core/gba_core_modules/*.c; do
  gcc -std=gnu11 -DPC_BUILD -I"${ROOT_DIR}" -c "$f" \
    -o "${OBJ_DIR}/$(basename "$f" .c).o"
done

g++ -std=c++17 -DPC_BUILD -I"${ROOT_DIR}" \
  -c "${ROOT_DIR}/src/core/gba_core.cpp" \
  -o "${OBJ_DIR}/gba_core.o"

g++ -std=c++17 -DPC_BUILD -I"${ROOT_DIR}" \
  -c "${ROOT_DIR}/src/core/gba_core_c_api.cpp" \
  -o "${OBJ_DIR}/gba_core_c_api.o"

g++ -std=c++17 -DPC_BUILD -I"${ROOT_DIR}" \
  -c "${ROOT_DIR}/utils/gba_test_runner.cpp" \
  -o "${OBJ_DIR}/gba_test_runner.o"

g++ "${OBJ_DIR}"/*.o -lm -o "${OUT_BIN}"

"${OUT_BIN}" \
  "${ROOT_DIR}/utils/testroms/test1.gba" \
  5 \
  "${OUT_PNG}" \
  "${ROOT_DIR}/utils/bios/ababios.bin"

echo "ROM test completed: ${OUT_PNG}"
