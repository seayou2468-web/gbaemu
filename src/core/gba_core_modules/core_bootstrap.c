#include "../gba_core.h"
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

/* ===== Imported from reference implementation/core.c ===== */
/* ===== Imported from reference implementation/io.c ===== */
/* ===== Imported from reference implementation/input.c ===== */
/* ===== Imported from reference implementation/gbp.c ===== */
/* ===== Imported from reference implementation/dolphin.c ===== */
static const struct mCoreChannelInfo _GBAVideoLayers[] = {
	{ GBA_LAYER_BG0, "bg0", "Background 0", NULL },
	{ GBA_LAYER_BG1, "bg1", "Background 1", NULL },
	{ GBA_LAYER_BG2, "bg2", "Background 2", NULL },
	{ GBA_LAYER_BG3, "bg3", "Background 3", NULL },
	{ GBA_LAYER_OBJ, "obj", "Objects", NULL },
	{ GBA_LAYER_WIN0, "win0", "Window 0", NULL },
	{ GBA_LAYER_WIN1, "win1", "Window 1", NULL },
	{ GBA_LAYER_OBJWIN, "objwin", "Object Window", NULL },
};

static const struct mCoreChannelInfo _GBAAudioChannels[] = {
	{ 0, "ch1", "PSG Channel 1", "Square/Sweep" },
	{ 1, "ch2", "PSG Channel 2", "Square" },
	{ 2, "ch3", "PSG Channel 3", "PCM" },
	{ 3, "ch4", "PSG Channel 4", "Noise" },
	{ 4, "chA", "FIFO Channel A", NULL },
	{ 5, "chB", "FIFO Channel B", NULL },
};

static const struct mCoreMemoryBlock _GBAMemoryBlocks[] = {
	{ -1, "mem", "All", "All", 0, 0x10000000, 0x10000000, mCORE_MEMORY_VIRTUAL },
	{ GBA_REGION_BIOS, "bios", "BIOS", "BIOS (16kiB)", GBA_BASE_BIOS, GBA_SIZE_BIOS, GBA_SIZE_BIOS, mCORE_MEMORY_READ | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_EWRAM, "wram", "EWRAM", "Working RAM (256kiB)", GBA_BASE_EWRAM, GBA_BASE_EWRAM + GBA_SIZE_EWRAM, GBA_SIZE_EWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IWRAM, "iwram", "IWRAM", "Internal Working RAM (32kiB)", GBA_BASE_IWRAM, GBA_BASE_IWRAM + GBA_SIZE_IWRAM, GBA_SIZE_IWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IO, "io", "MMIO", "Memory-Mapped I/O", GBA_BASE_IO, GBA_BASE_IO + GBA_SIZE_IO, GBA_SIZE_IO, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_PALETTE_RAM, "palette", "Palette", "Palette RAM (1kiB)", GBA_BASE_PALETTE_RAM, GBA_BASE_PALETTE_RAM + GBA_SIZE_PALETTE_RAM, GBA_SIZE_PALETTE_RAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_VRAM, "vram", "VRAM", "Video RAM (96kiB)", GBA_BASE_VRAM, GBA_BASE_VRAM + GBA_SIZE_VRAM, GBA_SIZE_VRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_OAM, "oam", "OAM", "OBJ Attribute Memory (1kiB)", GBA_BASE_OAM, GBA_BASE_OAM + GBA_SIZE_OAM, GBA_SIZE_OAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM0, "cart0", "ROM", "Game Pak (32MiB)", GBA_BASE_ROM0, GBA_BASE_ROM0 + GBA_SIZE_ROM0, GBA_SIZE_ROM0, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM1, "cart1", "ROM WS1", "Game Pak (Waitstate 1)", GBA_BASE_ROM1, GBA_BASE_ROM1 + GBA_SIZE_ROM1, GBA_SIZE_ROM1, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM2, "cart2", "ROM WS2", "Game Pak (Waitstate 2)", GBA_BASE_ROM2, GBA_BASE_ROM2 + GBA_SIZE_ROM2, GBA_SIZE_ROM2, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
};

static const struct mCoreMemoryBlock _GBAMemoryBlocksSRAM[] = {
	{ -1, "mem", "All", "All", 0, 0x10000000, 0x10000000, mCORE_MEMORY_VIRTUAL },
	{ GBA_REGION_BIOS, "bios", "BIOS", "BIOS (16kiB)", GBA_BASE_BIOS, GBA_SIZE_BIOS, GBA_SIZE_BIOS, mCORE_MEMORY_READ | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_EWRAM, "wram", "EWRAM", "Working RAM (256kiB)", GBA_BASE_EWRAM, GBA_BASE_EWRAM + GBA_SIZE_EWRAM, GBA_SIZE_EWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IWRAM, "iwram", "IWRAM", "Internal Working RAM (32kiB)", GBA_BASE_IWRAM, GBA_BASE_IWRAM + GBA_SIZE_IWRAM, GBA_SIZE_IWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IO, "io", "MMIO", "Memory-Mapped I/O", GBA_BASE_IO, GBA_BASE_IO + GBA_SIZE_IO, GBA_SIZE_IO, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_PALETTE_RAM, "palette", "Palette", "Palette RAM (1kiB)", GBA_BASE_PALETTE_RAM, GBA_BASE_PALETTE_RAM + GBA_SIZE_PALETTE_RAM, GBA_SIZE_PALETTE_RAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_VRAM, "vram", "VRAM", "Video RAM (96kiB)", GBA_BASE_VRAM, GBA_BASE_VRAM + GBA_SIZE_VRAM, GBA_SIZE_VRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_OAM, "oam", "OAM", "OBJ Attribute Memory (1kiB)", GBA_BASE_OAM, GBA_BASE_OAM + GBA_SIZE_OAM, GBA_SIZE_OAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM0, "cart0", "ROM", "Game Pak (32MiB)", GBA_BASE_ROM0, GBA_BASE_ROM0 + GBA_SIZE_ROM0, GBA_SIZE_ROM0, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM1, "cart1", "ROM WS1", "Game Pak (Waitstate 1)", GBA_BASE_ROM1, GBA_BASE_ROM1 + GBA_SIZE_ROM1, GBA_SIZE_ROM1, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM2, "cart2", "ROM WS2", "Game Pak (Waitstate 2)", GBA_BASE_ROM2, GBA_BASE_ROM2 + GBA_SIZE_ROM2, GBA_SIZE_ROM2, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_SRAM, "sram", "SRAM", "Static RAM (32kiB)", GBA_BASE_SRAM, GBA_BASE_SRAM + GBA_SIZE_SRAM, GBA_SIZE_SRAM, true },
};

static const struct mCoreMemoryBlock _GBAMemoryBlocksSRAM512[] = {
	{ -1, "mem", "All", "All", 0, 0x10000000, 0x10000000, mCORE_MEMORY_VIRTUAL },
	{ GBA_REGION_BIOS, "bios", "BIOS", "BIOS (16kiB)", GBA_BASE_BIOS, GBA_SIZE_BIOS, GBA_SIZE_BIOS, mCORE_MEMORY_READ | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_EWRAM, "wram", "EWRAM", "Working RAM (256kiB)", GBA_BASE_EWRAM, GBA_BASE_EWRAM + GBA_SIZE_EWRAM, GBA_SIZE_EWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IWRAM, "iwram", "IWRAM", "Internal Working RAM (32kiB)", GBA_BASE_IWRAM, GBA_BASE_IWRAM + GBA_SIZE_IWRAM, GBA_SIZE_IWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IO, "io", "MMIO", "Memory-Mapped I/O", GBA_BASE_IO, GBA_BASE_IO + GBA_SIZE_IO, GBA_SIZE_IO, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_PALETTE_RAM, "palette", "Palette", "Palette RAM (1kiB)", GBA_BASE_PALETTE_RAM, GBA_BASE_PALETTE_RAM + GBA_SIZE_PALETTE_RAM, GBA_SIZE_PALETTE_RAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_VRAM, "vram", "VRAM", "Video RAM (96kiB)", GBA_BASE_VRAM, GBA_BASE_VRAM + GBA_SIZE_VRAM, GBA_SIZE_VRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_OAM, "oam", "OAM", "OBJ Attribute Memory (1kiB)", GBA_BASE_OAM, GBA_BASE_OAM + GBA_SIZE_OAM, GBA_SIZE_OAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM0, "cart0", "ROM", "Game Pak (32MiB)", GBA_BASE_ROM0, GBA_BASE_ROM0 + GBA_SIZE_ROM0, GBA_SIZE_ROM0, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM1, "cart1", "ROM WS1", "Game Pak (Waitstate 1)", GBA_BASE_ROM1, GBA_BASE_ROM1 + GBA_SIZE_ROM1, GBA_SIZE_ROM1, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM2, "cart2", "ROM WS2", "Game Pak (Waitstate 2)", GBA_BASE_ROM2, GBA_BASE_ROM2 + GBA_SIZE_ROM2, GBA_SIZE_ROM2, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_SRAM, "sram", "SRAM", "Static RAM (64kiB)", GBA_BASE_SRAM, GBA_BASE_SRAM + GBA_SIZE_SRAM512, GBA_SIZE_SRAM512, true },
};

static const struct mCoreMemoryBlock _GBAMemoryBlocksFlash512[] = {
	{ -1, "mem", "All", "All", 0, 0x10000000, 0x10000000, mCORE_MEMORY_VIRTUAL },
	{ GBA_REGION_BIOS, "bios", "BIOS", "BIOS (16kiB)", GBA_BASE_BIOS, GBA_SIZE_BIOS, GBA_SIZE_BIOS, mCORE_MEMORY_READ | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_EWRAM, "wram", "EWRAM", "Working RAM (256kiB)", GBA_BASE_EWRAM, GBA_BASE_EWRAM + GBA_SIZE_EWRAM, GBA_SIZE_EWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IWRAM, "iwram", "IWRAM", "Internal Working RAM (32kiB)", GBA_BASE_IWRAM, GBA_BASE_IWRAM + GBA_SIZE_IWRAM, GBA_SIZE_IWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IO, "io", "MMIO", "Memory-Mapped I/O", GBA_BASE_IO, GBA_BASE_IO + GBA_SIZE_IO, GBA_SIZE_IO, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_PALETTE_RAM, "palette", "Palette", "Palette RAM (1kiB)", GBA_BASE_PALETTE_RAM, GBA_BASE_PALETTE_RAM + GBA_SIZE_PALETTE_RAM, GBA_SIZE_PALETTE_RAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_VRAM, "vram", "VRAM", "Video RAM (96kiB)", GBA_BASE_VRAM, GBA_BASE_VRAM + GBA_SIZE_VRAM, GBA_SIZE_VRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_OAM, "oam", "OAM", "OBJ Attribute Memory (1kiB)", GBA_BASE_OAM, GBA_BASE_OAM + GBA_SIZE_OAM, GBA_SIZE_OAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM0, "cart0", "ROM", "Game Pak (32MiB)", GBA_BASE_ROM0, GBA_BASE_ROM0 + GBA_SIZE_ROM0, GBA_SIZE_ROM0, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM1, "cart1", "ROM WS1", "Game Pak (Waitstate 1)", GBA_BASE_ROM1, GBA_BASE_ROM1 + GBA_SIZE_ROM1, GBA_SIZE_ROM1, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM2, "cart2", "ROM WS2", "Game Pak (Waitstate 2)", GBA_BASE_ROM2, GBA_BASE_ROM2 + GBA_SIZE_ROM2, GBA_SIZE_ROM2, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_SRAM, "sram", "Flash", "Flash Memory (64kiB)", GBA_BASE_SRAM, GBA_BASE_SRAM + GBA_SIZE_FLASH512, GBA_SIZE_FLASH512, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
};

static const struct mCoreMemoryBlock _GBAMemoryBlocksFlash1M[] = {
	{ -1, "mem", "All", "All", 0, 0x10000000, 0x10000000, mCORE_MEMORY_VIRTUAL },
	{ GBA_REGION_BIOS, "bios", "BIOS", "BIOS (16kiB)", GBA_BASE_BIOS, GBA_SIZE_BIOS, GBA_SIZE_BIOS, mCORE_MEMORY_READ | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_EWRAM, "wram", "EWRAM", "Working RAM (256kiB)", GBA_BASE_EWRAM, GBA_BASE_EWRAM + GBA_SIZE_EWRAM, GBA_SIZE_EWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IWRAM, "iwram", "IWRAM", "Internal Working RAM (32kiB)", GBA_BASE_IWRAM, GBA_BASE_IWRAM + GBA_SIZE_IWRAM, GBA_SIZE_IWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IO, "io", "MMIO", "Memory-Mapped I/O", GBA_BASE_IO, GBA_BASE_IO + GBA_SIZE_IO, GBA_SIZE_IO, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_PALETTE_RAM, "palette", "Palette", "Palette RAM (1kiB)", GBA_BASE_PALETTE_RAM, GBA_BASE_PALETTE_RAM + GBA_SIZE_PALETTE_RAM, GBA_SIZE_PALETTE_RAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_VRAM, "vram", "VRAM", "Video RAM (96kiB)", GBA_BASE_VRAM, GBA_BASE_VRAM + GBA_SIZE_VRAM, GBA_SIZE_VRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_OAM, "oam", "OAM", "OBJ Attribute Memory (1kiB)", GBA_BASE_OAM, GBA_BASE_OAM + GBA_SIZE_OAM, GBA_SIZE_OAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM0, "cart0", "ROM", "Game Pak (32MiB)", GBA_BASE_ROM0, GBA_BASE_ROM0 + GBA_SIZE_ROM0, GBA_SIZE_ROM0, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM1, "cart1", "ROM WS1", "Game Pak (Waitstate 1)", GBA_BASE_ROM1, GBA_BASE_ROM1 + GBA_SIZE_ROM1, GBA_SIZE_ROM1, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM2, "cart2", "ROM WS2", "Game Pak (Waitstate 2)", GBA_BASE_ROM2, GBA_BASE_ROM2 + GBA_SIZE_ROM2, GBA_SIZE_ROM2, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_SRAM, "sram", "Flash", "Flash Memory (128kiB)", GBA_BASE_SRAM, GBA_BASE_SRAM + GBA_SIZE_FLASH512, GBA_SIZE_FLASH1M, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED, 1, GBA_BASE_SRAM },
};

static const struct mCoreMemoryBlock _GBAMemoryBlocksEEPROM[] = {
	{ -1, "mem", "All", "All", 0, 0x10000000, 0x10000000, mCORE_MEMORY_VIRTUAL },
	{ GBA_REGION_BIOS, "bios", "BIOS", "BIOS (16kiB)", GBA_BASE_BIOS, GBA_SIZE_BIOS, GBA_SIZE_BIOS, mCORE_MEMORY_READ | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_EWRAM, "wram", "EWRAM", "Working RAM (256kiB)", GBA_BASE_EWRAM, GBA_BASE_EWRAM + GBA_SIZE_EWRAM, GBA_SIZE_EWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IWRAM, "iwram", "IWRAM", "Internal Working RAM (32kiB)", GBA_BASE_IWRAM, GBA_BASE_IWRAM + GBA_SIZE_IWRAM, GBA_SIZE_IWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IO, "io", "MMIO", "Memory-Mapped I/O", GBA_BASE_IO, GBA_BASE_IO + GBA_SIZE_IO, GBA_SIZE_IO, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_PALETTE_RAM, "palette", "Palette", "Palette RAM (1kiB)", GBA_BASE_PALETTE_RAM, GBA_BASE_PALETTE_RAM + GBA_SIZE_PALETTE_RAM, GBA_SIZE_PALETTE_RAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_VRAM, "vram", "VRAM", "Video RAM (96kiB)", GBA_BASE_VRAM, GBA_BASE_VRAM + GBA_SIZE_VRAM, GBA_SIZE_VRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_OAM, "oam", "OAM", "OBJ Attribute Memory (1kiB)", GBA_BASE_OAM, GBA_BASE_OAM + GBA_SIZE_OAM, GBA_SIZE_OAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM0, "cart0", "ROM", "Game Pak (32MiB)", GBA_BASE_ROM0, GBA_BASE_ROM0 + GBA_SIZE_ROM0, GBA_SIZE_ROM0, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM1, "cart1", "ROM WS1", "Game Pak (Waitstate 1)", GBA_BASE_ROM1, GBA_BASE_ROM1 + GBA_SIZE_ROM1, GBA_SIZE_ROM1, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM2, "cart2", "ROM WS2", "Game Pak (Waitstate 2)", GBA_BASE_ROM2, GBA_BASE_ROM2 + GBA_SIZE_ROM2, GBA_SIZE_ROM2, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_SRAM_MIRROR, "eeprom", "EEPROM", "EEPROM (8kiB)", 0, GBA_SIZE_EEPROM, GBA_SIZE_EEPROM, mCORE_MEMORY_RW },
};

static const struct mCoreMemoryBlock _GBAMemoryBlocksEEPROM512[] = {
	{ -1, "mem", "All", "All", 0, 0x10000000, 0x10000000, mCORE_MEMORY_VIRTUAL },
	{ GBA_REGION_BIOS, "bios", "BIOS", "BIOS (16kiB)", GBA_BASE_BIOS, GBA_SIZE_BIOS, GBA_SIZE_BIOS, mCORE_MEMORY_READ | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_EWRAM, "wram", "EWRAM", "Working RAM (256kiB)", GBA_BASE_EWRAM, GBA_BASE_EWRAM + GBA_SIZE_EWRAM, GBA_SIZE_EWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IWRAM, "iwram", "IWRAM", "Internal Working RAM (32kiB)", GBA_BASE_IWRAM, GBA_BASE_IWRAM + GBA_SIZE_IWRAM, GBA_SIZE_IWRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_IO, "io", "MMIO", "Memory-Mapped I/O", GBA_BASE_IO, GBA_BASE_IO + GBA_SIZE_IO, GBA_SIZE_IO, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_PALETTE_RAM, "palette", "Palette", "Palette RAM (1kiB)", GBA_BASE_PALETTE_RAM, GBA_BASE_PALETTE_RAM + GBA_SIZE_PALETTE_RAM, GBA_SIZE_PALETTE_RAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_VRAM, "vram", "VRAM", "Video RAM (96kiB)", GBA_BASE_VRAM, GBA_BASE_VRAM + GBA_SIZE_VRAM, GBA_SIZE_VRAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_OAM, "oam", "OAM", "OBJ Attribute Memory (1kiB)", GBA_BASE_OAM, GBA_BASE_OAM + GBA_SIZE_OAM, GBA_SIZE_OAM, mCORE_MEMORY_RW | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM0, "cart0", "ROM", "Game Pak (32MiB)", GBA_BASE_ROM0, GBA_BASE_ROM0 + GBA_SIZE_ROM0, GBA_SIZE_ROM0, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM1, "cart1", "ROM WS1", "Game Pak (Waitstate 1)", GBA_BASE_ROM1, GBA_BASE_ROM1 + GBA_SIZE_ROM1, GBA_SIZE_ROM1, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_ROM2, "cart2", "ROM WS2", "Game Pak (Waitstate 2)", GBA_BASE_ROM2, GBA_BASE_ROM2 + GBA_SIZE_ROM2, GBA_SIZE_ROM2, mCORE_MEMORY_READ | mCORE_MEMORY_WORM | mCORE_MEMORY_MAPPED },
	{ GBA_REGION_SRAM_MIRROR, "eeprom", "EEPROM", "EEPROM (512B)", 0, GBA_SIZE_EEPROM, GBA_SIZE_EEPROM512, mCORE_MEMORY_RW },
};

static const struct mCoreScreenRegion _GBAScreenRegions[] = {
	{ 0, "Screen", 0, 0, GBA_VIDEO_HORIZONTAL_PIXELS, GBA_VIDEO_VERTICAL_PIXELS }
};

static const struct mCoreRegisterInfo _GBARegisters[] = {
	{ "r0", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r1", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r2", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r3", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r4", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r5", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r6", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r7", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r8", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r9", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r10", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r11", NULL, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "r12", (const char*[]) { "ip", NULL }, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "sp", (const char*[]) { "r13", NULL }, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "lr", (const char*[]) { "r14", NULL }, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "pc", (const char*[]) { "r15", NULL }, 4, 0xFFFFFFFF, mCORE_REGISTER_GPR },
	{ "cpsr", NULL, 4, 0xF00000FF, mCORE_REGISTER_FLAGS },
	{ "spsr", NULL, 4, 0xF00000FF, mCORE_REGISTER_FLAGS },
	{ "spsr_irq", NULL, 4, 0xF00000FF, mCORE_REGISTER_FLAGS },
	{ "spsr_fiq", NULL, 4, 0xF00000FF, mCORE_REGISTER_FLAGS },
	{ "spsr_svc", NULL, 4, 0xF00000FF, mCORE_REGISTER_FLAGS },
	{ "spsr_abt", NULL, 4, 0xF00000FF, mCORE_REGISTER_FLAGS },
	{ "spsr_und", NULL, 4, 0xF00000FF, mCORE_REGISTER_FLAGS },
};

#define LOGO_CRC32 0xD0BEB55E

struct GBACore {
	struct mCore d;
	struct GBAVideoRenderer dummyRenderer;
	struct GBAVideoSoftwareRenderer renderer;
	struct mCoreCallbacks logCallbacks;
	struct mCPUComponent* components[CPU_COMPONENT_MAX];
	const struct Configuration* overrides;
	struct GBACartridgeOverride override;
	bool hasOverride;
	struct mDebuggerPlatform* debuggerPlatform;
	struct mCheatDevice* cheatDevice;
	struct mCoreMemoryBlock memoryBlocks[12];
	size_t nMemoryBlocks;
	int memoryBlockType;
};

#define _MAX(A, B) ((A > B) ? (A) : (B))
static_assert(sizeof(((struct GBACore*) 0)->memoryBlocks) >=
	_MAX(
		_MAX(
			_MAX(
				sizeof(_GBAMemoryBlocksSRAM),
				sizeof(_GBAMemoryBlocksSRAM512)
			),
			_MAX(
				sizeof(_GBAMemoryBlocksFlash512),
				sizeof(_GBAMemoryBlocksFlash1M)
			)
		),
		_MAX(
			_MAX(
				sizeof(_GBAMemoryBlocksEEPROM),
				sizeof(_GBAMemoryBlocksEEPROM512)
			),
			sizeof(_GBAMemoryBlocks)
		)
	),
	"GBACore memoryBlocks sized too small");
#undef _MAX

static bool _GBACoreInit(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;

	struct ARMCore* cpu = anonymousMemoryMap(sizeof(struct ARMCore));
	struct GBA* gba = anonymousMemoryMap(sizeof(struct GBA));
	if (!cpu || !gba) {
		free(cpu);
		free(gba);
		return false;
	}
	core->cpu = cpu;
	core->board = gba;
	core->timing = &gba->timing;
	core->debugger = NULL;
	core->symbolTable = NULL;
	core->videoLogger = NULL;
	gbacore->hasOverride = false;
	gbacore->overrides = NULL;
	gbacore->debuggerPlatform = NULL;
	gbacore->cheatDevice = NULL;
	gbacore->nMemoryBlocks = 0;
	gbacore->memoryBlockType = -2;

	GBACreate(gba);
	// TODO: Restore cheats
	memset(gbacore->components, 0, sizeof(gbacore->components));
	ARMSetComponents(cpu, &gba->d, CPU_COMPONENT_MAX, gbacore->components);
	ARMInit(cpu);
	mRTCGenericSourceInit(&core->rtc, core);
	gba->rtcSource = &core->rtc.d;

	GBAVideoDummyRendererCreate(&gbacore->dummyRenderer);
	GBAVideoAssociateRenderer(&gba->video, &gbacore->dummyRenderer);

	GBAVideoSoftwareRendererCreate(&gbacore->renderer);
	gbacore->renderer.outputBuffer = NULL;

#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
	mDirectorySetInit(&core->dirs);
#endif

	return true;
}

static void _GBACoreDeinit(struct mCore* core) {
	ARMDeinit(core->cpu);
	GBADestroy(core->board);
	mappedMemoryFree(core->cpu, sizeof(struct ARMCore));
	mappedMemoryFree(core->board, sizeof(struct GBA));
#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
	mDirectorySetDeinit(&core->dirs);
#endif
	struct GBACore* gbacore = (struct GBACore*) core;
	gbacore->debuggerPlatform = NULL;
	gbacore->cheatDevice = NULL;
	mCoreConfigFreeOpts(&core->opts);
	free(core);
}

static enum mPlatform _GBACorePlatform(const struct mCore* core) {
	UNUSED(core);
	return mPLATFORM_GBA;
}

static bool _GBACoreSupportsFeature(const struct mCore* core, enum mCoreFeature feature) {
	UNUSED(core);
	UNUSED(feature);
	return false;
}

static void _GBACoreSetSync(struct mCore* core, struct mCoreSync* sync) {
	struct GBA* gba = core->board;
	gba->sync = sync;
}

static void _GBACoreLoadConfig(struct mCore* core, const struct mCoreConfig* config) {
	UNUSED(core);
	UNUSED(config);
}

static void _GBACoreReloadConfigOption(struct mCore* core, const char* option, const struct mCoreConfig* config) {
	UNUSED(core);
	UNUSED(option);
	UNUSED(config);
}

static void _GBACoreSetOverride(struct mCore* core, const void* override) {
	struct GBACore* gbacore = (struct GBACore*) core;
	memcpy(&gbacore->override, override, sizeof(gbacore->override));
	gbacore->hasOverride = true;
}

static void _GBACoreBaseVideoSize(const struct mCore* core, unsigned* width, unsigned* height) {
	UNUSED(core);
	*width = GBA_VIDEO_HORIZONTAL_PIXELS;
	*height = GBA_VIDEO_VERTICAL_PIXELS;
}

static void _GBACoreCurrentVideoSize(const struct mCore* core, unsigned* width, unsigned* height) {
	UNUSED(core);
	*width = GBA_VIDEO_HORIZONTAL_PIXELS;
	*height = GBA_VIDEO_VERTICAL_PIXELS;
}

static unsigned _GBACoreVideoScale(const struct mCore* core) {
	UNUSED(core);
	return 1;
}

static size_t _GBACoreScreenRegions(const struct mCore* core, const struct mCoreScreenRegion** regions) {
	UNUSED(core);
	*regions = _GBAScreenRegions;
	return 1;
}

static void _GBACoreSetVideoBuffer(struct mCore* core, mColor* buffer, size_t stride) {
	struct GBACore* gbacore = (struct GBACore*) core;
	gbacore->renderer.outputBuffer = buffer;
	gbacore->renderer.outputBufferStride = stride;
	memset(gbacore->renderer.scanlineDirty, 0xFFFFFFFF, sizeof(gbacore->renderer.scanlineDirty));
}

static void _GBACoreSetVideoGLTex(struct mCore* core, unsigned texid) {
	UNUSED(core);
	UNUSED(texid);
}

static void _GBACoreGetPixels(struct mCore* core, const void** buffer, size_t* stride) {
	struct GBA* gba = core->board;
	gba->video.renderer->getPixels(gba->video.renderer, stride, buffer);
}

static void _GBACorePutPixels(struct mCore* core, const void* buffer, size_t stride) {
	struct GBA* gba = core->board;
	gba->video.renderer->putPixels(gba->video.renderer, stride, buffer);
}

static unsigned _GBACoreAudioSampleRate(const struct mCore* core) {
	struct GBA* gba = core->board;
	return GBA_ARM7TDMI_FREQUENCY / gba->audio.sampleInterval;
}

static struct mAudioBuffer* _GBACoreGetAudioBuffer(struct mCore* core) {
	struct GBA* gba = core->board;
	return &gba->audio.psg.buffer;
}

static void _GBACoreSetAudioBufferSize(struct mCore* core, size_t samples) {
	struct GBA* gba = core->board;
	GBAAudioResizeBuffer(&gba->audio, samples);
}

static size_t _GBACoreGetAudioBufferSize(struct mCore* core) {
	struct GBA* gba = core->board;
	return gba->audio.samples;
}

static void _GBACoreAddCoreCallbacks(struct mCore* core, struct mCoreCallbacks* coreCallbacks) {
	struct GBA* gba = core->board;
	*mCoreCallbacksListAppend(&gba->coreCallbacks) = *coreCallbacks;
}

static void _GBACoreClearCoreCallbacks(struct mCore* core) {
	struct GBA* gba = core->board;
	mCoreCallbacksListClear(&gba->coreCallbacks);
}

static void _GBACoreSetAVStream(struct mCore* core, struct mAVStream* stream) {
	struct GBA* gba = core->board;
	gba->stream = stream;
	if (stream && stream->videoDimensionsChanged) {
		unsigned width, height;
		core->currentVideoSize(core, &width, &height);
		stream->videoDimensionsChanged(stream, width, height);
	}
	if (stream && stream->audioRateChanged) {
		stream->audioRateChanged(stream, GBA_ARM7TDMI_FREQUENCY / gba->audio.sampleInterval);
	}
}

static bool _GBACoreLoadROM(struct mCore* core, struct VFile* vf) {
	struct GBACore* gbacore = (struct GBACore*) core;
#ifdef USE_ELF
	struct ELF* elf = ELFOpen(vf);
	if (elf) {
		if (GBAVerifyELFEntry(elf, GBA_BASE_ROM0)) {
			GBALoadNull(core->board);
		}
		bool success = mCoreLoadELF(core, elf);
		ELFClose(elf);
		if (success) {
			vf->close(vf);
		}
		return success;
	}
#endif
	if (GBAIsMB(vf)) {
		return GBALoadMB(core->board, vf);
	}
	gbacore->memoryBlockType = -2;
	return GBALoadROM(core->board, vf);
}

static bool _GBACoreLoadBIOS(struct mCore* core, struct VFile* vf, int type) {
	UNUSED(type);
	if (!GBAIsBIOS(vf)) {
		return false;
	}
	GBALoadBIOS(core->board, vf);
	return true;
}

static bool _GBACoreLoadSave(struct mCore* core, struct VFile* vf) {
	return GBALoadSave(core->board, vf);
}

static bool _GBACoreLoadTemporarySave(struct mCore* core, struct VFile* vf) {
	struct GBA* gba = core->board;
	GBASavedataMask(&gba->memory.savedata, vf, false);
	return true; // TODO: Return a real value
}

static bool _GBACoreLoadPatch(struct mCore* core, struct VFile* vf) {
	if (!vf) {
		return false;
	}
	struct Patch patch;
	if (!loadPatch(vf, &patch)) {
		return false;
	}
	GBAApplyPatch(core->board, &patch);
	return true;
}

static void _GBACoreUnloadROM(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;
	gbacore->cheatDevice = NULL;
	GBAUnloadROM(core->board);
}

static size_t _GBACoreROMSize(const struct mCore* core) {
	const struct GBA* gba = (const struct GBA*) core->board;
	if (gba->romVf) {
		return gba->romVf->size(gba->romVf);
	}
	if (gba->mbVf) {
		return gba->mbVf->size(gba->mbVf);
	}
	return gba->pristineRomSize;
}

static void _GBACoreChecksum(const struct mCore* core, void* data, enum mCoreChecksumType type) {
	const struct GBA* gba = (const struct GBA*) core->board;
	switch (type) {
	case mCHECKSUM_CRC32:
		memcpy(data, &gba->romCrc32, sizeof(gba->romCrc32));
		break;
	case mCHECKSUM_MD5:
		if (gba->romVf) {
			md5File(gba->romVf, data);
		} else if (gba->mbVf) {
			md5File(gba->mbVf, data);
		} else if (gba->memory.rom && gba->isPristine) {
			md5Buffer(gba->memory.rom, gba->pristineRomSize, data);
		} else if (gba->memory.rom) {
			md5Buffer(gba->memory.rom, gba->memory.romSize, data);
		} else {
			md5Buffer("", 0, data);
		}
		break;
	case mCHECKSUM_SHA1:
		if (gba->romVf) {
			sha1File(gba->romVf, data);
		} else if (gba->mbVf) {
			sha1File(gba->mbVf, data);
		} else if (gba->memory.rom && gba->isPristine) {
			sha1Buffer(gba->memory.rom, gba->pristineRomSize, data);
		} else if (gba->memory.rom) {
			sha1Buffer(gba->memory.rom, gba->memory.romSize, data);
		} else {
			sha1Buffer("", 0, data);
		}
		break;
	}
	return;
}

static void _GBACoreReset(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;
	struct GBA* gba = (struct GBA*) core->board;
	if (gbacore->renderer.outputBuffer) {
		GBAVideoAssociateRenderer(&gba->video, &gbacore->renderer.d);
	}

	gba->memory.hw.devices &= ~HW_GB_PLAYER_DETECTION;
	if (gbacore->hasOverride) {
		GBAOverrideApply(gba, &gbacore->override);
	} else {
		GBAOverrideApplyDefaults(gba, gbacore->overrides);
	}
	gbacore->memoryBlockType = -2;

	ARMReset(core->cpu);
	bool forceSkip = gba->mbVf || (core->opts.skipBios && (gba->romVf || gba->memory.rom));
	if (!forceSkip && (gba->romVf || gba->memory.rom) && gba->pristineRomSize >= 0xA0 && gba->biosVf) {
		uint32_t crc = doCrc32(&gba->memory.rom[1], 0x9C);
		if (crc != LOGO_CRC32) {
			mLOG(STATUS, WARN, "Invalid logo, skipping BIOS");
			forceSkip = true;
		}
	}

	if (forceSkip) {
		GBASkipBIOS(core->board);
	}

	mTimingInterrupt(&gba->timing);
}

static void _GBACoreRunFrame(struct mCore* core) {
	struct GBA* gba = core->board;
	uint32_t frameCounter = gba->video.frameCounter;
	uint32_t startCycle = mTimingCurrentTime(&gba->timing);
	while (gba->video.frameCounter == frameCounter && mTimingCurrentTime(&gba->timing) - startCycle < VIDEO_TOTAL_LENGTH + VIDEO_HORIZONTAL_LENGTH) {
		ARMRunLoop(core->cpu);
	}
}

static void _GBACoreRunLoop(struct mCore* core) {
	ARMRunLoop(core->cpu);
}

static void _GBACoreStep(struct mCore* core) {
	ARMRun(core->cpu);
}

static size_t _GBACoreStateSize(struct mCore* core) {
	UNUSED(core);
	return sizeof(struct GBASerializedState);
}

static bool _GBACoreLoadState(struct mCore* core, const void* state) {
	return GBADeserialize(core->board, state);
}

static bool _GBACoreSaveState(struct mCore* core, void* state) {
	GBASerialize(core->board, state);
	return true;
}

static bool _GBACoreLoadExtraState(struct mCore* core, const struct mStateExtdata* extdata) {
	struct GBA* gba = core->board;
	struct mStateExtdataItem item;
	bool ok = true;
	if (mStateExtdataGet(extdata, EXTDATA_SUBSYSTEM_START + GBA_SUBSYSTEM_VIDEO_RENDERER, &item)) {
		if ((uint32_t) item.size > sizeof(uint32_t)) {
			uint32_t type;
			LOAD_32(type, 0, item.data);
			if (type == gba->video.renderer->rendererId(gba->video.renderer)) {
				ok = gba->video.renderer->loadState(gba->video.renderer,
				                                    (void*) ((uintptr_t) item.data + sizeof(uint32_t)),
				                                    item.size - sizeof(type)) && ok;
			}
		} else if (item.data) {
			ok = false;
		}
	}
	if (gba->sio.driver && gba->sio.driver->driverId && gba->sio.driver->loadState &&
	    mStateExtdataGet(extdata, EXTDATA_SUBSYSTEM_START + GBA_SUBSYSTEM_SIO_DRIVER, &item)) {
		if ((uint32_t) item.size > sizeof(uint32_t)) {
			uint32_t type;
			LOAD_32(type, 0, item.data);
			if (type == gba->sio.driver->driverId(gba->sio.driver)) {
				ok = gba->sio.driver->loadState(gba->sio.driver,
				                                (void*) ((uintptr_t) item.data + sizeof(uint32_t)),
				                                item.size - sizeof(type)) && ok;
			}
		} else if (item.data) {
			ok = false;
		}
	}
	return ok;
}

static bool _GBACoreSaveExtraState(struct mCore* core, struct mStateExtdata* extdata) {
	struct GBA* gba = core->board;
	void* buffer = NULL;
	size_t size = 0;
	gba->video.renderer->saveState(gba->video.renderer, &buffer, &size);
	if (size > 0 && buffer) {
		struct mStateExtdataItem item;
		item.size = size + sizeof(uint32_t);
		item.data = malloc(item.size);
		item.clean = free;
		uint32_t type = gba->video.renderer->rendererId(gba->video.renderer);
		STORE_32(type, 0, item.data);
		memcpy((void*) ((uintptr_t) item.data + sizeof(uint32_t)), buffer, size);
		mStateExtdataPut(extdata, EXTDATA_SUBSYSTEM_START + GBA_SUBSYSTEM_VIDEO_RENDERER, &item);
	}
	if (buffer) {
		free(buffer);
		buffer = NULL;
	}
	size = 0;

	if (gba->sio.driver && gba->sio.driver->driverId && gba->sio.driver->saveState) {
		gba->sio.driver->saveState(gba->sio.driver, &buffer, &size);
		if (size > 0 && buffer) {
			struct mStateExtdataItem item;
			item.size = size + sizeof(uint32_t);
			item.data = malloc(item.size);
			item.clean = free;
			uint32_t type = gba->sio.driver->driverId(gba->sio.driver);
			STORE_32(type, 0, item.data);
			memcpy((void*) ((uintptr_t) item.data + sizeof(uint32_t)), buffer, size);
			mStateExtdataPut(extdata, EXTDATA_SUBSYSTEM_START + GBA_SUBSYSTEM_SIO_DRIVER, &item);
		}
		if (buffer) {
			free(buffer);
			buffer = NULL;
		}
		size = 0;
	}

	return true;
}

static void _GBACoreSetKeys(struct mCore* core, uint32_t keys) {
	struct GBA* gba = core->board;
	gba->keysActive = keys;
	GBATestKeypadIRQ(gba);
}

static void _GBACoreAddKeys(struct mCore* core, uint32_t keys) {
	struct GBA* gba = core->board;
	gba->keysActive |= keys;
	GBATestKeypadIRQ(gba);
}

static void _GBACoreClearKeys(struct mCore* core, uint32_t keys) {
	struct GBA* gba = core->board;
	gba->keysActive &= ~keys;
	GBATestKeypadIRQ(gba);
}

static uint32_t _GBACoreGetKeys(struct mCore* core) {
	struct GBA* gba = core->board;
	return gba->keysActive;
}

static void _GBACoreSetPeripheral(struct mCore* core, int type, void* periph) {
	struct GBA* gba = core->board;
	switch (type) {
	case mPERIPH_ROTATION:
		gba->rotationSource = periph;
		break;
	case mPERIPH_RUMBLE:
		gba->rumble = periph;
		break;
	case mPERIPH_GBA_LUMINANCE:
		gba->luminanceSource = periph;
		break;
	case mPERIPH_GBA_LINK_PORT:
		GBASIOSetDriver(&gba->sio, periph);
		break;
	default:
		return;
	}
}

static void* _GBACoreGetPeripheral(struct mCore* core, int type) {
	struct GBA* gba = core->board;
	switch (type) {
	case mPERIPH_ROTATION:
		return gba->rotationSource;
	case mPERIPH_RUMBLE:
		return gba->rumble;
	case mPERIPH_GBA_LUMINANCE:
		return gba->luminanceSource;
	default:
		return NULL;
	}
}

static uint32_t _GBACoreBusRead8(struct mCore* core, uint32_t address) {
	struct ARMCore* cpu = core->cpu;
	return cpu->memory.load8(cpu, address, 0);
}

static uint32_t _GBACoreBusRead16(struct mCore* core, uint32_t address) {
	struct ARMCore* cpu = core->cpu;
	return cpu->memory.load16(cpu, address, 0);

}

static uint32_t _GBACoreBusRead32(struct mCore* core, uint32_t address) {
	struct ARMCore* cpu = core->cpu;
	return cpu->memory.load32(cpu, address, 0);
}

static void _GBACoreBusWrite8(struct mCore* core, uint32_t address, uint8_t value) {
	struct ARMCore* cpu = core->cpu;
	cpu->memory.store8(cpu, address, value, 0);
}

static void _GBACoreBusWrite16(struct mCore* core, uint32_t address, uint16_t value) {
	struct ARMCore* cpu = core->cpu;
	cpu->memory.store16(cpu, address, value, 0);
}

static void _GBACoreBusWrite32(struct mCore* core, uint32_t address, uint32_t value) {
	struct ARMCore* cpu = core->cpu;
	cpu->memory.store32(cpu, address, value, 0);
}

static uint32_t _GBACoreRawRead8(struct mCore* core, uint32_t address, int segment) {
	UNUSED(segment);
	struct ARMCore* cpu = core->cpu;
	return GBAView8(cpu, address);
}

static uint32_t _GBACoreRawRead16(struct mCore* core, uint32_t address, int segment) {
	UNUSED(segment);
	struct ARMCore* cpu = core->cpu;
	return GBAView16(cpu, address);
}

static uint32_t _GBACoreRawRead32(struct mCore* core, uint32_t address, int segment) {
	UNUSED(segment);
	struct ARMCore* cpu = core->cpu;
	return GBAView32(cpu, address);
}

static void _GBACoreRawWrite8(struct mCore* core, uint32_t address, int segment, uint8_t value) {
	UNUSED(segment);
	struct ARMCore* cpu = core->cpu;
	GBAWrite8(cpu, address, value);
}

static void _GBACoreRawWrite16(struct mCore* core, uint32_t address, int segment, uint16_t value) {
	UNUSED(segment);
	struct ARMCore* cpu = core->cpu;
	GBAWrite16(cpu, address, value);
}

static void _GBACoreRawWrite32(struct mCore* core, uint32_t address, int segment, uint32_t value) {
	UNUSED(segment);
	struct ARMCore* cpu = core->cpu;
	GBAWrite32(cpu, address, value);
}

static struct mCheatDevice* _GBACoreCheatDevice(struct mCore* core) {
	UNUSED(core);
	return NULL;
}

static size_t _GBACoreSavedataClone(struct mCore* core, void** sram) {
	struct GBA* gba = core->board;
	size_t size = GBASavedataSize(&gba->memory.savedata);
	if (!size) {
		*sram = NULL;
		return 0;
	}
	*sram = malloc(size);
	struct VFile* vf = VFileFromMemory(*sram, size);
	if (!vf) {
		free(*sram);
		*sram = NULL;
		return 0;
	}
	bool success = GBASavedataClone(&gba->memory.savedata, vf);
	vf->close(vf);
	if (!success) {
		free(*sram);
		*sram = NULL;
		return 0;
	}
	return size;
}

static bool _GBACoreSavedataRestore(struct mCore* core, const void* sram, size_t size, bool writeback) {
	struct VFile* vf = VFileMemChunk(sram, size);
	if (!vf) {
		return false;
	}
	struct GBA* gba = core->board;
	bool success = true;
	if (writeback) {
		success = GBASavedataLoad(&gba->memory.savedata, vf);
		vf->close(vf);
	} else {
		GBASavedataMask(&gba->memory.savedata, vf, true);
	}
	return success;
}

static size_t _GBACoreListVideoLayers(const struct mCore* core, const struct mCoreChannelInfo** info) {
	UNUSED(core);
	if (info) {
		*info = _GBAVideoLayers;
	}
	return sizeof(_GBAVideoLayers) / sizeof(*_GBAVideoLayers);
}

static size_t _GBACoreListAudioChannels(const struct mCore* core, const struct mCoreChannelInfo** info) {
	UNUSED(core);
	if (info) {
		*info = _GBAAudioChannels;
	}
	return sizeof(_GBAAudioChannels) / sizeof(*_GBAAudioChannels);
}

static void _GBACoreEnableVideoLayer(struct mCore* core, size_t id, bool enable) {
	struct GBA* gba = core->board;
	switch (id) {
	case GBA_LAYER_BG0:
	case GBA_LAYER_BG1:
	case GBA_LAYER_BG2:
	case GBA_LAYER_BG3:
		gba->video.renderer->disableBG[id] = !enable;
		break;
	case GBA_LAYER_OBJ:
		gba->video.renderer->disableOBJ = !enable;
		break;
	case GBA_LAYER_WIN0:
		gba->video.renderer->disableWIN[0] = !enable;
		break;
	case GBA_LAYER_WIN1:
		gba->video.renderer->disableWIN[1] = !enable;
		break;
	case GBA_LAYER_OBJWIN:
		gba->video.renderer->disableOBJWIN = !enable;
		break;
	default:
		break;
	}
}

static void _GBACoreEnableAudioChannel(struct mCore* core, size_t id, bool enable) {
	struct GBA* gba = core->board;
	switch (id) {
	case 0:
	case 1:
	case 2:
	case 3:
		gba->audio.psg.forceDisableCh[id] = !enable;
		break;
	case 4:
		gba->audio.forceDisableChA = !enable;
		break;
	case 5:
		gba->audio.forceDisableChB = !enable;
		break;
	default:
		break;
	}
}

static void _GBACoreAdjustVideoLayer(struct mCore* core, size_t id, int32_t x, int32_t y) {
	struct GBACore* gbacore = (struct GBACore*) core;
	switch (id) {
	case GBA_LAYER_BG0:
	case GBA_LAYER_BG1:
	case GBA_LAYER_BG2:
	case GBA_LAYER_BG3:
		gbacore->renderer.bg[id].offsetX = x;
		gbacore->renderer.bg[id].offsetY = y;
		break;
	case GBA_LAYER_WIN0:
	case GBA_LAYER_WIN1:
		gbacore->renderer.winN[id - GBA_LAYER_WIN0].offsetX = x;
		gbacore->renderer.winN[id - GBA_LAYER_WIN0].offsetY = y;
		break;
	default:
		return;
	}
	memset(gbacore->renderer.scanlineDirty, 0xFFFFFFFF, sizeof(gbacore->renderer.scanlineDirty));
}

struct mCore* GBACoreCreate(void) {
	struct GBACore* gbacore = malloc(sizeof(*gbacore));
	struct mCore* core = &gbacore->d;
	memset(&core->opts, 0, sizeof(core->opts));
	core->cpu = NULL;
	core->board = NULL;
	core->debugger = NULL;
	return core;
}

static bool _GBAVLPInit(struct mCore* core) {
	UNUSED(core);
	return false;
}

static void _GBAVLPDeinit(struct mCore* core) {
	UNUSED(core);
}

static void _GBAVLPReset(struct mCore* core) {
	UNUSED(core);
}

static bool _GBAVLPLoadROM(struct mCore* core, struct VFile* vf) {
	UNUSED(core);
	UNUSED(vf);
	return false;
}

static bool _GBAVLPLoadState(struct mCore* core, const void* state) {
	UNUSED(core);
	UNUSED(state);
	return false;
}

struct mCore* GBAVideoLogPlayerCreate(void) {
	return false;
}
