#include "trace.h"

#if ENABLE_TRACE

TraceEntry g_trace_buffer[TRACE_BUFFER_SIZE];
uint32_t g_trace_index = 0;

#endif
