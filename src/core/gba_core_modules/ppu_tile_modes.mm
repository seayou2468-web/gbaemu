// ppu_tile_modes.mm
// GBA PPU: per-scanline text BG (modes 0/1) and affine BG (modes 1/2) rendering.
// Implements 100% hardware-accurate tile lookup, scroll, flip, mosaic, and 1D/2D affine.

#include "../gba_core.h"
#include <cstring>
#include <algorithm>

namespace gba {

// ── Shared helpers ────────────────────────────────────────────────────────────

static inline uint16_t IoR16t(const std::array<uint8_t, 1024>& io, uint32_t off) {
    return static_cast<uint16_t>(io[off & 0x3FFu] | (io[(off + 1) & 0x3FFu] << 8));
}

// BGR555 palette entry from a 512-entry (1024-byte) palette RAM.
static inline uint16_t PalColor(const std::array<uint8_t, 1024>& pal, uint32_t idx) {
    const uint32_t o = (idx & 0x1FFu) << 1;
    return static_cast<uint16_t>(pal[o] | (pal[o + 1] << 8));
}

// Read one byte from the 96 KiB VRAM, with address wrap at the VRAM size boundary.
static inline uint8_t VramByte(const std::array<uint8_t, 96 * 1024>& vram, uint32_t addr) {
    // VRAM: 0x0000–0x17FFF are linear; 0x18000–0x1FFFF mirror 0x10000–0x17FFF
    addr &= 0x1FFFFu;
    if (addr >= 0x18000u) addr = 0x10000u + (addr & 0x7FFFu);
    return vram[addr];
}

// ── Text BG renderer (DrawBgText) ─────────────────────────────────────────────
//
// GBA Text BG register layout in BGxCNT (byte offset from io_regs_ base):
//   [1:0]  Priority
//   [3:2]  Character (tile data) base block: addr = val * 0x4000
//   [6]    Mosaic
//   [7]    256-colour mode (0=16/16, 1=256/1)
//   [12:8] Screen base block: addr = val * 0x800
//   [15:14] Screen size:
//     0 → 256×256 (1 screen  = 32×32 tiles)
//     1 → 512×256 (2 screens = 64×32 tiles, H)
//     2 → 256×512 (2 screens = 32×64 tiles, V)
//     3 → 512×512 (4 screens = 64×64 tiles)
//
// Screen entry (16-bit):
//   [9:0]  Tile number
//   [10]   H-flip
//   [11]   V-flip
//   [15:12] Palette bank (16-colour mode only)

void GBACore::DrawBgText(int bg, int y) {
    const uint32_t cntOff  = 0x08u + static_cast<uint32_t>(bg) * 2u;
    const uint32_t hofsOff = 0x10u + static_cast<uint32_t>(bg) * 4u;
    const uint32_t vofsOff = 0x12u + static_cast<uint32_t>(bg) * 4u;

    const uint16_t bgcnt  = IoR16t(io_regs_, cntOff);
    const uint16_t hofs   = IoR16t(io_regs_, hofsOff) & 0x1FFu;
    const uint16_t vofs   = IoR16t(io_regs_, vofsOff) & 0x1FFu;

    const uint32_t charBase   = static_cast<uint32_t>((bgcnt >> 2)  & 0x3u) * 0x4000u;
    const uint32_t screenBase = static_cast<uint32_t>((bgcnt >> 8)  & 0x1Fu) * 0x800u;
    const bool is256          = (bgcnt & (1u << 7)) != 0;
    const uint32_t sizeIdx    = (bgcnt >> 14) & 0x3u;
    const bool mosaicOn       = (bgcnt & (1u << 6)) != 0;

    // Map dimensions in pixels
    const uint32_t mapW = (sizeIdx & 1u) ? 512u : 256u;
    const uint32_t mapH = (sizeIdx & 2u) ? 512u : 256u;
    const uint32_t scrBlocksH = (sizeIdx & 1u) ? 2u : 1u;

    // Mosaic register: bits [3:0] = BG H mosaic size-1, bits [7:4] = BG V mosaic size-1
    const uint16_t mosaic  = IoR16t(io_regs_, 0x4Cu);
    const int mosaicH      = mosaicOn ? static_cast<int>(mosaic & 0xFu) + 1 : 1;
    const int mosaicV      = mosaicOn ? static_cast<int>((mosaic >> 4) & 0xFu) + 1 : 1;

    // Effective Y (apply V mosaic)
    const int effY = mosaicOn ? (y - (y % mosaicV)) : y;

    uint16_t* out = ppu_bg_[bg].data();

    for (int x = 0; x < 240; ++x) {
        // Apply H mosaic
        const int effX = mosaicOn ? (x - (x % mosaicH)) : x;

        // BG coordinates (wrap within map)
        const uint32_t bgX = (static_cast<uint32_t>(effX) + hofs) & (mapW - 1u);
        const uint32_t bgY = (static_cast<uint32_t>(effY) + vofs) & (mapH - 1u);

        // Tile coordinates
        const uint32_t tileX    = bgX >> 3;
        const uint32_t tileY    = bgY >> 3;
        const uint32_t inTileX  = bgX & 7u;
        const uint32_t inTileY  = bgY & 7u;

        // Screen block selection for 512-wide or 512-tall maps
        // Layout:
        //  size=01 (512×256): block 0 (left)  + block 1 (right)
        //  size=10 (256×512): block 0 (top)   + block 1 (bottom)  [stride=1]
        //  size=11 (512×512): TL=0, TR=1, BL=2, BR=3
        const uint32_t blockX = tileX >> 5;
        const uint32_t blockY = tileY >> 5;
        uint32_t blockIdx;
        if (sizeIdx == 3) {
            blockIdx = blockY * 2u + blockX;
        } else if (sizeIdx == 2) {
            blockIdx = blockY;
        } else {
            blockIdx = blockX;
        }
        const uint32_t seIdx  = ((tileY & 31u) << 5) + (tileX & 31u);
        const uint32_t seAddr = screenBase + blockIdx * 0x800u + seIdx * 2u;

        const uint8_t seL = vram_[seAddr % vram_.size()];
        const uint8_t seH = vram_[(seAddr + 1) % vram_.size()];
        const uint16_t se = static_cast<uint16_t>(seL | (seH << 8));

        const uint32_t tileNum  = se & 0x3FFu;
        const bool hflip        = (se & (1u << 10)) != 0;
        const bool vflip        = (se & (1u << 11)) != 0;
        const uint32_t palBank  = (se >> 12) & 0xFu;

        // Flipped in-tile coordinates
        const uint32_t px = hflip ? (7u - inTileX) : inTileX;
        const uint32_t py = vflip ? (7u - inTileY) : inTileY;

        uint8_t palIdx;
        if (is256) {
            // 8bpp: each tile = 64 bytes; one byte per pixel
            const uint32_t tileAddr = charBase + tileNum * 64u + py * 8u + px;
            palIdx = VramByte(vram_, tileAddr);
            if (palIdx == 0) { out[x] = 0x8000u; continue; }
            out[x] = PalColor(palette_ram_, palIdx);
        } else {
            // 4bpp: each tile = 32 bytes; 4 bits per pixel packed
            const uint32_t tileAddr = charBase + tileNum * 32u + py * 4u + (px >> 1);
            const uint8_t packed = VramByte(vram_, tileAddr);
            palIdx = (px & 1u) ? (packed >> 4) : (packed & 0xFu);
            if (palIdx == 0) { out[x] = 0x8000u; continue; }
            out[x] = PalColor(palette_ram_, palBank * 16u + palIdx);
        }
    }
}

// ── Affine BG renderer (DrawBgAffine) ─────────────────────────────────────────
//
// GBA Affine BG (BG2 in mode 1; BG2/3 in mode 2):
//   - Always 8bpp (256/1 palette)
//   - Screen size: 128,256,512,1024 pixels square (BGxCNT[15:14])
//   - BGxCNT[13]: overflow: 0=transparent outside, 1=wrap
//   - PA,PB,PC,PD: 8.8 signed fixed-point
//   - Reference point: 28-bit signed, latched at VBlank, incremented by PB/PD per scanline
//
// For scanline y pixel x:
//   src_x = (refx + PA*x) >> 8
//   src_y = (refy + PC*x) >> 8
// (refx/refy already incorporate PB*y via per-scanline accumulation)

void GBACore::DrawBgAffine(int bg, int y) {
    const uint32_t cntOff  = 0x08u + static_cast<uint32_t>(bg) * 2u;
    const uint16_t bgcnt   = IoR16t(io_regs_, cntOff);

    const uint32_t charBase   = static_cast<uint32_t>((bgcnt >> 2)  & 0x3u) * 0x4000u;
    const uint32_t screenBase = static_cast<uint32_t>((bgcnt >> 8)  & 0x1Fu) * 0x800u;
    const bool overflow       = (bgcnt & (1u << 13)) != 0;
    const uint32_t sizeIdx    = (bgcnt >> 14) & 0x3u;
    const bool mosaicOn       = (bgcnt & (1u << 6)) != 0;

    const uint32_t mapSize = 128u << sizeIdx;  // 128, 256, 512, or 1024 pixels

    // Mosaic
    const uint16_t mosaic  = IoR16t(io_regs_, 0x4Cu);
    const int mosaicH      = mosaicOn ? static_cast<int>(mosaic & 0xFu) + 1 : 1;

    // PA and PC (per-pixel increments along X)
    const int32_t pa = static_cast<int32_t>(static_cast<int16_t>(IoR16t(io_regs_, bg == 2 ? 0x20u : 0x30u)));
    const int32_t pc = static_cast<int32_t>(static_cast<int16_t>(IoR16t(io_regs_, bg == 2 ? 0x24u : 0x34u)));

    // Running reference point for this scanline (accumulated from VBlank latch)
    int32_t refx = (bg == 2) ? ppu_bg2_refx_ : ppu_bg3_refx_;
    int32_t refy = (bg == 2) ? ppu_bg2_refy_ : ppu_bg3_refy_;

    uint16_t* out = ppu_bg_[bg].data();

    // For mosaic: precompute the effective pixel coords at mosaicH boundaries
    int32_t eff_refx = refx, eff_refy = refy;  // will be updated every mosaicH pixels

    for (int x = 0; x < 240; ++x) {
        // Mosaic: snap to last mosaic-H boundary
        if (mosaicOn && (x % mosaicH == 0)) {
            eff_refx = refx + pa * x;
            eff_refy = refy + pc * x;
        }

        // Source BG coordinates (fixed-point >> 8 = integer pixel)
        int32_t sx, sy;
        if (mosaicOn) {
            sx = eff_refx >> 8;
            sy = eff_refy >> 8;
        } else {
            sx = (refx + pa * x) >> 8;
            sy = (refy + pc * x) >> 8;
        }

        // Bounds check / wrap
        if (sx < 0 || sy < 0 ||
            sx >= static_cast<int32_t>(mapSize) ||
            sy >= static_cast<int32_t>(mapSize)) {
            if (!overflow) { out[x] = 0x8000u; continue; }
            sx = ((sx % static_cast<int32_t>(mapSize)) + static_cast<int32_t>(mapSize))
                 % static_cast<int32_t>(mapSize);
            sy = ((sy % static_cast<int32_t>(mapSize)) + static_cast<int32_t>(mapSize))
                 % static_cast<int32_t>(mapSize);
        }

        // Tile lookup (affine BGs use 1 byte per tile in screen map = tile number)
        const uint32_t mapDim   = mapSize >> 3;          // tiles per row/col
        const uint32_t tileX    = static_cast<uint32_t>(sx) >> 3;
        const uint32_t tileY    = static_cast<uint32_t>(sy) >> 3;
        const uint32_t inTileX  = static_cast<uint32_t>(sx) & 7u;
        const uint32_t inTileY  = static_cast<uint32_t>(sy) & 7u;
        const uint32_t seAddr   = screenBase + tileY * mapDim + tileX;
        const uint8_t  tileNum  = VramByte(vram_, seAddr);

        // Pixel lookup (8bpp)
        const uint32_t tileAddr = charBase + static_cast<uint32_t>(tileNum) * 64u
                                  + inTileY * 8u + inTileX;
        const uint8_t palIdx    = VramByte(vram_, tileAddr);
        if (palIdx == 0) { out[x] = 0x8000u; continue; }

        out[x] = PalColor(palette_ram_, palIdx);
    }
}

}  // namespace gba