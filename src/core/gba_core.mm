// Optional unified Objective-C++ core implementation entry point.
//
// Default behavior keeps this translation unit empty because the build compiles
// files in src/core/gba_core_modules/*.mm as standalone translation units.
//
// If a target wants a single aggregated TU build, define
// GBA_CORE_USE_AGGREGATED_MODULES for this file.

#if defined(GBA_CORE_USE_AGGREGATED_MODULES)
#include "gba_core_modules/core_bootstrap.mm"
#include "gba_core_modules/core_reset_state.mm"
#include "gba_core_modules/core_save_debug.mm"
#include "gba_core_modules/core_backup_runtime.mm"
#include "gba_core_modules/cpu_helpers.mm"
#include "gba_core_modules/cpu_swi.mm"
#include "gba_core_modules/cpu_arm_execute.mm"
#include "gba_core_modules/cpu_thumb_run.mm"
#include "gba_core_modules/memory_bus.mm"
#include "gba_core_modules/ppu_common.mm"
#include "gba_core_modules/ppu_bitmap_obj.mm"
#include "gba_core_modules/ppu_tile_modes.mm"
#include "gba_core_modules/timing_dma.mm"
#include "gba_core_modules/apu_interrupts.mm"
#include "gba_core_modules/render_debug.mm"
#endif
