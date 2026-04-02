
#if defined(GBA_CORE_USE_AGGREGATED_MODULES)
#define GBA_CORE_MODULE_COMPILED_FROM_AGGREGATE 1
#include "./gba_core_modules/core_bootstrap.c"
#include "./gba_core_modules/core_reset_state.c"
#include "./gba_core_modules/core_save_debug.c"
#include "./gba_core_modules/core_backup_runtime.c"
#include "./gba_core_modules/cpu_helpers.c"
#include "./gba_core_modules/cpu_swi.c"
#include "./gba_core_modules/cpu_arm_execute.c"
#include "./gba_core_modules/cpu_thumb_run.c"
#include "./gba_core_modules/memory_bus.c"
#include "./gba_core_modules/ppu_cocon.c"
#include "./gba_core_modules/ppu_bitmap_obj.c"
#include "./gba_core_modules/ppu_tile_modes.c"
#include "./gba_core_modules/timing_dma.c"
#include "./gba_core_modules/apu_interrupts.c"
#include "./gba_core_modules/render_debug.c"
#undef GBA_CORE_MODULE_COMPILED_FROM_AGGREGATE
#endif
