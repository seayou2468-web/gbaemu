#ifndef AURORA_INTERNAL_DEBUGGER_SYMBOLS_H
#define AURORA_INTERNAL_DEBUGGER_SYMBOLS_H

#include <stdint.h>

struct mDebuggerSymbols;
const char* mDebuggerSymbolReverseLookup(const struct mDebuggerSymbols* symbols, uint32_t addr, int* offset);

#endif
