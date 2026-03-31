#pragma once
#include <cstdint>

#ifndef ENABLE_TRACE
#define ENABLE_TRACE 0
#endif

#if ENABLE_TRACE

// ログ種別
enum class TraceType : uint8_t {
  READ8,
  READ16,
  READ32,
  WRITE8,
  WRITE16,
  WRITE32,
  IO_READ,
  IO_WRITE,
  DMA,
};

// 1ログ構造（固定サイズで高速）
struct TraceEntry {
  TraceType type;
  uint32_t addr;
  uint32_t value;
  uint32_t pc;
};

constexpr size_t TRACE_BUFFER_SIZE = 1 << 20;

extern TraceEntry g_trace_buffer[TRACE_BUFFER_SIZE];
extern uint32_t g_trace_index;

// 記録
inline void TraceLog(TraceType type, uint32_t addr, uint32_t value, uint32_t pc) {
  uint32_t idx = g_trace_index++ & (TRACE_BUFFER_SIZE - 1);
  g_trace_buffer[idx] = {type, addr, value, pc};
}

#else

inline void TraceLog(...) {}

#endif
