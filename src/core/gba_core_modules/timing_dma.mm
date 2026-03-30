#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

// =========================================================================
// PPU ステップ (スキャンライン精度)
// =========================================================================
void GBACore::StepPpu(uint32_t cycles) {
  constexpr uint32_t kHDrawCycles     = mgba_compat::kVideoHDrawCycles;   // 1006
  constexpr uint32_t kScanlineCycles  = mgba_compat::kVideoScanlineCycles; // 1232
  constexpr uint32_t kTotalLines      = mgba_compat::kVideoTotalLines;     // 228
  constexpr uint32_t kVisibleLines    = mgba_compat::kVideoVisibleLines;   // 160

  // io_regs_ への直接書き込み (WriteIO16の副作用なし)
  auto poke16 = [&](uint32_t addr, uint16_t val) {
    const size_t off = static_cast<size_t>(addr - 0x04000000u);
    if (off + 1u < io_regs_.size()) {
      io_regs_[off]   = static_cast<uint8_t>(val & 0xFFu);
      io_regs_[off+1] = static_cast<uint8_t>((val >> 8) & 0xFFu);
    }
  };
  auto peek16 = [&](uint32_t addr) -> uint16_t {
    const size_t off = static_cast<size_t>(addr - 0x04000000u);
    if (off + 1u >= io_regs_.size()) return 0;
    return static_cast<uint16_t>(io_regs_[off]) | (static_cast<uint16_t>(io_regs_[off+1]) << 8);
  };

  uint32_t remaining = cycles;
  while (remaining > 0) {
    const uint16_t dispstat = peek16(0x04000004u);
    const uint16_t vcount   = peek16(0x04000006u);
    const bool in_hblank    = (dispstat & 0x0002u) != 0;

    // 次のイベントまでのサイクル数
    uint32_t dist;
    if (!in_hblank) {
      // HDraw期間: HBlank開始まで
      dist = (ppu_cycle_accum_ < kHDrawCycles)
             ? (kHDrawCycles - ppu_cycle_accum_) : 1u;
    } else {
      // HBlank期間: 次のスキャンライン開始まで
      dist = (ppu_cycle_accum_ < kScanlineCycles)
             ? (kScanlineCycles - ppu_cycle_accum_) : 1u;
    }
    const uint32_t step = std::min(remaining, dist);
    ppu_cycle_accum_ += step;
    remaining -= step;

    // ---- HBlank 開始 (1006サイクル経過) ----
    if (!in_hblank && ppu_cycle_accum_ >= kHDrawCycles) {
    // HDraw完了: アフィン参照点をラインバッファに保存
    if (vcount < kVisibleLines) {
        bg2_refx_line_[vcount] = bg2_refx_internal_;
        bg2_refy_line_[vcount] = bg2_refy_internal_;
        bg3_refx_line_[vcount] = bg3_refx_internal_;
        bg3_refy_line_[vcount] = bg3_refy_internal_;
        affine_line_captured_[vcount] = 1;
        affine_line_refs_valid_ = true;
    }

    // HBlankフラグセット
    uint16_t ds = peek16(0x04000004u);
    ds |= 0x0002u;  // HBlank flag set
    poke16(0x04000004u, ds);

    // HBlank IRQ
    if (ds & (1u << 4)) RaiseInterrupt(1u << 1);

    // HBlank DMA
    if (vcount < kVisibleLines) {
        StepDmaHBlank();
    }
}

    // ---- スキャンライン終了 (1232サイクル経過) ----
    if (ppu_cycle_accum_ >= kScanlineCycles) {
      ppu_cycle_accum_ = 0;

      const uint16_t cur_vcount = peek16(0x04000006u);
      const uint16_t next_vcount = static_cast<uint16_t>((cur_vcount + 1u) % kTotalLines);
      poke16(0x04000006u, next_vcount);

      // HBlank フラグをクリア
      uint16_t ds = peek16(0x04000004u);
      ds &= ~0x0002u;

      // VBlank 制御
      const bool was_vblank = (ds & 0x0001u) != 0;
      const bool now_vblank = (next_vcount >= kVisibleLines && next_vcount < kTotalLines - 1u);

      if (now_vblank) {
        ds |= 0x0001u;
        if (!was_vblank) {
          // VBlank 開始
          if (ds & (1u << 3)) RaiseInterrupt(1u << 0);
          poke16(0x04000004u, ds);
          // VBlank DMA 発火
          StepDmaVBlank();
          // アフィン参照点をリロード (次フレーム用: 次のフレーム開始はline=0)
        }
      } else {
        ds &= ~0x0001u;
      }

      // VCount Compare
      const uint16_t lyc = static_cast<uint16_t>((ds >> 8) & 0xFFu);
      if (next_vcount == lyc) {
        if (!(ds & 0x0004u) && (ds & (1u << 5))) RaiseInterrupt(1u << 2);
        ds |= 0x0004u;
      } else {
        ds &= ~0x0004u;
      }
      poke16(0x04000004u, ds);

      // ライン=0: アフィン参照点リロード
      if (next_vcount == 0) {
        auto rb28 = [&](uint32_t addr) -> int32_t {
          uint32_t r = ReadIO16(addr) | (static_cast<uint32_t>(ReadIO16(addr + 2u)) << 16);
          r &= 0x0FFFFFFFu;
          return static_cast<int32_t>(r << 4) >> 4;
        };
        bg2_refx_internal_ = rb28(0x04000028u);
        bg2_refy_internal_ = rb28(0x0400002Cu);
        bg3_refx_internal_ = rb28(0x04000038u);
        bg3_refy_internal_ = rb28(0x0400003Cu);
        affine_line_refs_valid_ = false;
        std::fill(affine_line_captured_.begin(), affine_line_captured_.end(), 0);
      } else {
        // 各ライン終端: アフィン参照点を PB/PD ずつ進める
        const int16_t pb2 = static_cast<int16_t>(ReadIO16(0x04000022u));
        const int16_t pd2 = static_cast<int16_t>(ReadIO16(0x04000026u));
        const int16_t pb3 = static_cast<int16_t>(ReadIO16(0x04000032u));
        const int16_t pd3 = static_cast<int16_t>(ReadIO16(0x04000036u));
        bg2_refx_internal_ += pb2;
        bg2_refy_internal_ += pd2;
        bg3_refx_internal_ += pb3;
        bg3_refy_internal_ += pd3;
      }

      // アフィン参照点をラインバッファに保存
      if (next_vcount < kTotalLines) {
        bg2_refx_line_[next_vcount] = bg2_refx_internal_;
        bg2_refy_line_[next_vcount] = bg2_refy_internal_;
        bg3_refx_line_[next_vcount] = bg3_refx_internal_;
        bg3_refy_line_[next_vcount] = bg3_refy_internal_;
        if (next_vcount < kVisibleLines) {
          affine_line_captured_[next_vcount] = 1;
          affine_line_refs_valid_ = true;
        }
      }
    }
  }
}

// =========================================================================
// タイマー ステップ
// =========================================================================
void GBACore::StepTimers(uint32_t cycles) {
  static constexpr uint32_t kPrescalerLut[4] = {1u, 64u, 256u, 1024u};

  auto write_timer_counter = [&](size_t idx, uint16_t val) {
    const size_t off = 0x100u + idx * 4u;
    if (off + 1u < io_regs_.size()) {
      io_regs_[off]   = static_cast<uint8_t>(val & 0xFFu);
      io_regs_[off+1] = static_cast<uint8_t>((val >> 8) & 0xFFu);
    }
  };

  for (uint32_t c = 0; c < cycles; ++c) {
    bool overflowed[4] = {};

    for (int i = 0; i < 4; ++i) {
      TimerState& t = timers_[i];
      if (!(t.control & 0x80u)) continue;  // タイマー停止

      bool tick = false;
      if (i > 0 && (t.control & 0x04u)) {
        // カスケードモード: 前のタイマーオーバーフローで進む
        if (overflowed[i-1]) tick = true;
      } else {
        // プリスケーラーモード
        const uint32_t ps = kPrescalerLut[t.control & 3u];
        if (++t.prescaler_accum >= ps) {
          t.prescaler_accum = 0;
          tick = true;
        }
      }

      if (tick) {
        if (++t.counter == 0u) {
          // オーバーフロー
          t.counter = t.reload;
          overflowed[i] = true;
          // IRQ
          if (t.control & 0x40u) RaiseInterrupt(1u << (3 + i));
          // Audio FIFO 消費
          ConsumeAudioFifoOnTimer(static_cast<size_t>(i));
        }
        write_timer_counter(static_cast<size_t>(i), t.counter);
      }
    }
  }
}

// =========================================================================
// DMA 実行ヘルパー
// =========================================================================
static inline uint32_t dma_addr_mask(int ch) {
  return (ch == 0) ? 0x07FFFFFFu : 0x0FFFFFFFu;
}

void GBACore::StepDma() {
  // 即時起動 (start_timing=0) DMAのみ処理
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t cnt_base = 0x040000B0u + static_cast<uint32_t>(ch) * 12u;
    const uint16_t cnt_h = ReadIO16(cnt_base + 10u);
    if (!(cnt_h & 0x8000u)) { dma_shadows_[ch].active = false; continue; }
    const uint16_t start_timing = (cnt_h >> 12) & 0x3u;
    if (start_timing != 0u) continue;  // 即時以外はスキップ

    // シャドウDMA未初期化なら初期化
    if (!dma_shadows_[ch].active) {
      auto read_io32 = [&](size_t o) -> uint32_t {
        if (o + 3u >= io_regs_.size()) return 0;
        return static_cast<uint32_t>(io_regs_[o]) |
               (static_cast<uint32_t>(io_regs_[o+1]) << 8) |
               (static_cast<uint32_t>(io_regs_[o+2]) << 16) |
               (static_cast<uint32_t>(io_regs_[o+3]) << 24);
      };
      const size_t boff = static_cast<size_t>(cnt_base - 0x04000000u);
      dma_shadows_[ch].sad = read_io32(boff);
      dma_shadows_[ch].dad = read_io32(boff + 4u);
      dma_shadows_[ch].initial_dad = dma_shadows_[ch].dad;
      uint32_t c = static_cast<uint32_t>(io_regs_[boff+8]) |
                   (static_cast<uint32_t>(io_regs_[boff+9]) << 8);
      if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
      dma_shadows_[ch].initial_count = c;
      dma_shadows_[ch].count = c;
      dma_shadows_[ch].active = true;
    }

    ExecuteDmaTransfer(ch, cnt_h);
  }
}

void GBACore::StepDmaVBlank() {
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t cnt_base = 0x040000B0u + static_cast<uint32_t>(ch) * 12u;
    const uint16_t cnt_h = ReadIO16(cnt_base + 10u);
    if (!(cnt_h & 0x8000u)) continue;
    const uint16_t start_timing = (cnt_h >> 12) & 0x3u;
    if (start_timing != 1u) continue;  // VBlank起動以外はスキップ
    if (!dma_shadows_[ch].active) {
      // シャドウ再初期化
      auto read_io32 = [&](size_t o) -> uint32_t {
        if (o + 3u >= io_regs_.size()) return 0;
        return static_cast<uint32_t>(io_regs_[o]) |
               (static_cast<uint32_t>(io_regs_[o+1]) << 8) |
               (static_cast<uint32_t>(io_regs_[o+2]) << 16) |
               (static_cast<uint32_t>(io_regs_[o+3]) << 24);
      };
      const size_t boff = static_cast<size_t>(cnt_base - 0x04000000u);
      dma_shadows_[ch].sad = read_io32(boff);
      dma_shadows_[ch].dad = read_io32(boff + 4u);
      dma_shadows_[ch].initial_dad = dma_shadows_[ch].dad;
      uint32_t c = static_cast<uint32_t>(io_regs_[boff+8]) |
                   (static_cast<uint32_t>(io_regs_[boff+9]) << 8);
      if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
      dma_shadows_[ch].initial_count = c;
      dma_shadows_[ch].count = c;
      dma_shadows_[ch].active = true;
    }
    ExecuteDmaTransfer(ch, cnt_h);
  }
}

void GBACore::StepDmaHBlank() {
  for (int ch = 0; ch < 4; ++ch) {
    const uint32_t cnt_base = 0x040000B0u + static_cast<uint32_t>(ch) * 12u;
    const uint16_t cnt_h = ReadIO16(cnt_base + 10u);
    if (!(cnt_h & 0x8000u)) continue;
    const uint16_t start_timing = (cnt_h >> 12) & 0x3u;
    if (start_timing != 2u) continue;  // HBlank起動以外はスキップ
    if (!dma_shadows_[ch].active) {
      auto read_io32 = [&](size_t o) -> uint32_t {
        if (o + 3u >= io_regs_.size()) return 0;
        return static_cast<uint32_t>(io_regs_[o]) |
               (static_cast<uint32_t>(io_regs_[o+1]) << 8) |
               (static_cast<uint32_t>(io_regs_[o+2]) << 16) |
               (static_cast<uint32_t>(io_regs_[o+3]) << 24);
      };
      const size_t boff = static_cast<size_t>(cnt_base - 0x04000000u);
      dma_shadows_[ch].sad = read_io32(boff);
      dma_shadows_[ch].dad = read_io32(boff + 4u);
      dma_shadows_[ch].initial_dad = dma_shadows_[ch].dad;
      uint32_t c = static_cast<uint32_t>(io_regs_[boff+8]) |
                   (static_cast<uint32_t>(io_regs_[boff+9]) << 8);
      if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
      dma_shadows_[ch].initial_count = c;
      dma_shadows_[ch].count = c;
      dma_shadows_[ch].active = true;
    }
    ExecuteDmaTransfer(ch, cnt_h);
  }
}

void GBACore::ExecuteDmaTransfer(int ch, uint16_t cnt_h) {
  const uint32_t cnt_base = 0x040000B0u + static_cast<uint32_t>(ch) * 12u;
  const bool word32  = (cnt_h & 0x0400u) != 0;
  const bool repeat  = (cnt_h & 0x0200u) != 0;
  const uint32_t start_timing = (cnt_h >> 12) & 0x3u;
  const int dst_ctl  = (cnt_h >> 5) & 0x3;
  const int src_ctl  = (cnt_h >> 7) & 0x3;
  const uint32_t mask = dma_addr_mask(ch);
  const int unit = word32 ? 4 : 2;

  // FIFO DMA は固定4ワード転送
  uint32_t count = dma_shadows_[ch].count;
  if (start_timing == 3u && (ch == 1 || ch == 2)) count = 4u;

  uint32_t src = dma_shadows_[ch].sad & mask;
  uint32_t dst = dma_shadows_[ch].dad & mask;

  for (uint32_t n = 0; n < count; ++n) {
    if (word32) {
      Write32(dst & ~3u, Read32(src & ~3u));
    } else {
      Write16(dst & ~1u, Read16(src & ~1u));
    }

    // 送信元アドレス更新
    if      (src_ctl == 0) src = (src + unit) & mask;
    else if (src_ctl == 1) src = (src - unit) & mask;
    // src_ctl==2: 固定

    // 送信先アドレス更新
    if (start_timing == 3u && (ch == 1 || ch == 2)) {
      // FIFO DMA: 送信先固定
    } else if (dst_ctl == 0 || dst_ctl == 3) {
      dst = (dst + unit) & mask;
    } else if (dst_ctl == 1) {
      dst = (dst - unit) & mask;
    }
    // dst_ctl==2: 固定
  }

  dma_shadows_[ch].sad = src;

  // 完了処理
  if (repeat && start_timing != 0u) {
    // リピートモード: count再読み込み
    uint32_t c = static_cast<uint32_t>(io_regs_[static_cast<size_t>(cnt_base - 0x04000000u) + 8u]) |
                 (static_cast<uint32_t>(io_regs_[static_cast<size_t>(cnt_base - 0x04000000u) + 9u]) << 8);
    if (c == 0) c = (ch == 3) ? 0x10000u : 0x4000u;
    dma_shadows_[ch].count = c;
    // dst_ctl==3: 送信先もリロード
    if (dst_ctl == 3) {
      dma_shadows_[ch].dad = dma_shadows_[ch].initial_dad;
    } else {
      dma_shadows_[ch].dad = dst;
    }
    dma_shadows_[ch].active = true;  // リピートなのでアクティブ維持
  } else {
    dma_shadows_[ch].dad = dst;
    dma_shadows_[ch].active = false;
    // ENABLE ビットをクリア (repeat=0の場合)
    if (!repeat) {
      const size_t coff = static_cast<size_t>(cnt_base + 10u - 0x04000000u);
      const uint16_t next_cnt = (static_cast<uint16_t>(io_regs_[coff]) |
                                 (static_cast<uint16_t>(io_regs_[coff+1]) << 8)) & ~0x8000u;
      io_regs_[coff]   = static_cast<uint8_t>(next_cnt & 0xFFu);
      io_regs_[coff+1] = static_cast<uint8_t>((next_cnt >> 8) & 0xFFu);
    }
  }

  // DMA完了IRQ
  if (cnt_h & 0x4000u) RaiseInterrupt(1u << (8 + ch));
}

// =========================================================================
// Audio FIFO プッシュ
// =========================================================================
void GBACore::PushAudioFifo(bool fifo_a, uint32_t value) {
  auto& fifo = fifo_a ? fifo_a_ : fifo_b_;
  for (int i = 0; i < 4; ++i) {
    fifo.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xFFu));
  }
  // キャパシティ超過: 古いサンプルを捨てる
  while (fifo.size() > mgba_compat::kAudioFifoCapacityBytes) {
    fifo.pop_front();
  }
}

// =========================================================================
// Audio FIFO 消費 (タイマーオーバーフロー時)
// =========================================================================
void GBACore::ConsumeAudioFifoOnTimer(size_t timer_index) {
  const uint16_t soundcnt_h = ReadIO16(0x04000082u);
  const bool fifo_a_timer = (soundcnt_h & (1u << 10)) != 0;  // 0=TM0,1=TM1
  const bool fifo_b_timer = (soundcnt_h & (1u << 14)) != 0;

  auto pop_fifo = [&](std::deque<uint8_t>* fifo, int16_t* last_sample, bool* dma_req) {
    if (!fifo->empty()) {
      const int8_t sample = static_cast<int8_t>(fifo->front());
      fifo->pop_front();
      *last_sample = static_cast<int16_t>(sample);
    }
    if (fifo->size() <= mgba_compat::kAudioFifoDmaRequestThreshold) {
      *dma_req = true;
    }
  };

  const bool fifo_a_match = (!fifo_a_timer && timer_index == 0u) ||
                             (fifo_a_timer  && timer_index == 1u);
  const bool fifo_b_match = (!fifo_b_timer && timer_index == 0u) ||
                             (fifo_b_timer  && timer_index == 1u);

  if (fifo_a_match) {
    pop_fifo(&fifo_a_, &fifo_a_last_sample_, &dma_fifo_a_request_);
    // FIFO DMA 発火
    if (dma_fifo_a_request_) {
      dma_fifo_a_request_ = false;
      // DMA1をFIFO Aとしてチェック
      const uint16_t d1cnt = ReadIO16(0x040000C4u);
      if ((d1cnt & 0x8000u) && ((d1cnt >> 12) & 3u) == 3u) {
        ExecuteDmaTransfer(1, d1cnt);
      }
    }
  }
  if (fifo_b_match) {
    pop_fifo(&fifo_b_, &fifo_b_last_sample_, &dma_fifo_b_request_);
    if (dma_fifo_b_request_) {
      dma_fifo_b_request_ = false;
      const uint16_t d2cnt = ReadIO16(0x040000D0u);
      if ((d2cnt & 0x8000u) && ((d2cnt >> 12) & 3u) == 3u) {
        ExecuteDmaTransfer(2, d2cnt);
      }
    }
  }
}

}  // namespace gba