#if defined(GBA_CORE_USE_AGGREGATED_MODULES) && !defined(GBA_CORE_MODULE_COMPILED_FROM_AGGREGATE)
// Aggregated build is enabled; this standalone TU is intentionally empty to avoid duplicate symbols.
#else

// ppu_common.mm
// GBA PPU: scanline timing, window setup, and final compositing.
// All rendering follows GBA hardware behaviour exactly (per-scanline, priority/blend/window correct).

#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

// ── Shared helpers (also used by tile/bitmap/obj files) ──────────────────────

// Read a 16-bit IO register from the io_regs_ byte array (byte offset).
static inline uint16_t IoR16(const std::array<uint8_t, 1024>& io, uint32_t off) {
    return static_cast<uint16_t>(io[off & 0x3FFu] | (io[(off + 1) & 0x3FFu] << 8));
}

// Read a signed 28-bit fixed-point reference register (BG2X/Y, BG3X/Y).
// Returns the value as a 28.0 integer (i.e. the fractional 8 bits are kept in the low byte).
static inline int32_t IoR28(const std::array<uint8_t, 1024>& io, uint32_t off) {
    uint32_t raw = static_cast<uint32_t>(io[off & 0x3FFu])
                 | (static_cast<uint32_t>(io[(off+1)&0x3FFu]) << 8)
                 | (static_cast<uint32_t>(io[(off+2)&0x3FFu]) << 16)
                 | (static_cast<uint32_t>(io[(off+3)&0x3FFu]) << 24);
    raw &= 0x0FFFFFFFu;
    if (raw & 0x08000000u) raw |= 0xF0000000u;  // sign-extend from bit 27
    return static_cast<int32_t>(raw);
}

// Convert BGR555 → ARGB8888 (A=0xFF).
static inline uint32_t BGR555toARGB(uint16_t c) {
    const uint32_t r5 =  c        & 0x1Fu;
    const uint32_t g5 = (c >> 5)  & 0x1Fu;
    const uint32_t b5 = (c >> 10) & 0x1Fu;
    // 5-bit to 8-bit: multiply by 255/31 ≈ expand via (v<<3)|(v>>2)
    const uint32_t r8 = (r5 << 3) | (r5 >> 2);
    const uint32_t g8 = (g5 << 3) | (g5 >> 2);
    const uint32_t b8 = (b5 << 3) | (b5 >> 2);
    return 0xFF000000u | (r8 << 16) | (g8 << 8) | b8;
}

// Alpha blend two BGR555 colours: result = (eva*c1 + evb*c2) >> 4, clamped to 31.
static inline uint16_t AlphaBlend(uint16_t c1, uint16_t c2, int eva, int evb) {
    if (eva > 16) eva = 16;
    if (evb > 16) evb = 16;
    auto ch = [](uint16_t c, int sh, int a, int b, uint16_t c2, int sh2) -> int {
        int v = ((c >> sh) & 0x1F) * a + ((c2 >> sh2) & 0x1F) * b;
        v >>= 4;
        return v > 31 ? 31 : v;
    };
    int r = ((c1 & 0x1Fu)          * eva + (c2 & 0x1Fu)          * evb) >> 4;
    int g = (((c1 >> 5)  & 0x1Fu) * eva + ((c2 >> 5)  & 0x1Fu) * evb) >> 4;
    int b = (((c1 >> 10) & 0x1Fu) * eva + ((c2 >> 10) & 0x1Fu) * evb) >> 4;
    (void)ch;
    if (r > 31) r = 31;
    if (g > 31) g = 31;
    if (b > 31) b = 31;
    return static_cast<uint16_t>(r | (g << 5) | (b << 10));
}

// Brightness increase: ch = ch + (31 - ch) * evy / 16
static inline uint16_t Brighten(uint16_t c, int evy) {
    if (evy > 16) evy = 16;
    int r = (c & 0x1Fu);        r += (31 - r) * evy / 16;
    int g = (c >> 5)  & 0x1Fu;  g += (31 - g) * evy / 16;
    int b = (c >> 10) & 0x1Fu;  b += (31 - b) * evy / 16;
    return static_cast<uint16_t>(r | (g << 5) | (b << 10));
}

// Brightness decrease: ch = ch - ch * evy / 16
static inline uint16_t Darken(uint16_t c, int evy) {
    if (evy > 16) evy = 16;
    int r = (c & 0x1Fu);        r -= r * evy / 16;
    int g = (c >> 5)  & 0x1Fu;  g -= g * evy / 16;
    int b = (c >> 10) & 0x1Fu;  b -= b * evy / 16;
    return static_cast<uint16_t>(r | (g << 5) | (b << 10));
}

// Read palette entry (index into 512-entry palette RAM) as BGR555.
static inline uint16_t PaletteColor(const std::array<uint8_t, 1024>& pal, int idx) {
    const uint32_t off = static_cast<uint32_t>(idx) * 2u;
    return static_cast<uint16_t>(pal[off & 0x3FFu] | (pal[(off + 1) & 0x3FFu] << 8));
}

// ── Affine reference latch ────────────────────────────────────────────────────

void GBACore::LatchAffineRefs() {
    // Latch BG2/3 reference points from IO registers at VBlank start.
    // These are then incremented per-scanline by PB/PD.
    ppu_bg2_refx_ = IoR28(io_regs_, 0x28u);
    ppu_bg2_refy_ = IoR28(io_regs_, 0x2Cu);
    ppu_bg3_refx_ = IoR28(io_regs_, 0x38u);
    ppu_bg3_refy_ = IoR28(io_regs_, 0x3Cu);
    ppu_affine_latched_ = true;
}

// ── Window mask build ─────────────────────────────────────────────────────────
// Fills ppu_win_mask_[0..239] for scanline y.
// Bit layout: bit0=BG0, bit1=BG1, bit2=BG2, bit3=BG3, bit4=OBJ, bit5=ColorFX

void GBACore::BuildWinMask(int y) {
    const uint16_t dispcnt  = IoR16(io_regs_, 0x00u);
    const bool win0_en   = (dispcnt & (1u << 13)) != 0;
    const bool win1_en   = (dispcnt & (1u << 14)) != 0;
    const bool objwin_en = (dispcnt & (1u << 15)) != 0;

    // If no window hardware enabled → all layers + fx enabled for every pixel
    if (!win0_en && !win1_en && !objwin_en) {
        ppu_win_mask_.fill(0x3Fu);  // all 6 bits set
        return;
    }

    const uint16_t winin  = IoR16(io_regs_, 0x48u);
    const uint16_t winout = IoR16(io_regs_, 0x4Au);

    // WIN0 control bits [5:0], WIN1 [13:8] of WININ
    const uint8_t win0_ctrl = static_cast<uint8_t>(winin & 0x3Fu);
    const uint8_t win1_ctrl = static_cast<uint8_t>((winin >> 8) & 0x3Fu);
    // WINOUT [5:0] = outside all windows; [13:8] = inside OBJWIN
    const uint8_t out_ctrl    = static_cast<uint8_t>(winout & 0x3Fu);
    const uint8_t objwin_ctrl = static_cast<uint8_t>((winout >> 8) & 0x3Fu);

    // Check Y ranges
    const bool in_win0_y = [&]() -> bool {
        if (!win0_en) return false;
        const uint16_t v = IoR16(io_regs_, 0x44u);
        int y1 = v >> 8, y2 = v & 0xFF;
        if (y1 <= y2) return y >= y1 && y < y2;
        return y >= y1 || y < y2;
    }();
    const bool in_win1_y = [&]() -> bool {
        if (!win1_en) return false;
        const uint16_t v = IoR16(io_regs_, 0x46u);
        int y1 = v >> 8, y2 = v & 0xFF;
        if (y1 <= y2) return y >= y1 && y < y2;
        return y >= y1 || y < y2;
    }();

    // WIN0 / WIN1 X ranges
    const uint16_t win0h = win0_en ? IoR16(io_regs_, 0x40u) : 0u;
    const uint16_t win1h = win1_en ? IoR16(io_regs_, 0x42u) : 0u;
    int w0x1 = win0h >> 8,  w0x2 = win0h & 0xFF;
    int w1x1 = win1h >> 8,  w1x2 = win1h & 0xFF;

    for (int x = 0; x < 240; ++x) {
        // WIN0 x-range check (higher priority)
        bool in0 = false;
        if (in_win0_y) {
            if (w0x1 <= w0x2) in0 = (x >= w0x1 && x < w0x2);
            else               in0 = (x >= w0x1 || x < w0x2);
        }
        // WIN1 x-range check
        bool in1 = false;
        if (in_win1_y && !in0) {
            if (w1x1 <= w1x2) in1 = (x >= w1x1 && x < w1x2);
            else               in1 = (x >= w1x1 || x < w1x2);
        }

        uint8_t mask;
        if (in0)                      mask = win0_ctrl;
        else if (in1)                 mask = win1_ctrl;
        else if (objwin_en && ppu_objwin_[x]) mask = objwin_ctrl;
        else                          mask = out_ctrl;

        ppu_win_mask_[x] = mask;
    }
}

// ── Main scanline compositor ──────────────────────────────────────────────────

void GBACore::CompositeScanline(int y) {
    const uint16_t dispcnt  = IoR16(io_regs_, 0x00u);
    const uint16_t bldcnt   = IoR16(io_regs_, 0x50u);
    const uint16_t bldalpha = IoR16(io_regs_, 0x52u);
    const uint16_t bldy     = IoR16(io_regs_, 0x54u);

    const int blendMode = (bldcnt >> 6) & 0x3;
    const int eva  = std::min(16, static_cast<int>(bldalpha & 0x1Fu));
    const int evb  = std::min(16, static_cast<int>((bldalpha >> 8) & 0x1Fu));
    const int evy  = std::min(16, static_cast<int>(bldy & 0x1Fu));

    // BLDCNT target bits: bits[5:0]=target1, bits[13:8]=target2
    // Bit ordering: 0=BG0,1=BG1,2=BG2,3=BG3,4=OBJ,5=Backdrop
    const uint8_t t1 = static_cast<uint8_t>(bldcnt & 0x3Fu);
    const uint8_t t2 = static_cast<uint8_t>((bldcnt >> 8) & 0x3Fu);

    // BG priority: read from BGxCNT bits [1:0]
    const uint8_t bg_prio[4] = {
        static_cast<uint8_t>(IoR16(io_regs_, 0x08u) & 3u),
        static_cast<uint8_t>(IoR16(io_regs_, 0x0Au) & 3u),
        static_cast<uint8_t>(IoR16(io_regs_, 0x0Cu) & 3u),
        static_cast<uint8_t>(IoR16(io_regs_, 0x0Eu) & 3u),
    };
    // Which BGs are enabled?
    const bool bg_en[4] = {
        (dispcnt & (1u << 8))  != 0,
        (dispcnt & (1u << 9))  != 0,
        (dispcnt & (1u << 10)) != 0,
        (dispcnt & (1u << 11)) != 0,
    };
    const bool obj_en = (dispcnt & (1u << 12)) != 0;

    // Backdrop colour (palette index 0)
    const uint16_t backdrop = PaletteColor(palette_ram_, 0);

    uint32_t* row = &frame_buffer_[y * kScreenWidth];

    for (int x = 0; x < kScreenWidth; ++x) {
        const uint8_t wmask = ppu_win_mask_[x];
        const bool fx_en    = (wmask >> 5) & 1u;

        // ── Find top two visible pixels ──────────────────────────────────
        // top1: topmost non-transparent pixel (highest priority)
        // top2: second non-transparent pixel (for blending)
        uint16_t top1_color = backdrop;
        int      top1_layer = 5;   // 5 = backdrop
        int      top1_prio  = 4;   // backdrop priority = 4 (lowest)
        uint16_t top2_color = backdrop;
        int      top2_layer = 5;
        bool     top1_semitrans = false;

        // Evaluate priority for this pixel in order 0..3
        // At same priority: OBJ beats BG0 beats BG1 beats BG2 beats BG3
        for (int p = 0; p < 4; ++p) {
            // OBJ at priority p
            if (obj_en && (wmask & (1u << 4))) {
                const uint8_t om = ppu_obj_attr_[x];
                if ((ppu_obj_[x] & 0x8000u) == 0 &&  // not transparent
                    (om & 3u) == static_cast<uint8_t>(p)) {
                    const bool semi = (om & (1u << 2)) != 0;
                    if (top1_prio > p || (top1_prio == 4)) {
                        top2_color = top1_color; top2_layer = top1_layer;
                        top1_color = ppu_obj_[x];
                        top1_layer = 4;
                        top1_prio  = p;
                        top1_semitrans = semi;
                    } else if (top1_prio <= p) {
                        // OBJ loses to already-placed top1 — becomes top2 candidate
                        if (top2_layer == 5 || top1_prio < p) {
                            top2_color = ppu_obj_[x];
                            top2_layer = 4;
                        }
                    }
                }
            }
            // BGs at priority p (BG0 has highest BG priority at same p level)
            for (int bg = 0; bg < 4; ++bg) {
                if (!bg_en[bg] || !(wmask & (1u << bg))) continue;
                if (bg_prio[bg] != static_cast<uint8_t>(p)) continue;
                if (ppu_bg_[bg][x] & 0x8000u) continue;  // transparent

                if (top1_prio > p) {
                    top2_color = top1_color; top2_layer = top1_layer;
                    top1_color = ppu_bg_[bg][x];
                    top1_layer = bg;
                    top1_prio  = p;
                    top1_semitrans = false;
                } else {
                    if (top2_layer == 5) {
                        top2_color = ppu_bg_[bg][x];
                        top2_layer = bg;
                    }
                }
            }
        }

        // ── Apply colour effects ─────────────────────────────────────────
        uint16_t final_color = top1_color;

        // Determine if top1 is a blend target1 layer
        const bool top1_is_t1 = fx_en && ((t1 >> top1_layer) & 1u);
        const bool top2_is_t2 = (t2 >> top2_layer) & 1u;

        if (fx_en) {
            if (top1_semitrans && top2_is_t2) {
                // Semi-transparent OBJ: always alpha-blend with whatever is behind
                final_color = AlphaBlend(top1_color, top2_color, eva, evb);
            } else if (blendMode == 1 && top1_is_t1 && top2_is_t2) {
                // Alpha blend
                final_color = AlphaBlend(top1_color, top2_color, eva, evb);
            } else if (blendMode == 2 && top1_is_t1) {
                // Brightness increase
                final_color = Brighten(top1_color, evy);
            } else if (blendMode == 3 && top1_is_t1) {
                // Brightness decrease
                final_color = Darken(top1_color, evy);
            }
        }

        row[x] = BGR555toARGB(final_color);
    }
}

// ── DrawScanline ──────────────────────────────────────────────────────────────

void GBACore::DrawScanline(int y) {
    const uint16_t dispcnt = IoR16(io_regs_, 0x00u);

    // Forced-blank: white screen
    if (dispcnt & (1u << 7)) {
        uint32_t* row = &frame_buffer_[y * kScreenWidth];
        for (int x = 0; x < kScreenWidth; ++x) row[x] = 0xFFFFFFFFu;
        return;
    }

    const int mode = dispcnt & 7;

    // Clear BG buffers (0x8000 = transparent)
    for (int b = 0; b < 4; ++b) ppu_bg_[b].fill(0x8000u);
    ppu_obj_.fill(0x8000u);
    ppu_obj_attr_.fill(0);
    ppu_objwin_.fill(false);

    // OBJ rendering (needed before BuildWinMask for OBJWIN)
    if (dispcnt & (1u << 12)) DrawObjects(y);

    // Build window mask (uses ppu_objwin_ from DrawObjects)
    BuildWinMask(y);

    // BG rendering
    switch (mode) {
    case 0:  // 4 text BGs
        if (dispcnt & (1u << 8))  DrawBgText(0, y);
        if (dispcnt & (1u << 9))  DrawBgText(1, y);
        if (dispcnt & (1u << 10)) DrawBgText(2, y);
        if (dispcnt & (1u << 11)) DrawBgText(3, y);
        break;
    case 1:  // 2 text + 1 affine
        if (dispcnt & (1u << 8))  DrawBgText(0, y);
        if (dispcnt & (1u << 9))  DrawBgText(1, y);
        if (dispcnt & (1u << 10)) DrawBgAffine(2, y);
        break;
    case 2:  // 2 affine
        if (dispcnt & (1u << 10)) DrawBgAffine(2, y);
        if (dispcnt & (1u << 11)) DrawBgAffine(3, y);
        break;
    case 3:
        if (dispcnt & (1u << 10)) DrawBgBitmap3(y);
        break;
    case 4:
        if (dispcnt & (1u << 10)) DrawBgBitmap4(y);
        break;
    case 5:
        if (dispcnt & (1u << 10)) DrawBgBitmap5(y);
        break;
    default:
        break;
    }

    // Composite all layers into frame_buffer_
    CompositeScanline(y);

    // Update affine reference points for next scanline (PB, PD per scanline)
    // Mode 1: BG2 affine
    if (mode == 1 || mode == 2) {
        const int16_t pb2 = static_cast<int16_t>(IoR16(io_regs_, 0x22u));
        const int16_t pd2 = static_cast<int16_t>(IoR16(io_regs_, 0x26u));
        ppu_bg2_refx_ += static_cast<int32_t>(pb2);
        ppu_bg2_refy_ += static_cast<int32_t>(pd2);
    }
    if (mode == 2) {
        const int16_t pb3 = static_cast<int16_t>(IoR16(io_regs_, 0x32u));
        const int16_t pd3 = static_cast<int16_t>(IoR16(io_regs_, 0x36u));
        ppu_bg3_refx_ += static_cast<int32_t>(pb3);
        ppu_bg3_refy_ += static_cast<int32_t>(pd3);
    }
    // Bitmap modes also use BG2 affine reference
    if (mode >= 3 && mode <= 5) {
        const int16_t pb2 = static_cast<int16_t>(IoR16(io_regs_, 0x22u));
        const int16_t pd2 = static_cast<int16_t>(IoR16(io_regs_, 0x26u));
        ppu_bg2_refx_ += static_cast<int32_t>(pb2);
        ppu_bg2_refy_ += static_cast<int32_t>(pd2);
    }
}

// ── PPU step (scanline timing machine) ───────────────────────────────────────

void GBACore::StepPpu(uint32_t cycles) {
    ppu_cycle_accum_ += cycles;

    constexpr uint32_t kHDrawCycles  = mgba_compat::kVideoHDrawCycles;
    constexpr uint32_t kHBlankCycles = mgba_compat::kVideoScanlineCycles - kHDrawCycles;

    while (true) {
        uint16_t dispstat = IoR16(io_regs_, 0x04u);
        const bool in_hblank = (dispstat & 0x2u) != 0;
        const uint32_t phase_len = in_hblank ? kHBlankCycles : kHDrawCycles;

        if (ppu_cycle_accum_ < phase_len) break;
        ppu_cycle_accum_ -= phase_len;

        if (!in_hblank) {
            // ── Transition: HDraw → HBlank ───────────────────────────────
            dispstat |= 0x2u;
            WriteIO16(0x04000004u, dispstat);

            const uint16_t vcount = IoR16(io_regs_, 0x06u);

            if (vcount < mgba_compat::kVideoVisibleLines) {
                // Render this scanline during HBlank
                DrawScanline(static_cast<int>(vcount));
                // HBlank DMA
                StepDmaHBlank(kHBlankCycles);
            }
            if (dispstat & (1u << 4)) RaiseInterrupt(1u << 1);  // HBlank IRQ
            continue;
        }

        // ── Transition: HBlank → HDraw (next scanline) ───────────────────
        dispstat &= ~0x2u;

        uint16_t vcount = IoR16(io_regs_, 0x06u);
        vcount = static_cast<uint16_t>((vcount + 1) % mgba_compat::kVideoTotalLines);
        WriteIO16(0x04000006u, vcount);

        // VBlank handling
        if (vcount == mgba_compat::kVideoVisibleLines) {
            dispstat |= 0x1u;  // set VBlank flag
            WriteIO16(0x04000004u, dispstat);
            if (dispstat & (1u << 3)) RaiseInterrupt(1u << 0);  // VBlank IRQ
            StepDmaVBlank(kHDrawCycles);
            ++frame_count_;
        } else if (vcount == 0) {
            dispstat &= ~0x1u;  // clear VBlank flag
            // Latch affine reference points at start of new frame
            LatchAffineRefs();
        } else if (vcount == mgba_compat::kVideoTotalLines - 1) {
            dispstat &= ~0x1u;
        }

        // VCounter IRQ
        const uint16_t lyc = static_cast<uint16_t>((dispstat >> 8) & 0xFFu);
        if (vcount == lyc) {
            dispstat |= 0x4u;
            if (dispstat & (1u << 5)) RaiseInterrupt(1u << 2);
        } else {
            dispstat &= ~0x4u;
        }
        WriteIO16(0x04000004u, dispstat);
    }
}

// ── Debug frame (no ROM / unknown mode) ──────────────────────────────────────

void GBACore::RenderDebugFrame() {
    // Solid black frame
    std::fill(frame_buffer_.begin(), frame_buffer_.end(), 0xFF000000u);
}

// ── RunCycles / StepFrame (wrappers, unchanged API) ──────────────────────────

void GBACore::RunCycles(uint32_t cycles) {
    if (!loaded_) return;
    if (frame_buffer_.size() != static_cast<size_t>(kScreenWidth * kScreenHeight))
        frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000u);
    RunCpuSlice(cycles);
    StepTimers(cycles);
    StepDma(cycles);
    StepApu(cycles);
    StepSio(cycles);
    StepPpu(cycles);
    ServiceInterruptIfNeeded();
    executed_cycles_ += cycles;
}

void GBACore::SyncKeyInputRegister() {
    const uint16_t keyinput = static_cast<uint16_t>(~keys_pressed_mask_ & 0x03FFu);
    io_regs_[0x130] = static_cast<uint8_t>(keyinput & 0xFF);
    io_regs_[0x131] = static_cast<uint8_t>(keyinput >> 8);
}

void GBACore::SetKeys(uint16_t keys_pressed_mask) {
    previous_keys_mask_ = keys_pressed_mask_;
    keys_pressed_mask_  = static_cast<uint16_t>(keys_pressed_mask & 0x03FFu);
    SyncKeyInputRegister();
}

void GBACore::UpdateGameplayFromInput() {
    if (keys_pressed_mask_ & kKeyLeft)  gameplay_state_.player_x--;
    if (keys_pressed_mask_ & kKeyRight) gameplay_state_.player_x++;
    if (keys_pressed_mask_ & kKeyUp)    gameplay_state_.player_y--;
    if (keys_pressed_mask_ & kKeyDown)  gameplay_state_.player_y++;
    gameplay_state_.player_x = std::clamp(gameplay_state_.player_x, 0, kScreenWidth  - 1);
    gameplay_state_.player_y = std::clamp(gameplay_state_.player_y, 0, kScreenHeight - 1);
}

void GBACore::StepFrame() {
    if (!loaded_) return;
    if (frame_buffer_.size() != static_cast<size_t>(kScreenWidth * kScreenHeight))
        frame_buffer_.assign(kScreenWidth * kScreenHeight, 0xFF000000u);
    UpdateGameplayFromInput();
    RunCycles(kCyclesPerFrame);
}

}  // namespace gba
#endif
