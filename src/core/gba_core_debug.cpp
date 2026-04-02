#if defined(GBA_CORE_USE_AGGREGATED_MODULES) && GBAEMU_ENABLE_DEBUG_FEATURES
#define GBA_CORE_MODULE_COMPILED_FROM_AGGREGATE 1
#include "./gba_core_modules/core_save_debug.c"
#include "./gba_core_modules/render_debug.c"
#undef GBA_CORE_MODULE_COMPILED_FROM_AGGREGATE
#endif
