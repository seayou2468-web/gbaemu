#include "trace.h"
#include <cstdio>

void DumpTrace() {
#if ENABLE_TRACE
  for (uint32_t i = 0; i < TRACE_BUFFER_SIZE; i++) {
    const TraceEntry& e = g_trace_buffer[i];
    if (e.addr == 0 && e.value == 0 && e.pc == 0) continue;

    printf("[%u] type=%d addr=%08X value=%08X pc=%08X\n",
           i,
           static_cast<int>(e.type),
           e.addr,
           e.value,
           e.pc);
  }
#endif
}
