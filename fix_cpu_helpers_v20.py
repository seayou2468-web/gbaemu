import sys
import re

path = "src/core/gba_core_modules/cpu_helpers.mm"
with open(path, "r") as f:
    c = f.read()

new_apply_shift = """uint32_t GBACore::ApplyShift(uint32_t value,
                             uint32_t shift_type,
                             uint32_t shift_amount,
                             bool* carry_out) const {
  if (!carry_out) return value;
  if (shift_amount == 0) {
    *carry_out = GetFlagC();
    return value;
  }
  switch (shift_type & 0x3u) {
    case 0: { // LSL
      if (shift_amount < 32) {
        *carry_out = ((value >> (32u - shift_amount)) & 1u) != 0;
        return value << shift_amount;
      }
      if (shift_amount == 32) {
        *carry_out = (value & 1u) != 0;
        return 0;
      }
      *carry_out = false;
      return 0;
    }
    case 1: { // LSR
      if (shift_amount < 32) {
        *carry_out = ((value >> (shift_amount - 1u)) & 1u) != 0;
        return value >> shift_amount;
      }
      if (shift_amount == 32) {
        *carry_out = (value >> 31) != 0;
        return 0;
      }
      *carry_out = false;
      return 0;
    }
    case 2: { // ASR
      if (shift_amount < 32) {
        *carry_out = ((value >> (shift_amount - 1u)) & 1u) != 0;
        return static_cast<uint32_t>(static_cast<int32_t>(value) >> shift_amount);
      }
      *carry_out = (value >> 31) != 0;
      return (value & 0x80000000u) ? 0xFFFFFFFFu : 0u;
    }
    case 3: { // ROR
      uint32_t rot = shift_amount & 31u;
      if (rot == 0) {
        // RRX behavior for ROR #0
        *carry_out = (value & 1u) != 0;
        return (value >> 1) | (GetFlagC() ? 0x80000000u : 0u);
      }
      uint32_t result = RotateRight(value, rot);
      *carry_out = (result >> 31) != 0;
      return result;
    }
    default:
      return value;
  }
}"""

c = re.sub(r"uint32_t GBACore::ApplyShift\(.*?\)\s*const\s*\{.*?^\}", new_apply_shift, c, flags=re.DOTALL | re.MULTILINE)

with open(path, "w") as f:
    f.write(c)
