#include "trace.h"
#include <cstdio>

#if ENABLE_TRACE

void DumpTrace(const char* path) {
  FILE* f = fopen(path, "w");
  if (!f) return;

  for (uint32_t i = 0; i < TRACE_BUFFER_SIZE; i++) {
    const auto& e = g_trace_buffer[i];
    fprintf(f, "%u %08X %08X %08X\n",
            (uint32_t)e.type,
            e.addr,
            e.value,
            e.pc);
  }

  fclose(f);
}

#endif
