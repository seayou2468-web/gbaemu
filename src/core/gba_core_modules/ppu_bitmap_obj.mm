// ppu_bitmap_obj.mm
// GBA PPU: bitmap background modes (3/4/5) and OBJ sprite rendering.
// Full hardware accuracy: regular sprites, affine sprites, double-size, semi-transparent,
// OBJ-window, 1D/2D tile mapping, priority, hflip/vflip, mosaic.

#include "../gba_core.h"
#include <algorithm>
#include <cstring>

namespace gba {

// ── Local helpers ─────────────────────────────────────────────────────────────

static inline uint16_t IoR16b(const std::array<uint8_t, 1024>& io, uint32_t off) {
    return static_cast<uint16_t>(io[off & 0x3FFu] | (io[(off + 1) & 0x3FFu] << 8));
}

static inline uint16_t PalColorB(const std::array<uint8_t, 1024>& pal, uint32_t idx) {
    const uint32_t o = (idx & 0x1FFu) << 1;
    return static_cast<uint16_t>(pal[o] | (pal[o + 1] << 8));
}

// VRAM read with GBA address wrap:
// 0x0000–0x17FFF = linear; 0x18000–0x1FFFF mirrors 0x10000–0x17FFF
static inline uint8_t VramB(const std::array<uint8_t, 96 * 1024>& vram, uint32_t addr) {
    addr &= 0x1FFFFu;
    if (addr >= 0x18000u) addr = 0x10000u + (addr & 0x7FFFu);
    return vram[addr];
}

static inline uint16_t VramH(const std::array<uint8_t, 96 * 1024>& vram, uint32_t addr) {
    addr &= ~1u;
    const uint8_t lo = VramB(vram, addr);
    const uint8_t hi = VramB(vram, addr + 1);
    return static_cast<uint16_t>(lo | (hi << 8));
}

// ── Bitmap mode 3: 240×160, 15bpp direct colour ──────────────────────────────
// Each pixel = 16-bit BGR555 stored directly in VRAM starting at 0x00000.
// BG2 layer only; uses the affine matrix PA/PC for optional rotation/scaling
// (most games just keep PA=1.0, PC=0 for a 1:1 mapping).

void GBACore::DrawBgBitmap3(int y) {
    // Affine transform: src_x = (refx + PA*x) >> 8, src_y = (refy + PC*x) >> 8
    const int32_t pa  = static_cast<int32_t>(static_cast<int16_t>(IoR16b(io_regs_, 0x20u)));
    const int32_t pc  = static_cast<int32_t>(static_cast<int16_t>(IoR16b(io_regs_, 0x24u)));
    const int32_t rx  = ppu_bg2_refx_;
    const int32_t ry  = ppu_bg2_refy_;

    uint16_t* out = ppu_bg_[2].data();

    for (int x = 0; x < 240; ++x) {
        const int32_t sx = (rx + pa * x) >> 8;
        const int32_t sy = (ry + pc * x) >> 8;

        if (sx < 0 || sy < 0 || sx >= 240 || sy >= 160) {
            out[x] = 0x8000u;
            continue;
        }
        const uint32_t addr = static_cast<uint32_t>(sy * 240 + sx) * 2u;
        const uint16_t c = static_cast<uint16_t>(vram_[addr] | (vram_[addr + 1] << 8));
        out[x] = c & 0x7FFFu;  // strip bit15 (not used in mode3); ensure not transparent sentinel
        // Note: in mode3 every pixel is opaque (no palette-index-0 transparency)
        // We use the colour directly; if it happens to be 0x8000 we mask it to 0x7FFF.
        // (Colour 0x0000 = black, still valid.)
    }
}

// ── Bitmap mode 4: 240×160, 8bpp paletted, page-flipped ─────────────────────
// Pixel = 1-byte palette index. Palette index 0 = transparent within mode4 BG,
// rendered as the backdrop colour. Page 0 = VRAM 0x00000, Page 1 = VRAM 0x0A000.

void GBACore::DrawBgBitmap4(int y) {
    const uint16_t dispcnt = IoR16b(io_regs_, 0x00u);
    const uint32_t pageBase = (dispcnt & (1u << 4)) ? 0xA000u : 0u;

    const int32_t pa = static_cast<int32_t>(static_cast<int16_t>(IoR16b(io_regs_, 0x20u)));
    const int32_t pc = static_cast<int32_t>(static_cast<int16_t>(IoR16b(io_regs_, 0x24u)));
    const int32_t rx = ppu_bg2_refx_;
    const int32_t ry = ppu_bg2_refy_;

    uint16_t* out = ppu_bg_[2].data();

    for (int x = 0; x < 240; ++x) {
        const int32_t sx = (rx + pa * x) >> 8;
        const int32_t sy = (ry + pc * x) >> 8;

        if (sx < 0 || sy < 0 || sx >= 240 || sy >= 160) {
            out[x] = 0x8000u;
            continue;
        }
        const uint32_t addr    = pageBase + static_cast<uint32_t>(sy * 240 + sx);
        const uint8_t  palIdx  = vram_[addr & 0x17FFFu];
        if (palIdx == 0) { out[x] = 0x8000u; continue; }
        out[x] = PalColorB(palette_ram_, palIdx);
    }
}

// ── Bitmap mode 5: 160×128, 15bpp direct colour, page-flipped ───────────────
// Like mode 3 but smaller canvas (160×128). Pixels outside canvas = backdrop.

void GBACore::DrawBgBitmap5(int y) {
    const uint16_t dispcnt = IoR16b(io_regs_, 0x00u);
    const uint32_t pageBase = (dispcnt & (1u << 4)) ? 0xA000u : 0u;

    const int32_t pa = static_cast<int32_t>(static_cast<int16_t>(IoR16b(io_regs_, 0x20u)));
    const int32_t pc = static_cast<int32_t>(static_cast<int16_t>(IoR16b(io_regs_, 0x24u)));
    const int32_t rx = ppu_bg2_refx_;
    const int32_t ry = ppu_bg2_refy_;

    uint16_t* out = ppu_bg_[2].data();

    for (int x = 0; x < 240; ++x) {
        const int32_t sx = (rx + pa * x) >> 8;
        const int32_t sy = (ry + pc * x) >> 8;

        if (sx < 0 || sy < 0 || sx >= 160 || sy >= 128) {
            out[x] = 0x8000u;
            continue;
        }
        const uint32_t addr = pageBase + static_cast<uint32_t>(sy * 160 + sx) * 2u;
        const uint16_t c = static_cast<uint16_t>(vram_[addr & 0x17FFFu] | (vram_[(addr + 1) & 0x17FFFu] << 8));
        out[x] = c & 0x7FFFu;
    }
}

// ── OBJ sprite rendering (DrawObjects) ───────────────────────────────────────
//
// GBA OAM: 128 sprite entries × 8 bytes = 1024 bytes.
// Each entry: Attr0 (2B), Attr1 (2B), Attr2 (2B), Attr3/AffineD (2B).
// Affine matrices: 32 matrices interleaved in Attr3 of sprites 0–127 (4 sprites per matrix).
//
// Sprite sizes by (shape, size):
//   shape0=Square: 8,16,32,64
//   shape1=Wide:  16×8, 32×8, 32×16, 64×32
//   shape2=Tall:   8×16, 8×32, 16×32, 32×64
//
// Character mapping (DISPCNT[6]):
//   0 = 2D: tiles laid out in 32-tile-wide grid; row stride = 32 tiles
//   1 = 1D: tiles laid out sequentially (base_tile advances linearly)
//
// OBJ VRAM base: 0x10000 (in modes 0–2); tile index < 512 invalid in modes 3–5.
// Processing order: 127 → 0 (lower OAM index overwrites → higher priority).

// Sprite size table indexed by [shape][size]
static constexpr int kObjW[3][4] = { {8,16,32,64}, {16,32,32,64}, { 8, 8,16,32} };
static constexpr int kObjH[3][4] = { {8,16,32,64}, { 8, 8,16,32}, {16,32,32,64} };

void GBACore::DrawObjects(int y) {
    const uint16_t dispcnt  = IoR16b(io_regs_, 0x00u);
    const uint8_t  mode     = static_cast<uint8_t>(dispcnt & 7u);
    const bool     map1d    = (dispcnt & (1u << 6)) != 0;

    // Mosaic register: bits [11:8] = OBJ V mosaic size-1, bits [15:12] = OBJ H mosaic size-1
    const uint16_t mosaicReg = IoR16b(io_regs_, 0x4Cu);
    const int objMosaicH = static_cast<int>((mosaicReg >> 8)  & 0xFu) + 1;
    const int objMosaicV = static_cast<int>((mosaicReg >> 12) & 0xFu) + 1;

    uint16_t* objBuf   = ppu_obj_.data();
    uint8_t*  attrBuf  = ppu_obj_attr_.data();
    bool*     winBuf   = ppu_objwin_.data();

    // Process sprites from 127 to 0 so that sprite 0 overwrites sprite 127 (highest priority)
    for (int i = 127; i >= 0; --i) {
        const uint32_t base = static_cast<uint32_t>(i) * 8u;
        const uint16_t attr0 = static_cast<uint16_t>(oam_[base + 0] | (oam_[base + 1] << 8));
        const uint16_t attr1 = static_cast<uint16_t>(oam_[base + 2] | (oam_[base + 3] << 8));
        const uint16_t attr2 = static_cast<uint16_t>(oam_[base + 4] | (oam_[base + 5] << 8));

        // Attr0[9:8]: 00=regular, 01=affine, 10=disabled, 11=affine+double-size
        const uint8_t transMode = (attr0 >> 8) & 0x3u;
        if (transMode == 2) continue;  // disabled

        const bool isAffine     = (transMode & 1u) != 0;
        const bool doubleSize   = (transMode == 3);
        const uint8_t objMode   = static_cast<uint8_t>((attr0 >> 10) & 0x3u);
        // objMode: 0=normal, 1=semi-transparent, 2=OBJ-window, 3=prohibited
        if (objMode == 3) continue;

        const bool mosaicOn = (attr0 & (1u << 12)) != 0;
        const bool is256    = (attr0 & (1u << 13)) != 0;
        const uint8_t shape = static_cast<uint8_t>((attr0 >> 14) & 0x3u);
        if (shape == 3) continue;  // prohibited

        const uint8_t size  = static_cast<uint8_t>((attr1 >> 14) & 0x3u);
        int sprW = kObjW[shape][size];
        int sprH = kObjH[shape][size];

        // Bounding box (possibly double for affine+double-size)
        const int boxW = doubleSize ? sprW * 2 : sprW;
        const int boxH = doubleSize ? sprH * 2 : sprH;

        // Y coordinate (8-bit, treated as 0..255; sprites wrap at 256)
        const int sprY = static_cast<int>(attr0 & 0xFFu);
        // Detect if scanline y is within the sprite's bounding box
        int inY = y - sprY;
        if (inY < 0)    inY += 256;
        if (inY >= boxH) continue;  // not on this scanline

        // X coordinate: 9-bit signed
        int sprX = static_cast<int>((attr1 & 0x1FFu));
        if (sprX & 0x100) sprX -= 512;  // sign-extend from 9 bits

        // Tile data
        const uint32_t tileNum  = attr2 & 0x3FFu;
        const uint8_t  priority = static_cast<uint8_t>((attr2 >> 10) & 0x3u);
        const uint32_t palBank  = (attr2 >> 12) & 0xFu;

        // In modes 3-5, tile numbers < 512 are in the BG bitmap area and invalid for OBJ
        if (mode >= 3 && tileNum < 512) continue;

        // Tile size in bytes
        const uint32_t tileBytes = is256 ? 64u : 32u;
        // OBJ tile base in VRAM
        const uint32_t charBase  = 0x10000u;

        // Row stride for 2D mapping (32 tiles per row × tileBytes per tile)
        // For 1D: stride = sprW_tiles × tileBytes
        const int sprWTiles = sprW >> 3;
        const uint32_t rowStride = map1d
            ? static_cast<uint32_t>(sprWTiles) * tileBytes
            : 32u * tileBytes;

        // Affine matrix (if applicable)
        int16_t aPA = 0x100, aPB = 0, aPC = 0, aPD = 0x100;  // identity
        if (isAffine) {
            const uint8_t matIdx = static_cast<uint8_t>((attr1 >> 9) & 0x1Fu);
            // Matrix stored in OAM: mat[n].A = oam[n*32+6], .B = oam[n*32+14],
            //                       mat[n].C = oam[n*32+22], .D = oam[n*32+30]
            const uint32_t mBase = static_cast<uint32_t>(matIdx) * 32u;
            aPA = static_cast<int16_t>(oam_[(mBase +  6) & 0x3FFu] | (oam_[(mBase +  7) & 0x3FFu] << 8));
            aPB = static_cast<int16_t>(oam_[(mBase + 14) & 0x3FFu] | (oam_[(mBase + 15) & 0x3FFu] << 8));
            aPC = static_cast<int16_t>(oam_[(mBase + 22) & 0x3FFu] | (oam_[(mBase + 23) & 0x3FFu] << 8));
            aPD = static_cast<int16_t>(oam_[(mBase + 30) & 0x3FFu] | (oam_[(mBase + 31) & 0x3FFu] << 8));
        }

        // Draw each screen pixel in the sprite's X range
        const int screenXEnd = std::min(240, sprX + boxW);
        const int screenXBeg = std::max(0, sprX);

        for (int sx = screenXBeg; sx < screenXEnd; ++sx) {
            int inX = sx - sprX;   // pixel within bounding box, 0..boxW-1

            int localX, localY;

            if (isAffine) {
                // Affine: transform (inX, inY) back to sprite texture space.
                // Centre of bounding box = (boxW/2, boxH/2).
                const int cx = boxW >> 1;
                const int cy = boxH >> 1;
                const int dx = inX - cx, dy = inY - cy;
                // Sprite centre = (sprW/2, sprH/2) in texture
                int tx = ((static_cast<int32_t>(aPA) * dx + static_cast<int32_t>(aPB) * dy) >> 8) + (sprW >> 1);
                int ty = ((static_cast<int32_t>(aPC) * dx + static_cast<int32_t>(aPD) * dy) >> 8) + (sprH >> 1);
                if (tx < 0 || ty < 0 || tx >= sprW || ty >= sprH) continue;
                localX = tx;
                localY = ty;
                // Mosaic on affine sprites
                if (mosaicOn) {
                    localX = localX - (localX % objMosaicH);
                    localY = localY - (localY % objMosaicV);
                    if (localX >= sprW) localX = sprW - 1;
                    if (localY >= sprH) localY = sprH - 1;
                }
            } else {
                // Regular sprite
                localY = inY;
                localX = inX;
                // Mosaic
                if (mosaicOn) {
                    localX = localX - (localX % objMosaicH);
                    localY = localY - (localY % objMosaicV);
                    if (localX >= sprW) localX = sprW - 1;
                    if (localY >= sprH) localY = sprH - 1;
                }
                // V-flip
                if (!isAffine && (attr1 & (1u << 13))) localY = sprH - 1 - localY;
                // H-flip
                if (!isAffine && (attr1 & (1u << 12))) localX = sprW - 1 - localX;
            }

            // Tile coordinates within sprite
            const uint32_t tileX    = static_cast<uint32_t>(localX) >> 3;
            const uint32_t tileY    = static_cast<uint32_t>(localY) >> 3;
            const uint32_t inTileX  = static_cast<uint32_t>(localX) & 7u;
            const uint32_t inTileY  = static_cast<uint32_t>(localY) & 7u;

            // Tile address in VRAM
            uint32_t tileAddr;
            if (map1d) {
                // 1D: sequentially laid out
                tileAddr = charBase
                    + (tileNum * tileBytes)                     // base tile row 0
                    + tileY * rowStride                         // advance by sprite tile rows
                    + tileX * tileBytes                         // advance along X
                    + inTileY * (is256 ? 8u : 4u)               // row within tile
                    + (is256 ? inTileX : (inTileX >> 1));       // column within tile
            } else {
                // 2D: 32-tile-wide grid (tile numbers map into 2D grid)
                // Base tile selects position in the 32×32 tile grid
                const uint32_t baseTileX = tileNum & 31u;
                const uint32_t baseTileY = tileNum >> 5;
                const uint32_t absTileX  = baseTileX + tileX;
                const uint32_t absTileY  = baseTileY + tileY;
                tileAddr = charBase
                    + (absTileY * 32u + absTileX) * tileBytes
                    + inTileY * (is256 ? 8u : 4u)
                    + (is256 ? inTileX : (inTileX >> 1));
            }

            // OBJ VRAM is at 0x10000–0x17FFF (32KiB); addresses above wrap or are invalid
            tileAddr &= 0x17FFFu;

            uint8_t palIdx;
            if (is256) {
                palIdx = vram_[tileAddr];
            } else {
                const uint8_t packed = vram_[tileAddr];
                palIdx = (inTileX & 1u) ? (packed >> 4) : (packed & 0xFu);
            }
            if (palIdx == 0) continue;  // transparent

            // Sprite palette starts at entry 256 (second half of palette RAM)
            const uint16_t color = is256
                ? PalColorB(palette_ram_, 256u + palIdx)
                : PalColorB(palette_ram_, 256u + palBank * 16u + palIdx);

            if (objMode == 2) {
                // OBJ-window mode: mark this pixel as part of OBJWIN mask
                winBuf[sx] = true;
            } else {
                // Normal or semi-transparent sprite
                objBuf[sx]  = color;
                attrBuf[sx] = static_cast<uint8_t>(
                    (priority & 3u) |
                    ((objMode == 1) ? (1u << 2) : 0u)  // bit2 = semi-transparent
                );
            }
        }  // x loop
    }  // sprite loop
}

}  // namespace gba