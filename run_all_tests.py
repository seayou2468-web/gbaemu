import os
import subprocess

tests = [
    "gba-tests/arm/arm.gba",
    "gba-tests/thumb/thumb.gba",
    "gba-tests/ppu/hello.gba"
]

for t in tests:
    if os.path.exists(t):
        print(f"Testing {t}...")
        try:
            # Run for 2 seconds
            res = subprocess.run(["./run_test", t], capture_output=True, text=True, timeout=2)
            print(res.stdout)
        except subprocess.TimeoutExpired:
            print(f"Timeout running {t}")
        except Exception as e:
            print(f"Error: {e}")
