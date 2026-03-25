# Vendored mGBA sources (CPU/GBA core migration base)

This directory vendors core mGBA sources to accelerate migration of this emulator toward mGBA behavior.

- Upstream repository: https://github.com/mgba-emu/mgba
- Upstream commit: `93fed7144836d20c9087ae88bc67dfdde834db9d`
- Copied on: 2026-03-25

## Included subsets

- `src/arm` (ARM7TDMI core logic)
- `src/gba` (GBA platform core, BIOS/SWI/PPU/DMA/IRQ paths)
- `include/mgba/internal/arm`
- `include/mgba/internal/gba`
- upstream `LICENSE`

## Purpose

These files are currently imported as a reference/migration base for staged integration.
They are not yet wired as the active runtime backend in `src/core/*`.

The next migration steps are:

1. replace `src/core/gba_core_cpu.cpp` decode/execute paths with mGBA ARM/Thumb dispatch,
2. replace `StepPpu`/`StepDma` timing loops with mGBA scheduler/event model,
3. swap BIOS SWI/HLE handling to mGBA's BIOS path and remove duplicated local HLE code.
