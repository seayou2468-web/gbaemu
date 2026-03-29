import sys
path = "utils/testroms/test1.gba"
with open(path, "rb") as f:
    rom = f.read()

logo = rom[4:4+156]
# Standard logo hash
import hashlib
print(f"Logo Hash: {hashlib.md5(logo).hexdigest()}")

complement = rom[0xBD]
sum_val = sum(rom[0xA0:0xBD])
calc = (-sum_val - 0x19) & 0xFF
print(f"Header Complement: {complement:02X}, Calculated: {calc:02X}")
