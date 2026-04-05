#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/.tmp"
BIN="${OUT_DIR}/gba_test_runner"
ROM1="${ROOT_DIR}/utils/testroms/test1.gba"
ROM2="${ROOT_DIR}/utils/testroms/test2.gba"
BIOS="${ROOT_DIR}/utils/bios/ababios.bin"

bash "${ROOT_DIR}/utils/build_and_test_rom.sh" >/dev/null

"${BIN}" "${ROM1}" 300 "${OUT_DIR}/test1_300.png" "${BIOS}" >/dev/null
"${BIN}" "${ROM2}" 300 "${OUT_DIR}/test2_300.png" "${BIOS}" >/dev/null

h1=$(sha256sum "${OUT_DIR}/testrom_frame.png" | awk '{print $1}')
h2=$(sha256sum "${OUT_DIR}/test1_300.png" | awk '{print $1}')
h3=$(sha256sum "${OUT_DIR}/test2_300.png" | awk '{print $1}')

echo "hash(test1,5f)   = ${h1}"
echo "hash(test1,300f) = ${h2}"
echo "hash(test2,300f) = ${h3}"

if [[ "${h1}" == "${h2}" && "${h2}" == "${h3}" ]]; then
  echo "render_progress: NG (all frames identical)"
  exit 1
fi

echo "render_progress: OK (frame outputs differ)"
