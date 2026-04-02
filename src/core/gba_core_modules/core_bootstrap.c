#include "../gba_core.h"
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

/* ===== Imported from reference implementation/core.c ===== */
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

struct mVideoLogContext;

#define LOGO_CRC32 0xD0BEB55E

struct GBACore {
	struct mCore d;
	struct GBAVideoRenderer dummyRenderer;
	struct GBAVideoSoftwareRenderer renderer;
#ifdef BUILD_GLES3
	struct GBAVideoGLRenderer glRenderer;
#endif
#ifndef MINIMAL_CORE
	struct GBAVideoProxyRenderer vlProxy;
	struct GBAVideoProxyRenderer proxyRenderer;
	struct mVideoLogContext* logContext;
#endif
	struct mCoreCallbacks logCallbacks;
#ifndef DISABLE_THREADING
	struct mVideoThreadProxy threadProxy;
#endif
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
#ifndef MINIMAL_CORE
	gbacore->logContext = NULL;
#endif
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

#ifdef BUILD_GLES3
	GBAVideoGLRendererCreate(&gbacore->glRenderer);
	gbacore->glRenderer.outputTex = -1;
#endif

#ifndef DISABLE_THREADING
	mVideoThreadProxyCreate(&gbacore->threadProxy);
#endif
#ifndef MINIMAL_CORE
	gbacore->vlProxy.logger = NULL;
	gbacore->proxyRenderer.logger = NULL;
#endif

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
#ifdef ENABLE_DEBUGGERS
	if (core->symbolTable) {
		mDebuggerSymbolTableDestroy(core->symbolTable);
	}
#endif

	struct GBACore* gbacore = (struct GBACore*) core;
	free(gbacore->debuggerPlatform);
	if (gbacore->cheatDevice) {
		mCheatDeviceDestroy(gbacore->cheatDevice);
	}
	mCoreConfigFreeOpts(&core->opts);
	free(core);
}

static enum mPlatform _GBACorePlatform(const struct mCore* core) {
	UNUSED(core);
	return mPLATFORM_GBA;
}

static bool _GBACoreSupportsFeature(const struct mCore* core, enum mCoreFeature feature) {
	UNUSED(core);
	switch (feature) {
	case mCORE_FEATURE_OPENGL:
#ifdef BUILD_GLES3
		return true;
#else
		return false;
#endif
	default:
		return false;
	}
}

static void _GBACoreSetSync(struct mCore* core, struct mCoreSync* sync) {
	struct GBA* gba = core->board;
	gba->sync = sync;
}

static void _GBACoreLoadConfig(struct mCore* core, const struct mCoreConfig* config) {
	struct GBA* gba = core->board;
	if (core->opts.mute) {
		gba->audio.masterVolume = 0;
	} else {
		gba->audio.masterVolume = core->opts.volume;
	}
	gba->video.frameskip = core->opts.frameskip;

#if !defined(MINIMAL_CORE) || MINIMAL_CORE < 2
	struct GBACore* gbacore = (struct GBACore*) core;
	gbacore->overrides = mCoreConfigGetOverridesConst(config);
#endif

	const char* idleOptimization = mCoreConfigGetValue(config, "idleOptimization");
	if (idleOptimization) {
		if (strcasecmp(idleOptimization, "ignore") == 0) {
			gba->idleOptimization = IDLE_LOOP_IGNORE;
		} else if (strcasecmp(idleOptimization, "remove") == 0) {
			gba->idleOptimization = IDLE_LOOP_REMOVE;
		} else if (strcasecmp(idleOptimization, "detect") == 0) {
			if (gba->idleLoop == GBA_IDLE_LOOP_NONE) {
				gba->idleOptimization = IDLE_LOOP_DETECT;
			} else {
				gba->idleOptimization = IDLE_LOOP_REMOVE;
			}
		}
	}

	mCoreConfigGetBoolValue(config, "allowOpposingDirections", &gba->allowOpposingDirections);

	mCoreConfigCopyValue(&core->config, config, "allowOpposingDirections");
	mCoreConfigCopyValue(&core->config, config, "gba.bios");
	mCoreConfigCopyValue(&core->config, config, "gba.forceGbp");
	mCoreConfigCopyValue(&core->config, config, "vbaBugCompat");

#ifndef DISABLE_THREADING
	mCoreConfigCopyValue(&core->config, config, "threadedVideo");
#endif
	mCoreConfigCopyValue(&core->config, config, "hwaccelVideo");
	mCoreConfigCopyValue(&core->config, config, "videoScale");
}

static void _GBACoreReloadConfigOption(struct mCore* core, const char* option, const struct mCoreConfig* config) {
	struct GBA* gba = core->board;
	if (!config) {
		config = &core->config;
	}

	if (!option) {
		// Reload options from opts
		if (core->opts.mute) {
			gba->audio.masterVolume = 0;
		} else {
			gba->audio.masterVolume = core->opts.volume;
		}
		gba->video.frameskip = core->opts.frameskip;
		return;
	}

	if (strcmp("mute", option) == 0) {
		if (mCoreConfigGetBoolValue(config, "mute", &core->opts.mute)) {
			if (core->opts.mute) {
				gba->audio.masterVolume = 0;
			} else {
				gba->audio.masterVolume = core->opts.volume;
			}
		}
		return;
	}
	if (strcmp("volume", option) == 0) {
		if (mCoreConfigGetIntValue(config, "volume", &core->opts.volume) && !core->opts.mute) {
			gba->audio.masterVolume = core->opts.volume;
		}
		return;
	}
	if (strcmp("frameskip", option) == 0) {
		if (mCoreConfigGetIntValue(config, "frameskip", &core->opts.frameskip)) {
			gba->video.frameskip = core->opts.frameskip;
		}
		return;
	}
	if (strcmp("allowOpposingDirections", option) == 0) {
		if (config != &core->config) {
			mCoreConfigCopyValue(&core->config, config, "allowOpposingDirections");
		}
		mCoreConfigGetBoolValue(config, "allowOpposingDirections", &gba->allowOpposingDirections);
		return;
	}

	struct GBACore* gbacore = (struct GBACore*) core;
#ifdef BUILD_GLES3
	if (strcmp("videoScale", option) == 0) {
		if (config != &core->config) {
			mCoreConfigCopyValue(&core->config, config, "videoScale");
		}
		bool value;
		if (gbacore->glRenderer.outputTex != (unsigned) -1 && mCoreConfigGetBoolValue(&core->config, "hwaccelVideo", &value) && value) {
			int scale;
			mCoreConfigGetIntValue(config, "videoScale", &scale);
			GBAVideoGLRendererSetScale(&gbacore->glRenderer, scale);
		}
		return;
	}
#endif
	if (strcmp("hwaccelVideo", option) == 0) {
		struct GBAVideoRenderer* renderer = NULL;
		if (gbacore->renderer.outputBuffer) {
			renderer = &gbacore->renderer.d;
		}
#ifdef BUILD_GLES3
		bool value;
		if (gbacore->glRenderer.outputTex != (unsigned) -1 && mCoreConfigGetBoolValue(&core->config, "hwaccelVideo", &value) && value) {
			mCoreConfigGetIntValue(&core->config, "videoScale", &gbacore->glRenderer.scale);
			renderer = &gbacore->glRenderer.d;
		} else {
			gbacore->glRenderer.scale = 1;
		}
#endif
#ifndef MINIMAL_CORE
		if (renderer && core->videoLogger) {
			GBAVideoProxyRendererCreate(&gbacore->proxyRenderer, renderer, core->videoLogger);
			renderer = &gbacore->proxyRenderer.d;
		}
#endif
		if (renderer) {
			GBAVideoAssociateRenderer(&gba->video, renderer);
		}
	}

#ifndef MINIMAL_CORE
	if (strcmp("threadedVideo.flushScanline", option) == 0) {
		int flushScanline = -1;
		mCoreConfigGetIntValue(config, "threadedVideo.flushScanline", &flushScanline);
		gbacore->proxyRenderer.flushScanline = flushScanline;
	}
#endif
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
	int scale = 1;
#ifdef BUILD_GLES3
	const struct GBACore* gbacore = (const struct GBACore*) core;
	if (gbacore->glRenderer.outputTex != (unsigned) -1) {
		scale = gbacore->glRenderer.scale;
	}
#else
	UNUSED(core);
#endif

	*width = GBA_VIDEO_HORIZONTAL_PIXELS * scale;
	*height = GBA_VIDEO_VERTICAL_PIXELS * scale;
}

static unsigned _GBACoreVideoScale(const struct mCore* core) {
#ifdef BUILD_GLES3
	const struct GBACore* gbacore = (const struct GBACore*) core;
	if (gbacore->glRenderer.outputTex != (unsigned) -1) {
		return gbacore->glRenderer.scale;
	}
#else
	UNUSED(core);
#endif
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
#ifdef BUILD_GLES3
	struct GBACore* gbacore = (struct GBACore*) core;
	gbacore->glRenderer.outputTex = texid;
	gbacore->glRenderer.outputTexDirty = true;
#else
	UNUSED(core);
	UNUSED(texid);
#endif
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
	struct ARMCore* cpu = core->cpu;
	if (gbacore->cheatDevice) {
		ARMHotplugDetach(cpu, CPU_COMPONENT_CHEAT_DEVICE);
		cpu->components[CPU_COMPONENT_CHEAT_DEVICE] = NULL;
		mCheatDeviceDestroy(gbacore->cheatDevice);
		gbacore->cheatDevice = NULL;
	}
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
	bool value;
	UNUSED(value);
	if (gbacore->renderer.outputBuffer
#ifdef BUILD_GLES3
	    || gbacore->glRenderer.outputTex != (unsigned) -1
#endif
	) {
		struct GBAVideoRenderer* renderer = NULL;
		if (gbacore->renderer.outputBuffer) {
			renderer = &gbacore->renderer.d;
		}
#ifdef BUILD_GLES3
		if (gbacore->glRenderer.outputTex != (unsigned) -1 && mCoreConfigGetBoolValue(&core->config, "hwaccelVideo", &value) && value) {
			mCoreConfigGetIntValue(&core->config, "videoScale", &gbacore->glRenderer.scale);
			renderer = &gbacore->glRenderer.d;
		} else {
			gbacore->glRenderer.scale = 1;
		}
#endif
#ifndef DISABLE_THREADING
		if (mCoreConfigGetBoolValue(&core->config, "threadedVideo", &value) && value) {
			if (!core->videoLogger) {
				core->videoLogger = &gbacore->threadProxy.d;
			}
		}
#endif
#ifndef MINIMAL_CORE
		if (renderer && core->videoLogger) {
			GBAVideoProxyRendererCreate(&gbacore->proxyRenderer, renderer, core->videoLogger);
			renderer = &gbacore->proxyRenderer.d;

			int flushScanline = -1;
			mCoreConfigGetIntValue(&core->config, "threadedVideo.flushScanline", &flushScanline);
			gbacore->proxyRenderer.flushScanline = flushScanline;
		}
#endif
		if (renderer) {
			GBAVideoAssociateRenderer(&gba->video, renderer);
		}
	}

	bool forceGbp = false;
	bool vbaBugCompat = true;
	mCoreConfigGetBoolValue(&core->config, "gba.forceGbp", &forceGbp);
	mCoreConfigGetBoolValue(&core->config, "vbaBugCompat", &vbaBugCompat);
	if (!forceGbp) {
		gba->memory.hw.devices &= ~HW_GB_PLAYER_DETECTION;
	}
	if (gbacore->hasOverride) {
		GBAOverrideApply(gba, &gbacore->override);
	} else {
		GBAOverrideApplyDefaults(gba, gbacore->overrides);
	}
	if (forceGbp) {
		gba->memory.hw.devices |= HW_GB_PLAYER_DETECTION;
	}
	if (!vbaBugCompat) {
		gba->vbaBugCompat = false;
	}
	gbacore->memoryBlockType = -2;

#ifdef ENABLE_VFS
	if (!gba->biosVf && core->opts.useBios) {
		struct VFile* bios = NULL;
		bool found = false;
		if (core->opts.bios) {
			bios = VFileOpen(core->opts.bios, O_RDONLY);
			if (bios && GBAIsBIOS(bios)) {
				found = true;
			} else if (bios) {
				bios->close(bios);
				bios = NULL;
			}
		}
		if (!found) {
			const char* configPath = mCoreConfigGetValue(&core->config, "gba.bios");
			if (configPath) {
				bios = VFileOpen(configPath, O_RDONLY);
			}
			if (bios && GBAIsBIOS(bios)) {
				found = true;
			} else if (bios) {
				bios->close(bios);
				bios = NULL;
			}
		}
		if (!found) {
			char path[PATH_MAX];
			mCoreConfigDirectory(path, PATH_MAX);
			strncat(path, PATH_SEP "gba_bios.bin", PATH_MAX - strlen(path) - 1);
			bios = VFileOpen(path, O_RDONLY);
			if (bios && GBAIsBIOS(bios)) {
				found = true;
			} else if (bios) {
				bios->close(bios);
				bios = NULL;
			}
		}
		if (found && bios) {
			GBALoadBIOS(gba, bios);
		}
	}
#endif

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

static uint32_t _GBACoreFrameCounter(const struct mCore* core) {
	const struct GBA* gba = core->board;
	return gba->video.frameCounter;
}

static int32_t _GBACoreFrameCycles(const struct mCore* core) {
	UNUSED(core);
	return VIDEO_TOTAL_LENGTH;
}

static int32_t _GBACoreFrequency(const struct mCore* core) {
	UNUSED(core);
	return GBA_ARM7TDMI_FREQUENCY;
}

static void _GBACoreGetGameInfo(const struct mCore* core, struct mGameInfo* info) {
	GBAGetGameInfo(core->board, info);
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
	GBAPatch8(cpu, address, value, NULL);
}

static void _GBACoreRawWrite16(struct mCore* core, uint32_t address, int segment, uint16_t value) {
	UNUSED(segment);
	struct ARMCore* cpu = core->cpu;
	GBAPatch16(cpu, address, value, NULL);
}

static void _GBACoreRawWrite32(struct mCore* core, uint32_t address, int segment, uint32_t value) {
	UNUSED(segment);
	struct ARMCore* cpu = core->cpu;
	GBAPatch32(cpu, address, value, NULL);
}

size_t _GBACoreListMemoryBlocks(const struct mCore* core, const struct mCoreMemoryBlock** blocks) {
	const struct GBA* gba = core->board;
	struct GBACore* gbacore = (struct GBACore*) core;

	if (gbacore->memoryBlockType != gba->memory.savedata.type) {
		switch (gba->memory.savedata.type) {
		case GBA_SAVEDATA_SRAM:
			memcpy(gbacore->memoryBlocks, _GBAMemoryBlocksSRAM, sizeof(_GBAMemoryBlocksSRAM));
			gbacore->nMemoryBlocks = sizeof(_GBAMemoryBlocksSRAM) / sizeof(*_GBAMemoryBlocksSRAM);
			break;
		case GBA_SAVEDATA_SRAM512:
			memcpy(gbacore->memoryBlocks, _GBAMemoryBlocksSRAM512, sizeof(_GBAMemoryBlocksSRAM512));
			gbacore->nMemoryBlocks = sizeof(_GBAMemoryBlocksSRAM512) / sizeof(*_GBAMemoryBlocksSRAM512);
			break;
		case GBA_SAVEDATA_FLASH512:
			memcpy(gbacore->memoryBlocks, _GBAMemoryBlocksFlash512, sizeof(_GBAMemoryBlocksFlash512));
			gbacore->nMemoryBlocks = sizeof(_GBAMemoryBlocksFlash512) / sizeof(*_GBAMemoryBlocksFlash512);
			break;
		case GBA_SAVEDATA_FLASH1M:
			memcpy(gbacore->memoryBlocks, _GBAMemoryBlocksFlash1M, sizeof(_GBAMemoryBlocksFlash1M));
			gbacore->nMemoryBlocks = sizeof(_GBAMemoryBlocksFlash1M) / sizeof(*_GBAMemoryBlocksFlash1M);
			break;
		case GBA_SAVEDATA_EEPROM:
			memcpy(gbacore->memoryBlocks, _GBAMemoryBlocksEEPROM, sizeof(_GBAMemoryBlocksEEPROM));
			gbacore->nMemoryBlocks = sizeof(_GBAMemoryBlocksEEPROM) / sizeof(*_GBAMemoryBlocksEEPROM);
			break;
		case GBA_SAVEDATA_EEPROM512:
			memcpy(gbacore->memoryBlocks, _GBAMemoryBlocksEEPROM512, sizeof(_GBAMemoryBlocksEEPROM512));
			gbacore->nMemoryBlocks = sizeof(_GBAMemoryBlocksEEPROM512) / sizeof(*_GBAMemoryBlocksEEPROM512);
			break;
		default:
			memcpy(gbacore->memoryBlocks, _GBAMemoryBlocks, sizeof(_GBAMemoryBlocks));
			gbacore->nMemoryBlocks = sizeof(_GBAMemoryBlocks) / sizeof(*_GBAMemoryBlocks);
			break;
		}

		size_t i;
		for (i = 0; i < gbacore->nMemoryBlocks; ++i) {
			if (gbacore->memoryBlocks[i].id == GBA_REGION_ROM0 || gbacore->memoryBlocks[i].id == GBA_REGION_ROM1 || gbacore->memoryBlocks[i].id == GBA_REGION_ROM2) {
				gbacore->memoryBlocks[i].size = gba->memory.romSize;
			}
		}
		gbacore->memoryBlockType = gba->memory.savedata.type;

		mCALLBACKS_INVOKE(gba, memoryBlocksChanged);
	}

	*blocks = gbacore->memoryBlocks;
	return gbacore->nMemoryBlocks;
}

void* _GBACoreGetMemoryBlock(struct mCore* core, size_t id, size_t* sizeOut) {
	struct GBA* gba = core->board;
	switch (id) {
	default:
		return NULL;
	case GBA_REGION_BIOS:
		*sizeOut = GBA_SIZE_BIOS;
		return gba->memory.bios;
	case GBA_REGION_EWRAM:
		*sizeOut = GBA_SIZE_EWRAM;
		return gba->memory.wram;
	case GBA_REGION_IWRAM:
		*sizeOut = GBA_SIZE_IWRAM;
		return gba->memory.iwram;
	case GBA_REGION_PALETTE_RAM:
		*sizeOut = GBA_SIZE_PALETTE_RAM;
		return gba->video.palette;
	case GBA_REGION_VRAM:
		*sizeOut = GBA_SIZE_VRAM;
		return gba->video.vram;
	case GBA_REGION_OAM:
		*sizeOut = GBA_SIZE_OAM;
		return gba->video.oam.raw;
	case GBA_REGION_ROM0:
	case GBA_REGION_ROM1:
	case GBA_REGION_ROM2:
		*sizeOut = gba->memory.romSize;
		return gba->memory.rom;
	case GBA_REGION_SRAM:
		if (gba->memory.savedata.type == GBA_SAVEDATA_FLASH1M) {
			*sizeOut = GBA_SIZE_FLASH1M;
			return gba->memory.savedata.currentBank;
		}
		// Fall through
	case GBA_REGION_SRAM_MIRROR:
		*sizeOut = GBASavedataSize(&gba->memory.savedata);
		return gba->memory.savedata.data;
	}
}

static size_t _GBACoreListRegisters(const struct mCore* core, const struct mCoreRegisterInfo** list) {
	UNUSED(core);
	*list = _GBARegisters;
	return sizeof(_GBARegisters) / sizeof(*_GBARegisters);
}

static bool _GBACoreReadRegister(const struct mCore* core, const char* name, void* out) {
	struct ARMCore* cpu = core->cpu;
	int32_t* value = out;
	switch (name[0]) {
	case 'r':
	case 'R':
		++name;
		break;
	case 'c':
	case 'C':
		if (strcmp(name, "cpsr") == 0 || strcmp(name, "CPSR") == 0) {
			*value = cpu->cpsr.packed;
			_ARMReadCPSR(cpu);
			return true;
		}
		return false;
	case 'i':
	case 'I':
		if (strcmp(name, "ip") == 0 || strcmp(name, "IP") == 0) {
			*value = cpu->gprs[12];
			return true;
		}
		return false;
	case 's':
	case 'S':
		if (strcmp(name, "sp") == 0 || strcmp(name, "SP") == 0) {
			*value = cpu->gprs[ARM_SP];
			return true;
		}
		// TODO: SPSR
		return false;
	case 'l':
	case 'L':
		if (strcmp(name, "lr") == 0 || strcmp(name, "LR") == 0) {
			*value = cpu->gprs[ARM_LR];
			return true;
		}
		return false;
	case 'p':
	case 'P':
		if (strcmp(name, "pc") == 0 || strcmp(name, "PC") == 0) {
			*value = cpu->gprs[ARM_PC];
			return true;
		}
		return false;
	default:
		return false;
	}

	char* parseEnd;
	errno = 0;
	unsigned long regId = strtoul(name, &parseEnd, 10);
	if (errno || regId > 15 || *parseEnd) {
		return false;
	}
	*value = cpu->gprs[regId];
	return true;
}

static bool _GBACoreWriteRegister(struct mCore* core, const char* name, const void* in) {
	struct ARMCore* cpu = core->cpu;
	int32_t value = *(const int32_t*) in;
	switch (name[0]) {
	case 'r':
	case 'R':
		++name;
		break;
	case 'c':
	case 'C':
		if (strcmp(name, "cpsr") == 0) {
			uint32_t pc = cpu->gprs[ARM_PC] & -WORD_SIZE_THUMB;
			enum ExecutionMode mode = cpu->cpsr.t;
			cpu->cpsr.packed = value & 0xF00000FF;
			_ARMReadCPSR(cpu);
			if (mode != cpu->cpsr.t) {
				// Mode changed, flush the prefetch
				if (cpu->cpsr.t == MODE_ARM) {
					pc &= -WORD_SIZE_ARM;
					LOAD_32(cpu->prefetch[0], (pc - WORD_SIZE_ARM) & cpu->memory.activeMask, cpu->memory.activeRegion);
					LOAD_32(cpu->prefetch[1], pc & cpu->memory.activeMask, cpu->memory.activeRegion);
				} else {
					LOAD_16(cpu->prefetch[0], (pc - WORD_SIZE_THUMB) & cpu->memory.activeMask, cpu->memory.activeRegion);
					LOAD_16(cpu->prefetch[1], pc & cpu->memory.activeMask, cpu->memory.activeRegion);
				}
			}
			return true;
		}
		return false;
	case 'i':
	case 'I':
		if (strcmp(name, "ip") == 0 || strcmp(name, "IP") == 0) {
			cpu->gprs[12] = value;
			return true;
		}
		return false;
	case 's':
	case 'S':
		if (strcmp(name, "sp") == 0 || strcmp(name, "SP") == 0) {
			cpu->gprs[ARM_SP] = value;
			return true;
		}
		// TODO: SPSR
		return false;
	case 'l':
	case 'L':
		if (strcmp(name, "lr") == 0 || strcmp(name, "LR") == 0) {
			cpu->gprs[ARM_LR] = value;
			return true;
		}
		return false;
	case 'p':
	case 'P':
		if (strcmp(name, "pc") == 0 || strcmp(name, "PC") == 0) {
			name = "15";
			break;
		}
		return false;
	default:
		return false;
	}

	char* parseEnd;
	errno = 0;
	unsigned long regId = strtoul(name, &parseEnd, 10);
	if (errno || regId > 15 || *parseEnd) {
		return false;
	}
	cpu->gprs[regId] = value;
	if (regId == ARM_PC) {
		if (cpu->cpsr.t) {
			ThumbWritePC(cpu);
		} else {
			ARMWritePC(cpu);
		}
	}
	return true;
}

#ifdef ENABLE_DEBUGGERS
static bool _GBACoreSupportsDebuggerType(struct mCore* core, enum mDebuggerType type) {
	UNUSED(core);
	switch (type) {
	case DEBUGGER_CUSTOM:
	case DEBUGGER_CLI:
	case DEBUGGER_GDB:
		return true;
	default:
		return false;
	}
}

static struct mDebuggerPlatform* _GBACoreDebuggerPlatform(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;
	if (!gbacore->debuggerPlatform) {
		gbacore->debuggerPlatform = ARMDebuggerPlatformCreate();
	}
	return gbacore->debuggerPlatform;
}

static struct CLIDebuggerSystem* _GBACoreCliDebuggerSystem(struct mCore* core) {
	return &GBACLIDebuggerCreate(core)->d;
}

static void _GBACoreAttachDebugger(struct mCore* core, struct mDebugger* debugger) {
	if (core->debugger == debugger) {
		return;
	}
	if (core->debugger) {
		GBADetachDebugger(core->board);
	}
	GBAAttachDebugger(core->board, debugger);
	core->debugger = debugger;
}

static void _GBACoreDetachDebugger(struct mCore* core) {
	GBADetachDebugger(core->board);
	core->debugger = NULL;
}

static void _GBACoreLoadSymbols(struct mCore* core, struct VFile* vf) {
	struct GBA* gba = core->board;
	bool closeAfter = false;
	if (!core->symbolTable) {
		core->symbolTable = mDebuggerSymbolTableCreate();
	}
	off_t seek;
	if (vf) {
		seek = vf->seek(vf, 0, SEEK_CUR);
		vf->seek(vf, 0, SEEK_SET);
	}
#if defined(ENABLE_VFS) && defined(ENABLE_DIRECTORIES)
#ifdef USE_ELF
	if (!vf && core->dirs.base) {
		closeAfter = true;
		vf = mDirectorySetOpenSuffix(&core->dirs, core->dirs.base, ".elf", O_RDONLY);
	}
#endif
	if (!vf && core->dirs.base) {
		vf = mDirectorySetOpenSuffix(&core->dirs, core->dirs.base, ".sym", O_RDONLY);
		if (vf) {
			mDebuggerLoadARMIPSSymbols(core->symbolTable, vf);
			vf->close(vf);
			return;
		}
	}
#endif
	if (!vf && gba->mbVf) {
		closeAfter = false;
		vf = gba->mbVf;
		seek = vf->seek(vf, 0, SEEK_CUR);
		vf->seek(vf, 0, SEEK_SET);
	}
	if (!vf && gba->romVf) {
		closeAfter = false;
		vf = gba->romVf;
		seek = vf->seek(vf, 0, SEEK_CUR);
		vf->seek(vf, 0, SEEK_SET);
	}
	if (!vf) {
		return;
	}
#ifdef USE_ELF
	struct ELF* elf = ELFOpen(vf);
	if (elf) {
#ifdef ENABLE_DEBUGGERS
		mCoreLoadELFSymbols(core->symbolTable, elf);
#endif
		ELFClose(elf);
	}
#endif
	if (closeAfter) {
		vf->close(vf);
	} else {
		vf->seek(vf, seek, SEEK_SET);
	}
}

static bool _GBACoreLookupIdentifier(struct mCore* core, const char* name, int32_t* value, int* segment) {
	UNUSED(core);
	*segment = -1;
	int i;
	for (i = 0; i < GBA_REG_MAX; i += 2) {
		const char* reg = GBAIORegisterNames[i >> 1];
		if (reg && strcasecmp(reg, name) == 0) {
			*value = GBA_BASE_IO | i;
			return true;
		}
	}
	return false;
}
#endif

static struct mCheatDevice* _GBACoreCheatDevice(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;
	if (!gbacore->cheatDevice) {
		gbacore->cheatDevice = GBACheatDeviceCreate();
		((struct ARMCore*) core->cpu)->components[CPU_COMPONENT_CHEAT_DEVICE] = &gbacore->cheatDevice->d;
		ARMHotplugAttach(core->cpu, CPU_COMPONENT_CHEAT_DEVICE);
		gbacore->cheatDevice->p = core;
	}
	return gbacore->cheatDevice;
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
#ifdef BUILD_GLES3
		gbacore->glRenderer.bg[id].offsetX = x;
		gbacore->glRenderer.bg[id].offsetY = y;
#endif
		break;
	case GBA_LAYER_OBJ:
		gbacore->renderer.objOffsetX = x;
		gbacore->renderer.objOffsetY = y;
		gbacore->renderer.oamDirty = 1;
#ifdef BUILD_GLES3
		gbacore->glRenderer.objOffsetX = x;
		gbacore->glRenderer.objOffsetY = y;
		gbacore->glRenderer.oamDirty = 1;
#endif
		break;
	case GBA_LAYER_WIN0:
	case GBA_LAYER_WIN1:
		gbacore->renderer.winN[id - GBA_LAYER_WIN0].offsetX = x;
		gbacore->renderer.winN[id - GBA_LAYER_WIN0].offsetY = y;
#ifdef BUILD_GLES3
		gbacore->glRenderer.winN[id - GBA_LAYER_WIN0].offsetX = x;
		gbacore->glRenderer.winN[id - GBA_LAYER_WIN0].offsetY = y;
#endif
		break;
	default:
		return;
	}
	memset(gbacore->renderer.scanlineDirty, 0xFFFFFFFF, sizeof(gbacore->renderer.scanlineDirty));
}

#ifndef MINIMAL_CORE
static void _GBACoreStartVideoLog(struct mCore* core, struct mVideoLogContext* context) {
	struct GBACore* gbacore = (struct GBACore*) core;
	struct GBA* gba = core->board;
	gbacore->logContext = context;

	struct GBASerializedState* state = mVideoLogContextInitialState(context, NULL);
	state->id = 0;
	state->cpu.gprs[ARM_PC] = GBA_BASE_EWRAM;

	int channelId = mVideoLoggerAddChannel(context);
	struct mVideoLogger* logger = malloc(sizeof(*logger));
	mVideoLoggerRendererCreate(logger, false);
	mVideoLoggerAttachChannel(logger, context, channelId);
	logger->block = false;

	GBAVideoProxyRendererCreate(&gbacore->vlProxy, gba->video.renderer, logger);
	GBAVideoProxyRendererShim(&gba->video, &gbacore->vlProxy);
}

static void _GBACoreEndVideoLog(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;
	struct GBA* gba = core->board;
	if (gbacore->vlProxy.logger) {
		GBAVideoProxyRendererUnshim(&gba->video, &gbacore->vlProxy);
		free(gbacore->vlProxy.logger);
		gbacore->vlProxy.logger = NULL;
	}
}
#endif

struct mCore* GBACoreCreate(void) {
	struct GBACore* gbacore = malloc(sizeof(*gbacore));
	struct mCore* core = &gbacore->d;
	memset(&core->opts, 0, sizeof(core->opts));
	core->cpu = NULL;
	core->board = NULL;
	core->debugger = NULL;
	core->init = _GBACoreInit;
	core->deinit = _GBACoreDeinit;
	core->platform = _GBACorePlatform;
	core->supportsFeature = _GBACoreSupportsFeature;
	core->setSync = _GBACoreSetSync;
	core->loadConfig = _GBACoreLoadConfig;
	core->reloadConfigOption = _GBACoreReloadConfigOption;
	core->setOverride = _GBACoreSetOverride;
	core->baseVideoSize = _GBACoreBaseVideoSize;
	core->currentVideoSize = _GBACoreCurrentVideoSize;
	core->videoScale = _GBACoreVideoScale;
	core->screenRegions = _GBACoreScreenRegions;
	core->setVideoBuffer = _GBACoreSetVideoBuffer;
	core->setVideoGLTex = _GBACoreSetVideoGLTex;
	core->getPixels = _GBACoreGetPixels;
	core->putPixels = _GBACorePutPixels;
	core->audioSampleRate = _GBACoreAudioSampleRate;
	core->getAudioBuffer = _GBACoreGetAudioBuffer;
	core->setAudioBufferSize = _GBACoreSetAudioBufferSize;
	core->getAudioBufferSize = _GBACoreGetAudioBufferSize;
	core->addCoreCallbacks = _GBACoreAddCoreCallbacks;
	core->clearCoreCallbacks = _GBACoreClearCoreCallbacks;
	core->setAVStream = _GBACoreSetAVStream;
	core->isROM = GBAIsROM;
	core->loadROM = _GBACoreLoadROM;
	core->loadBIOS = _GBACoreLoadBIOS;
	core->loadSave = _GBACoreLoadSave;
	core->loadTemporarySave = _GBACoreLoadTemporarySave;
	core->loadPatch = _GBACoreLoadPatch;
	core->unloadROM = _GBACoreUnloadROM;
	core->romSize = _GBACoreROMSize;
	core->checksum = _GBACoreChecksum;
	core->reset = _GBACoreReset;
	core->runFrame = _GBACoreRunFrame;
	core->runLoop = _GBACoreRunLoop;
	core->step = _GBACoreStep;
	core->stateSize = _GBACoreStateSize;
	core->loadState = _GBACoreLoadState;
	core->saveState = _GBACoreSaveState;
	core->loadExtraState = _GBACoreLoadExtraState;
	core->saveExtraState = _GBACoreSaveExtraState;
	core->setKeys = _GBACoreSetKeys;
	core->addKeys = _GBACoreAddKeys;
	core->clearKeys = _GBACoreClearKeys;
	core->getKeys = _GBACoreGetKeys;
	core->frameCounter = _GBACoreFrameCounter;
	core->frameCycles = _GBACoreFrameCycles;
	core->frequency = _GBACoreFrequency;
	core->getGameInfo = _GBACoreGetGameInfo;
	core->setPeripheral = _GBACoreSetPeripheral;
	core->getPeripheral = _GBACoreGetPeripheral;
	core->busRead8 = _GBACoreBusRead8;
	core->busRead16 = _GBACoreBusRead16;
	core->busRead32 = _GBACoreBusRead32;
	core->busWrite8 = _GBACoreBusWrite8;
	core->busWrite16 = _GBACoreBusWrite16;
	core->busWrite32 = _GBACoreBusWrite32;
	core->rawRead8 = _GBACoreRawRead8;
	core->rawRead16 = _GBACoreRawRead16;
	core->rawRead32 = _GBACoreRawRead32;
	core->rawWrite8 = _GBACoreRawWrite8;
	core->rawWrite16 = _GBACoreRawWrite16;
	core->rawWrite32 = _GBACoreRawWrite32;
	core->listMemoryBlocks = _GBACoreListMemoryBlocks;
	core->getMemoryBlock = _GBACoreGetMemoryBlock;
	core->listRegisters = _GBACoreListRegisters;
	core->readRegister = _GBACoreReadRegister;
	core->writeRegister = _GBACoreWriteRegister;
#ifdef ENABLE_DEBUGGERS
	core->supportsDebuggerType = _GBACoreSupportsDebuggerType;
	core->debuggerPlatform = _GBACoreDebuggerPlatform;
	core->cliDebuggerSystem = _GBACoreCliDebuggerSystem;
	core->attachDebugger = _GBACoreAttachDebugger;
	core->detachDebugger = _GBACoreDetachDebugger;
	core->loadSymbols = _GBACoreLoadSymbols;
	core->lookupIdentifier = _GBACoreLookupIdentifier;
#endif
	core->cheatDevice = _GBACoreCheatDevice;
	core->savedataClone = _GBACoreSavedataClone;
	core->savedataRestore = _GBACoreSavedataRestore;
	core->listVideoLayers = _GBACoreListVideoLayers;
	core->listAudioChannels = _GBACoreListAudioChannels;
	core->enableVideoLayer = _GBACoreEnableVideoLayer;
	core->enableAudioChannel = _GBACoreEnableAudioChannel;
	core->adjustVideoLayer = _GBACoreAdjustVideoLayer;
#ifndef MINIMAL_CORE
	core->startVideoLog = _GBACoreStartVideoLog;
	core->endVideoLog = _GBACoreEndVideoLog;
#endif
	return core;
}

#ifndef MINIMAL_CORE
static void _GBAVLPStartFrameCallback(void *context) {
	struct mCore* core = context;
	struct GBACore* gbacore = (struct GBACore*) core;
	struct GBA* gba = core->board;

	if (!mVideoLoggerRendererRun(gbacore->vlProxy.logger, true)) {
		GBAVideoProxyRendererUnshim(&gba->video, &gbacore->vlProxy);
		mVideoLogContextRewind(gbacore->logContext, core);
		GBAVideoProxyRendererShim(&gba->video, &gbacore->vlProxy);
		GBAInterrupt(gba);
	}
}

static bool _GBAVLPInit(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;
	if (!_GBACoreInit(core)) {
		return false;
	}
	struct mVideoLogger* logger = malloc(sizeof(*logger));
	mVideoLoggerRendererCreate(logger, true);
	GBAVideoProxyRendererCreate(&gbacore->vlProxy, NULL, logger);
	memset(&gbacore->logCallbacks, 0, sizeof(gbacore->logCallbacks));
	gbacore->logCallbacks.videoFrameStarted = _GBAVLPStartFrameCallback;
	gbacore->logCallbacks.context = core;
	core->addCoreCallbacks(core, &gbacore->logCallbacks);
	core->videoLogger = gbacore->vlProxy.logger;
	return true;
}

static void _GBAVLPDeinit(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;
	if (gbacore->logContext) {
		mVideoLogContextDestroy(core, gbacore->logContext, true);
	}
	_GBACoreDeinit(core);
}

static void _GBAVLPReset(struct mCore* core) {
	struct GBACore* gbacore = (struct GBACore*) core;
	struct GBA* gba = (struct GBA*) core->board;
	if (gba->video.renderer == &gbacore->vlProxy.d) {
		GBAVideoProxyRendererUnshim(&gba->video, &gbacore->vlProxy);
	} else if (gbacore->renderer.outputBuffer) {
		struct GBAVideoRenderer* renderer = &gbacore->renderer.d;
		GBAVideoAssociateRenderer(&gba->video, renderer);
	}

	ARMReset(core->cpu);
	mVideoLogContextRewind(gbacore->logContext, core);
	GBAVideoProxyRendererShim(&gba->video, &gbacore->vlProxy);

	// Make sure CPU loop never spins
	GBAHalt(gba);
	gba->cpu->memory.store16(gba->cpu, GBA_BASE_IO | GBA_REG_IME, 0, NULL);
	gba->cpu->memory.store16(gba->cpu, GBA_BASE_IO | GBA_REG_IE, 0, NULL);
}

static bool _GBAVLPLoadROM(struct mCore* core, struct VFile* vf) {
	struct GBACore* gbacore = (struct GBACore*) core;
	gbacore->logContext = mVideoLogContextCreate(NULL);
	if (!mVideoLogContextLoad(gbacore->logContext, vf)) {
		mVideoLogContextDestroy(core, gbacore->logContext, false);
		gbacore->logContext = NULL;
		return false;
	}
	mVideoLoggerAttachChannel(gbacore->vlProxy.logger, gbacore->logContext, 0);
	return true;
}

static bool _GBAVLPLoadState(struct mCore* core, const void* state) {
	struct GBA* gba = (struct GBA*) core->board;

	gba->timing.root = NULL;
	gba->cpu->gprs[ARM_PC] = GBA_BASE_EWRAM;
	gba->cpu->memory.setActiveRegion(gba->cpu, gba->cpu->gprs[ARM_PC]);

	// Make sure CPU loop never spins
	GBAHalt(gba);
	gba->cpu->memory.store16(gba->cpu, GBA_BASE_IO | GBA_REG_IME, 0, NULL);
	gba->cpu->memory.store16(gba->cpu, GBA_BASE_IO | GBA_REG_IE, 0, NULL);
	GBAVideoDeserialize(&gba->video, state);
	GBAIODeserialize(gba, state);
	GBAAudioReset(&gba->audio);

	return true;
}

static bool _returnTrue(struct VFile* vf) {
	UNUSED(vf);
	return true;
}

struct mCore* GBAVideoLogPlayerCreate(void) {
	struct mCore* core = GBACoreCreate();
	core->init = _GBAVLPInit;
	core->deinit = _GBAVLPDeinit;
	core->reset = _GBAVLPReset;
	core->loadROM = _GBAVLPLoadROM;
	core->loadState = _GBAVLPLoadState;
	core->isROM = _returnTrue;
	return core;
}
#else
struct mCore* GBAVideoLogPlayerCreate(void) {
	return false;
}
#endif

/* ===== Imported from reference implementation/io.c ===== */
const char* const GBAIORegisterNames[] = {
	// Video
	[GBA_REG(DISPCNT)] = "DISPCNT",
	[GBA_REG(DISPSTAT)] = "DISPSTAT",
	[GBA_REG(VCOUNT)] = "VCOUNT",
	[GBA_REG(BG0CNT)] = "BG0CNT",
	[GBA_REG(BG1CNT)] = "BG1CNT",
	[GBA_REG(BG2CNT)] = "BG2CNT",
	[GBA_REG(BG3CNT)] = "BG3CNT",
	[GBA_REG(BG0HOFS)] = "BG0HOFS",
	[GBA_REG(BG0VOFS)] = "BG0VOFS",
	[GBA_REG(BG1HOFS)] = "BG1HOFS",
	[GBA_REG(BG1VOFS)] = "BG1VOFS",
	[GBA_REG(BG2HOFS)] = "BG2HOFS",
	[GBA_REG(BG2VOFS)] = "BG2VOFS",
	[GBA_REG(BG3HOFS)] = "BG3HOFS",
	[GBA_REG(BG3VOFS)] = "BG3VOFS",
	[GBA_REG(BG2PA)] = "BG2PA",
	[GBA_REG(BG2PB)] = "BG2PB",
	[GBA_REG(BG2PC)] = "BG2PC",
	[GBA_REG(BG2PD)] = "BG2PD",
	[GBA_REG(BG2X_LO)] = "BG2X_LO",
	[GBA_REG(BG2X_HI)] = "BG2X_HI",
	[GBA_REG(BG2Y_LO)] = "BG2Y_LO",
	[GBA_REG(BG2Y_HI)] = "BG2Y_HI",
	[GBA_REG(BG3PA)] = "BG3PA",
	[GBA_REG(BG3PB)] = "BG3PB",
	[GBA_REG(BG3PC)] = "BG3PC",
	[GBA_REG(BG3PD)] = "BG3PD",
	[GBA_REG(BG3X_LO)] = "BG3X_LO",
	[GBA_REG(BG3X_HI)] = "BG3X_HI",
	[GBA_REG(BG3Y_LO)] = "BG3Y_LO",
	[GBA_REG(BG3Y_HI)] = "BG3Y_HI",
	[GBA_REG(WIN0H)] = "WIN0H",
	[GBA_REG(WIN1H)] = "WIN1H",
	[GBA_REG(WIN0V)] = "WIN0V",
	[GBA_REG(WIN1V)] = "WIN1V",
	[GBA_REG(WININ)] = "WININ",
	[GBA_REG(WINOUT)] = "WINOUT",
	[GBA_REG(MOSAIC)] = "MOSAIC",
	[GBA_REG(BLDCNT)] = "BLDCNT",
	[GBA_REG(BLDALPHA)] = "BLDALPHA",
	[GBA_REG(BLDY)] = "BLDY",

	// Sound
	[GBA_REG(SOUND1CNT_LO)] = "SOUND1CNT_LO",
	[GBA_REG(SOUND1CNT_HI)] = "SOUND1CNT_HI",
	[GBA_REG(SOUND1CNT_X)] = "SOUND1CNT_X",
	[GBA_REG(SOUND2CNT_LO)] = "SOUND2CNT_LO",
	[GBA_REG(SOUND2CNT_HI)] = "SOUND2CNT_HI",
	[GBA_REG(SOUND3CNT_LO)] = "SOUND3CNT_LO",
	[GBA_REG(SOUND3CNT_HI)] = "SOUND3CNT_HI",
	[GBA_REG(SOUND3CNT_X)] = "SOUND3CNT_X",
	[GBA_REG(SOUND4CNT_LO)] = "SOUND4CNT_LO",
	[GBA_REG(SOUND4CNT_HI)] = "SOUND4CNT_HI",
	[GBA_REG(SOUNDCNT_LO)] = "SOUNDCNT_LO",
	[GBA_REG(SOUNDCNT_HI)] = "SOUNDCNT_HI",
	[GBA_REG(SOUNDCNT_X)] = "SOUNDCNT_X",
	[GBA_REG(SOUNDBIAS)] = "SOUNDBIAS",
	[GBA_REG(WAVE_RAM0_LO)] = "WAVE_RAM0_LO",
	[GBA_REG(WAVE_RAM0_HI)] = "WAVE_RAM0_HI",
	[GBA_REG(WAVE_RAM1_LO)] = "WAVE_RAM1_LO",
	[GBA_REG(WAVE_RAM1_HI)] = "WAVE_RAM1_HI",
	[GBA_REG(WAVE_RAM2_LO)] = "WAVE_RAM2_LO",
	[GBA_REG(WAVE_RAM2_HI)] = "WAVE_RAM2_HI",
	[GBA_REG(WAVE_RAM3_LO)] = "WAVE_RAM3_LO",
	[GBA_REG(WAVE_RAM3_HI)] = "WAVE_RAM3_HI",
	[GBA_REG(FIFO_A_LO)] = "FIFO_A_LO",
	[GBA_REG(FIFO_A_HI)] = "FIFO_A_HI",
	[GBA_REG(FIFO_B_LO)] = "FIFO_B_LO",
	[GBA_REG(FIFO_B_HI)] = "FIFO_B_HI",

	// DMA
	[GBA_REG(DMA0SAD_LO)] = "DMA0SAD_LO",
	[GBA_REG(DMA0SAD_HI)] = "DMA0SAD_HI",
	[GBA_REG(DMA0DAD_LO)] = "DMA0DAD_LO",
	[GBA_REG(DMA0DAD_HI)] = "DMA0DAD_HI",
	[GBA_REG(DMA0CNT_LO)] = "DMA0CNT_LO",
	[GBA_REG(DMA0CNT_HI)] = "DMA0CNT_HI",
	[GBA_REG(DMA1SAD_LO)] = "DMA1SAD_LO",
	[GBA_REG(DMA1SAD_HI)] = "DMA1SAD_HI",
	[GBA_REG(DMA1DAD_LO)] = "DMA1DAD_LO",
	[GBA_REG(DMA1DAD_HI)] = "DMA1DAD_HI",
	[GBA_REG(DMA1CNT_LO)] = "DMA1CNT_LO",
	[GBA_REG(DMA1CNT_HI)] = "DMA1CNT_HI",
	[GBA_REG(DMA2SAD_LO)] = "DMA2SAD_LO",
	[GBA_REG(DMA2SAD_HI)] = "DMA2SAD_HI",
	[GBA_REG(DMA2DAD_LO)] = "DMA2DAD_LO",
	[GBA_REG(DMA2DAD_HI)] = "DMA2DAD_HI",
	[GBA_REG(DMA2CNT_LO)] = "DMA2CNT_LO",
	[GBA_REG(DMA2CNT_HI)] = "DMA2CNT_HI",
	[GBA_REG(DMA3SAD_LO)] = "DMA3SAD_LO",
	[GBA_REG(DMA3SAD_HI)] = "DMA3SAD_HI",
	[GBA_REG(DMA3DAD_LO)] = "DMA3DAD_LO",
	[GBA_REG(DMA3DAD_HI)] = "DMA3DAD_HI",
	[GBA_REG(DMA3CNT_LO)] = "DMA3CNT_LO",
	[GBA_REG(DMA3CNT_HI)] = "DMA3CNT_HI",

	// Timers
	[GBA_REG(TM0CNT_LO)] = "TM0CNT_LO",
	[GBA_REG(TM0CNT_HI)] = "TM0CNT_HI",
	[GBA_REG(TM1CNT_LO)] = "TM1CNT_LO",
	[GBA_REG(TM1CNT_HI)] = "TM1CNT_HI",
	[GBA_REG(TM2CNT_LO)] = "TM2CNT_LO",
	[GBA_REG(TM2CNT_HI)] = "TM2CNT_HI",
	[GBA_REG(TM3CNT_LO)] = "TM3CNT_LO",
	[GBA_REG(TM3CNT_HI)] = "TM3CNT_HI",

	// SIO
	[GBA_REG(SIOMULTI0)] = "SIOMULTI0",
	[GBA_REG(SIOMULTI1)] = "SIOMULTI1",
	[GBA_REG(SIOMULTI2)] = "SIOMULTI2",
	[GBA_REG(SIOMULTI3)] = "SIOMULTI3",
	[GBA_REG(SIOCNT)] = "SIOCNT",
	[GBA_REG(SIOMLT_SEND)] = "SIOMLT_SEND",
	[GBA_REG(KEYINPUT)] = "KEYINPUT",
	[GBA_REG(KEYCNT)] = "KEYCNT",
	[GBA_REG(RCNT)] = "RCNT",
	[GBA_REG(JOYCNT)] = "JOYCNT",
	[GBA_REG(JOY_RECV_LO)] = "JOY_RECV_LO",
	[GBA_REG(JOY_RECV_HI)] = "JOY_RECV_HI",
	[GBA_REG(JOY_TRANS_LO)] = "JOY_TRANS_LO",
	[GBA_REG(JOY_TRANS_HI)] = "JOY_TRANS_HI",
	[GBA_REG(JOYSTAT)] = "JOYSTAT",

	// Interrupts, etc
	[GBA_REG(IE)] = "IE",
	[GBA_REG(IF)] = "IF",
	[GBA_REG(WAITCNT)] = "WAITCNT",
	[GBA_REG(IME)] = "IME",
};

static const int _isValidRegister[GBA_REG(INTERNAL_MAX)] = {
	/*      0  2  4  6  8  A  C  E */
	/*    Video */
	/* 00 */ 1, 0, 1, 1, 1, 1, 1, 1,
	/* 01 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 02 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 03 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 04 */ 1, 1, 1, 1, 1, 1, 1, 0,
	/* 05 */ 1, 1, 1, 0, 0, 0, 0, 0,
	/*    Audio */
	/* 06 */ 1, 1, 1, 0, 1, 0, 1, 0,
	/* 07 */ 1, 1, 1, 0, 1, 0, 1, 0,
	/* 08 */ 1, 1, 1, 0, 1, 0, 0, 0,
	/* 09 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0A */ 1, 1, 1, 1, 0, 0, 0, 0,
	/*    DMA */
	/* 0B */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0C */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0D */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0E */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 0F */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*   Timers */
	/* 10 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 11 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    SIO */
	/* 12 */ 1, 1, 1, 1, 1, 0, 0, 0,
	/* 13 */ 1, 1, 1, 0, 0, 0, 0, 0,
	/* 14 */ 1, 0, 0, 0, 0, 0, 0, 0,
	/* 15 */ 1, 1, 1, 1, 1, 0, 0, 0,
	/* 16 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 17 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 18 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 19 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1A */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1B */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1C */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1D */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1E */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1F */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    Interrupts */
	/* 20 */ 1, 1, 1, 0, 1, 0, 0, 0,
	// Internal registers
	1, 1
};

static const int _isRSpecialRegister[GBA_REG(INTERNAL_MAX)] = {
	/*      0  2  4  6  8  A  C  E */
	/*    Video */
	/* 00 */ 0, 0, 1, 1, 0, 0, 0, 0,
	/* 01 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 02 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 03 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 04 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 05 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/*    Audio */
	/* 06 */ 0, 0, 1, 0, 0, 0, 1, 0,
	/* 07 */ 0, 0, 1, 0, 0, 0, 1, 0,
	/* 08 */ 0, 0, 0, 0, 1, 0, 0, 0,
	/* 09 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0A */ 1, 1, 1, 1, 0, 0, 0, 0,
	/*    DMA */
	/* 0B */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0C */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0D */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0E */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 0F */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    Timers */
	/* 10 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 11 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    SIO */
	/* 12 */ 1, 1, 1, 1, 0, 0, 0, 0,
	/* 13 */ 1, 1, 0, 0, 0, 0, 0, 0,
	/* 14 */ 1, 0, 0, 0, 0, 0, 0, 0,
	/* 15 */ 1, 1, 1, 1, 1, 0, 0, 0,
	/* 16 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 17 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 18 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 19 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1A */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1B */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1C */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1D */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1E */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1F */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    Interrupts */
	/* 20 */ 0, 0, 0, 0, 0, 0, 0, 0,
	// Internal registers
	1, 1
};

static const int _isWSpecialRegister[GBA_REG(INTERNAL_MAX)] = {
	/*      0  2  4  6  8  A  C  E */
	/*    Video */
	/* 00 */ 0, 0, 1, 1, 0, 0, 0, 0,
	/* 01 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 02 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 03 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 04 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 05 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    Audio */
	/* 06 */ 0, 0, 1, 0, 0, 0, 1, 0,
	/* 07 */ 0, 0, 1, 0, 0, 0, 1, 0,
	/* 08 */ 0, 0, 1, 0, 0, 0, 0, 0,
	/* 09 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 0A */ 1, 1, 1, 1, 0, 0, 0, 0,
	/*    DMA */
	/* 0B */ 0, 0, 0, 0, 0, 1, 0, 0,
	/* 0C */ 0, 0, 0, 1, 0, 0, 0, 0,
	/* 0D */ 0, 1, 0, 0, 0, 0, 0, 1,
	/* 0E */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 0F */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    Timers */
	/* 10 */ 1, 1, 1, 1, 1, 1, 1, 1,
	/* 11 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    SIO */
	/* 12 */ 1, 1, 1, 1, 1, 0, 0, 0,
	/* 13 */ 1, 1, 1, 0, 0, 0, 0, 0,
	/* 14 */ 1, 0, 0, 0, 0, 0, 0, 0,
	/* 15 */ 1, 1, 1, 1, 1, 0, 0, 0,
	/* 16 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 17 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 18 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 19 */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1A */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1B */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1C */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1D */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1E */ 0, 0, 0, 0, 0, 0, 0, 0,
	/* 1F */ 0, 0, 0, 0, 0, 0, 0, 0,
	/*    Interrupts */
	/* 20 */ 1, 1, 0, 0, 1, 0, 0, 0,
	// Internal registers
	1, 1
};

void GBAIOInit(struct GBA* gba) {
	gba->memory.io[GBA_REG(DISPCNT)] = 0x0080;
	gba->memory.io[GBA_REG(RCNT)] = RCNT_INITIAL;
	gba->memory.io[GBA_REG(KEYINPUT)] = 0x3FF;
	gba->memory.io[GBA_REG(SOUNDBIAS)] = 0x200;
	gba->memory.io[GBA_REG(BG2PA)] = 0x100;
	gba->memory.io[GBA_REG(BG2PD)] = 0x100;
	gba->memory.io[GBA_REG(BG3PA)] = 0x100;
	gba->memory.io[GBA_REG(BG3PD)] = 0x100;
	gba->memory.io[GBA_REG(INTERNAL_EXWAITCNT_LO)] = 0x20;
	gba->memory.io[GBA_REG(INTERNAL_EXWAITCNT_HI)] = 0xD00;

	if (!gba->biosVf) {
		gba->memory.io[GBA_REG(VCOUNT)] = 0x7E;
		gba->memory.io[GBA_REG(POSTFLG)] = 1;
	}
}

void GBAIOWrite(struct GBA* gba, uint32_t address, uint16_t value) {
	if (address < GBA_REG_SOUND1CNT_LO && (address > GBA_REG_VCOUNT || address < GBA_REG_DISPSTAT)) {
		gba->memory.io[address >> 1] = gba->video.renderer->writeVideoRegister(gba->video.renderer, address, value);
		return;
	}

	if (address >= GBA_REG_SOUND1CNT_LO && address <= GBA_REG_SOUNDCNT_LO && !gba->audio.enable) {
		// Ignore writes to most audio registers if the hardware is off.
		return;
	}

	switch (address) {
	// Video
	case GBA_REG_DISPSTAT:
		value = GBAVideoWriteDISPSTAT(&gba->video, value);
		break;

	case GBA_REG_VCOUNT:
		mLOG(GBA_IO, GAME_ERROR, "Write to read-only I/O register: %03X", address);
		return;

	// Audio
	case GBA_REG_SOUND1CNT_LO:
		GBAAudioWriteSOUND1CNT_LO(&gba->audio, value);
		value &= 0x007F;
		break;
	case GBA_REG_SOUND1CNT_HI:
		GBAAudioWriteSOUND1CNT_HI(&gba->audio, value);
		value &= 0xFFC0;
		break;
	case GBA_REG_SOUND1CNT_X:
		GBAAudioWriteSOUND1CNT_X(&gba->audio, value);
		value &= 0x4000;
		break;
	case GBA_REG_SOUND2CNT_LO:
		GBAAudioWriteSOUND2CNT_LO(&gba->audio, value);
		value &= 0xFFC0;
		break;
	case GBA_REG_SOUND2CNT_HI:
		GBAAudioWriteSOUND2CNT_HI(&gba->audio, value);
		value &= 0x4000;
		break;
	case GBA_REG_SOUND3CNT_LO:
		GBAAudioWriteSOUND3CNT_LO(&gba->audio, value);
		value &= 0x00E0;
		break;
	case GBA_REG_SOUND3CNT_HI:
		GBAAudioWriteSOUND3CNT_HI(&gba->audio, value);
		value &= 0xE000;
		break;
	case GBA_REG_SOUND3CNT_X:
		GBAAudioWriteSOUND3CNT_X(&gba->audio, value);
		value &= 0x4000;
		break;
	case GBA_REG_SOUND4CNT_LO:
		GBAAudioWriteSOUND4CNT_LO(&gba->audio, value);
		value &= 0xFF00;
		break;
	case GBA_REG_SOUND4CNT_HI:
		GBAAudioWriteSOUND4CNT_HI(&gba->audio, value);
		value &= 0x40FF;
		break;
	case GBA_REG_SOUNDCNT_LO:
		GBAAudioWriteSOUNDCNT_LO(&gba->audio, value);
		value &= 0xFF77;
		break;
	case GBA_REG_SOUNDCNT_HI:
		GBAAudioWriteSOUNDCNT_HI(&gba->audio, value);
		value &= 0x770F;
		break;
	case GBA_REG_SOUNDCNT_X:
		GBAAudioWriteSOUNDCNT_X(&gba->audio, value);
		value &= 0x0080;
		value |= gba->memory.io[GBA_REG(SOUNDCNT_X)] & 0xF;
		break;
	case GBA_REG_SOUNDBIAS:
		value &= 0xC3FE;
		GBAAudioWriteSOUNDBIAS(&gba->audio, value);
		break;

	case GBA_REG_WAVE_RAM0_LO:
	case GBA_REG_WAVE_RAM1_LO:
	case GBA_REG_WAVE_RAM2_LO:
	case GBA_REG_WAVE_RAM3_LO:
		GBAIOWrite32(gba, address, (gba->memory.io[(address >> 1) + 1] << 16) | value);
		break;

	case GBA_REG_WAVE_RAM0_HI:
	case GBA_REG_WAVE_RAM1_HI:
	case GBA_REG_WAVE_RAM2_HI:
	case GBA_REG_WAVE_RAM3_HI:
		GBAIOWrite32(gba, address - 2, gba->memory.io[(address >> 1) - 1] | (value << 16));
		break;

	case GBA_REG_FIFO_A_LO:
	case GBA_REG_FIFO_B_LO:
		GBAIOWrite32(gba, address, (gba->memory.io[(address >> 1) + 1] << 16) | value);
		return;

	case GBA_REG_FIFO_A_HI:
	case GBA_REG_FIFO_B_HI:
		GBAIOWrite32(gba, address - 2, gba->memory.io[(address >> 1) - 1] | (value << 16));
		return;

	// DMA
	case GBA_REG_DMA0SAD_LO:
	case GBA_REG_DMA0DAD_LO:
	case GBA_REG_DMA1SAD_LO:
	case GBA_REG_DMA1DAD_LO:
	case GBA_REG_DMA2SAD_LO:
	case GBA_REG_DMA2DAD_LO:
	case GBA_REG_DMA3SAD_LO:
	case GBA_REG_DMA3DAD_LO:
		GBAIOWrite32(gba, address, (gba->memory.io[(address >> 1) + 1] << 16) | value);
		break;

	case GBA_REG_DMA0SAD_HI:
	case GBA_REG_DMA0DAD_HI:
	case GBA_REG_DMA1SAD_HI:
	case GBA_REG_DMA1DAD_HI:
	case GBA_REG_DMA2SAD_HI:
	case GBA_REG_DMA2DAD_HI:
	case GBA_REG_DMA3SAD_HI:
	case GBA_REG_DMA3DAD_HI:
		GBAIOWrite32(gba, address - 2, gba->memory.io[(address >> 1) - 1] | (value << 16));
		break;

	case GBA_REG_DMA0CNT_LO:
		GBADMAWriteCNT_LO(gba, 0, value & 0x3FFF);
		break;
	case GBA_REG_DMA0CNT_HI:
		value = GBADMAWriteCNT_HI(gba, 0, value);
		break;
	case GBA_REG_DMA1CNT_LO:
		GBADMAWriteCNT_LO(gba, 1, value & 0x3FFF);
		break;
	case GBA_REG_DMA1CNT_HI:
		value = GBADMAWriteCNT_HI(gba, 1, value);
		break;
	case GBA_REG_DMA2CNT_LO:
		GBADMAWriteCNT_LO(gba, 2, value & 0x3FFF);
		break;
	case GBA_REG_DMA2CNT_HI:
		value = GBADMAWriteCNT_HI(gba, 2, value);
		break;
	case GBA_REG_DMA3CNT_LO:
		GBADMAWriteCNT_LO(gba, 3, value);
		break;
	case GBA_REG_DMA3CNT_HI:
		value = GBADMAWriteCNT_HI(gba, 3, value);
		break;

	// Timers
	case GBA_REG_TM0CNT_LO:
		GBATimerWriteTMCNT_LO(gba, 0, value);
		return;
	case GBA_REG_TM1CNT_LO:
		GBATimerWriteTMCNT_LO(gba, 1, value);
		return;
	case GBA_REG_TM2CNT_LO:
		GBATimerWriteTMCNT_LO(gba, 2, value);
		return;
	case GBA_REG_TM3CNT_LO:
		GBATimerWriteTMCNT_LO(gba, 3, value);
		return;

	case GBA_REG_TM0CNT_HI:
		value &= 0x00C7;
		GBATimerWriteTMCNT_HI(gba, 0, value);
		break;
	case GBA_REG_TM1CNT_HI:
		value &= 0x00C7;
		GBATimerWriteTMCNT_HI(gba, 1, value);
		break;
	case GBA_REG_TM2CNT_HI:
		value &= 0x00C7;
		GBATimerWriteTMCNT_HI(gba, 2, value);
		break;
	case GBA_REG_TM3CNT_HI:
		value &= 0x00C7;
		GBATimerWriteTMCNT_HI(gba, 3, value);
		break;

	// SIO
	case GBA_REG_SIOCNT:
		value &= 0x7FFF;
		GBASIOWriteSIOCNT(&gba->sio, value);
		break;
	case GBA_REG_RCNT:
		value &= 0xC1FF;
		GBASIOWriteRCNT(&gba->sio, value);
		break;
	case GBA_REG_JOY_TRANS_LO:
	case GBA_REG_JOY_TRANS_HI:
		gba->memory.io[GBA_REG(JOYSTAT)] |= JOYSTAT_TRANS;
		// Fall through
	case GBA_REG_SIODATA32_LO:
	case GBA_REG_SIODATA32_HI:
	case GBA_REG_SIOMLT_SEND:
	case GBA_REG_JOYCNT:
	case GBA_REG_JOYSTAT:
	case GBA_REG_JOY_RECV_LO:
	case GBA_REG_JOY_RECV_HI:
		value = GBASIOWriteRegister(&gba->sio, address, value);
		break;

	// Interrupts and misc
	case GBA_REG_KEYCNT:
		value &= 0xC3FF;
		if (gba->keysLast < 0x400) {
			gba->keysLast &= gba->memory.io[address >> 1] | ~value;
		}
		gba->memory.io[address >> 1] = value;
		GBATestKeypadIRQ(gba);
		return;
	case GBA_REG_WAITCNT:
		value &= 0x5FFF;
		GBAAdjustWaitstates(gba, value);
		break;
	case GBA_REG_IE:
		gba->memory.io[GBA_REG(IE)] = value;
		GBATestIRQ(gba, 1);
		return;
	case GBA_REG_IF:
		value = gba->memory.io[GBA_REG(IF)] & ~value;
		gba->memory.io[GBA_REG(IF)] = value;
		GBATestIRQ(gba, 1);
		return;
	case GBA_REG_IME:
		gba->memory.io[GBA_REG(IME)] = value & 1;
		GBATestIRQ(gba, 1);
		return;
	case GBA_REG_MAX:
		// Some bad interrupt libraries will write to this
		break;
	case GBA_REG_POSTFLG:
		if (gba->memory.activeRegion == GBA_REGION_BIOS) {
			if (gba->memory.io[address >> 1]) {
				if (value & 0x8000) {
					GBAStop(gba);
				} else {
					GBAHalt(gba);
				}
			}
			value &= ~0x8000;
		} else {
			mLOG(GBA_IO, GAME_ERROR, "Write to BIOS-only I/O register: %03X", address);
			return;
		}
		break;
	case GBA_REG_EXWAITCNT_HI:
		// This register sits outside of the normal I/O block, so we need to stash it somewhere unused
		address = GBA_REG_INTERNAL_EXWAITCNT_HI;
		value &= 0xFF00;
		GBAAdjustEWRAMWaitstates(gba, value);
		break;
	case GBA_REG_DEBUG_ENABLE:
		gba->debug = value == 0xC0DE;
		return;
	case GBA_REG_DEBUG_FLAGS:
		if (gba->debug) {
			GBADebug(gba, value);

			return;
		}
		// Fall through
	default:
		if (address >= GBA_REG_DEBUG_STRING && address - GBA_REG_DEBUG_STRING < sizeof(gba->debugString)) {
			STORE_16LE(value, address - GBA_REG_DEBUG_STRING, gba->debugString);
			return;
		}
		mLOG(GBA_IO, STUB, "Stub I/O register write: %03X", address);
		if (address >= GBA_REG_MAX) {
			mLOG(GBA_IO, GAME_ERROR, "Write to unused I/O register: %03X", address);
			return;
		}
		break;
	}
	gba->memory.io[address >> 1] = value;
}

void GBAIOWrite8(struct GBA* gba, uint32_t address, uint8_t value) {
	if (address >= GBA_REG_DEBUG_STRING && address - GBA_REG_DEBUG_STRING < sizeof(gba->debugString)) {
		gba->debugString[address - GBA_REG_DEBUG_STRING] = value;
		return;
	}
	if (address > GBA_SIZE_IO) {
		return;
	}
	uint16_t value16;

	switch (address) {
	case GBA_REG_SOUND1CNT_HI:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR11(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND1CNT_HI)] &= 0xFF00;
		gba->memory.io[GBA_REG(SOUND1CNT_HI)] |= value & 0xC0;
		break;
	case GBA_REG_SOUND1CNT_HI + 1:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR12(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND1CNT_HI)] &= 0x00C0;
		gba->memory.io[GBA_REG(SOUND1CNT_HI)] |= value << 8;
		break;
	case GBA_REG_SOUND1CNT_X:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR13(&gba->audio.psg, value);
		break;
	case GBA_REG_SOUND1CNT_X + 1:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR14(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND1CNT_X)] = (value & 0x40) << 8;
		break;
	case GBA_REG_SOUND2CNT_LO:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR21(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND2CNT_LO)] &= 0xFF00;
		gba->memory.io[GBA_REG(SOUND2CNT_LO)] |= value & 0xC0;
		break;
	case GBA_REG_SOUND2CNT_LO + 1:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR22(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND2CNT_LO)] &= 0x00C0;
		gba->memory.io[GBA_REG(SOUND2CNT_LO)] |= value << 8;
		break;
	case GBA_REG_SOUND2CNT_HI:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR23(&gba->audio.psg, value);
		break;
	case GBA_REG_SOUND2CNT_HI + 1:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR24(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND2CNT_HI)] = (value & 0x40) << 8;
		break;
	case GBA_REG_SOUND3CNT_HI:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR31(&gba->audio.psg, value);
		break;
	case GBA_REG_SOUND3CNT_HI + 1:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		gba->audio.psg.ch3.volume = GBAudioRegisterBankVolumeGetVolumeGBA(value);
		gba->memory.io[GBA_REG(SOUND3CNT_HI)] = (value & 0xE0) << 8;
		break;
	case GBA_REG_SOUND3CNT_X:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR33(&gba->audio.psg, value);
		break;
	case GBA_REG_SOUND3CNT_X + 1:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR34(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND3CNT_X)] = (value & 0x40) << 8;
		break;
	case GBA_REG_SOUND4CNT_LO:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR41(&gba->audio.psg, value);
		break;
	case GBA_REG_SOUND4CNT_LO + 1:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR42(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND4CNT_LO)] = value << 8;
		break;
	case GBA_REG_SOUND4CNT_HI:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR43(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND4CNT_HI)] &= 0x4000;
		gba->memory.io[GBA_REG(SOUND4CNT_HI)] |= value;
		break;
	case GBA_REG_SOUND4CNT_HI + 1:
		GBAAudioSample(&gba->audio, mTimingCurrentTime(&gba->timing));
		GBAudioWriteNR44(&gba->audio.psg, value);
		gba->memory.io[GBA_REG(SOUND4CNT_HI)] &= 0x00FF;
		gba->memory.io[GBA_REG(SOUND4CNT_HI)] |= (value & 0x40) << 8;
		break;
	default:
		value16 = value << (8 * (address & 1));
		value16 |= (gba->memory.io[(address & (GBA_SIZE_IO - 1)) >> 1]) & ~(0xFF << (8 * (address & 1)));
		GBAIOWrite(gba, address & 0xFFFFFFFE, value16);
		break;
	}
}

void GBAIOWrite32(struct GBA* gba, uint32_t address, uint32_t value) {
	switch (address) {
	// Wave RAM can be written and read even if the audio hardware is disabled.
	// However, it is not possible to switch between the two banks because it
	// isn't possible to write to register SOUND3CNT_LO.
	case GBA_REG_WAVE_RAM0_LO:
		GBAAudioWriteWaveRAM(&gba->audio, 0, value);
		break;
	case GBA_REG_WAVE_RAM1_LO:
		GBAAudioWriteWaveRAM(&gba->audio, 1, value);
		break;
	case GBA_REG_WAVE_RAM2_LO:
		GBAAudioWriteWaveRAM(&gba->audio, 2, value);
		break;
	case GBA_REG_WAVE_RAM3_LO:
		GBAAudioWriteWaveRAM(&gba->audio, 3, value);
		break;
	case GBA_REG_FIFO_A_LO:
	case GBA_REG_FIFO_B_LO:
		value = GBAAudioWriteFIFO(&gba->audio, address, value);
		break;
	case GBA_REG_DMA0SAD_LO:
		value = GBADMAWriteSAD(gba, 0, value);
		break;
	case GBA_REG_DMA0DAD_LO:
		value = GBADMAWriteDAD(gba, 0, value);
		break;
	case GBA_REG_DMA1SAD_LO:
		value = GBADMAWriteSAD(gba, 1, value);
		break;
	case GBA_REG_DMA1DAD_LO:
		value = GBADMAWriteDAD(gba, 1, value);
		break;
	case GBA_REG_DMA2SAD_LO:
		value = GBADMAWriteSAD(gba, 2, value);
		break;
	case GBA_REG_DMA2DAD_LO:
		value = GBADMAWriteDAD(gba, 2, value);
		break;
	case GBA_REG_DMA3SAD_LO:
		value = GBADMAWriteSAD(gba, 3, value);
		break;
	case GBA_REG_DMA3DAD_LO:
		value = GBADMAWriteDAD(gba, 3, value);
		break;
	default:
		if (address >= GBA_REG_DEBUG_STRING && address - GBA_REG_DEBUG_STRING < sizeof(gba->debugString)) {
			STORE_32LE(value, address - GBA_REG_DEBUG_STRING, gba->debugString);
			return;
		}
		GBAIOWrite(gba, address, value & 0xFFFF);
		GBAIOWrite(gba, address | 2, value >> 16);
		return;
	}
	gba->memory.io[address >> 1] = value;
	gba->memory.io[(address >> 1) + 1] = value >> 16;
}

bool GBAIOIsReadConstant(uint32_t address) {
	switch (address) {
	default:
		return false;
	case GBA_REG_BG0CNT:
	case GBA_REG_BG1CNT:
	case GBA_REG_BG2CNT:
	case GBA_REG_BG3CNT:
	case GBA_REG_WININ:
	case GBA_REG_WINOUT:
	case GBA_REG_BLDCNT:
	case GBA_REG_BLDALPHA:
	case GBA_REG_SOUND1CNT_LO:
	case GBA_REG_SOUND1CNT_HI:
	case GBA_REG_SOUND1CNT_X:
	case GBA_REG_SOUND2CNT_LO:
	case GBA_REG_SOUND2CNT_HI:
	case GBA_REG_SOUND3CNT_LO:
	case GBA_REG_SOUND3CNT_HI:
	case GBA_REG_SOUND3CNT_X:
	case GBA_REG_SOUND4CNT_LO:
	case GBA_REG_SOUND4CNT_HI:
	case GBA_REG_SOUNDCNT_LO:
	case GBA_REG_SOUNDCNT_HI:
	case GBA_REG_TM0CNT_HI:
	case GBA_REG_TM1CNT_HI:
	case GBA_REG_TM2CNT_HI:
	case GBA_REG_TM3CNT_HI:
	case GBA_REG_KEYINPUT:
	case GBA_REG_KEYCNT:
	case GBA_REG_IE:
		return true;
	}
}

uint16_t GBAIORead(struct GBA* gba, uint32_t address) {
	if (!GBAIOIsReadConstant(address)) {
		// Most IO reads need to disable idle removal
		gba->haltPending = false;
	}

	switch (address) {
	// Reading this takes two cycles (1N+1I), so let's remove them preemptively
	case GBA_REG_TM0CNT_LO:
		GBATimerUpdateRegister(gba, 0, 2);
		break;
	case GBA_REG_TM1CNT_LO:
		GBATimerUpdateRegister(gba, 1, 2);
		break;
	case GBA_REG_TM2CNT_LO:
		GBATimerUpdateRegister(gba, 2, 2);
		break;
	case GBA_REG_TM3CNT_LO:
		GBATimerUpdateRegister(gba, 3, 2);
		break;

	case GBA_REG_KEYINPUT: {
			size_t c;
			for (c = 0; c < mCoreCallbacksListSize(&gba->coreCallbacks); ++c) {
				struct mCoreCallbacks* callbacks = mCoreCallbacksListGetPointer(&gba->coreCallbacks, c);
				if (callbacks->keysRead) {
					callbacks->keysRead(callbacks->context);
				}
			}
			bool allowOpposingDirections = gba->allowOpposingDirections;
			if (gba->keyCallback) {
				gba->keysActive = gba->keyCallback->readKeys(gba->keyCallback);
				if (!allowOpposingDirections) {
					allowOpposingDirections = gba->keyCallback->requireOpposingDirections;
				}
			}
			uint16_t input = gba->keysActive;
			if (!allowOpposingDirections) {
				unsigned rl = input & 0x030;
				unsigned ud = input & 0x0C0;
				input &= 0x30F;
				if (rl != 0x030) {
					input |= rl;
				}
				if (ud != 0x0C0) {
					input |= ud;
				}
			}
			gba->memory.io[address >> 1] = 0x3FF ^ input;
		}
		break;
	case GBA_REG_SIOCNT:
		return gba->sio.siocnt;
	case GBA_REG_RCNT:
		return gba->sio.rcnt;

	case GBA_REG_BG0HOFS:
	case GBA_REG_BG0VOFS:
	case GBA_REG_BG1HOFS:
	case GBA_REG_BG1VOFS:
	case GBA_REG_BG2HOFS:
	case GBA_REG_BG2VOFS:
	case GBA_REG_BG3HOFS:
	case GBA_REG_BG3VOFS:
	case GBA_REG_BG2PA:
	case GBA_REG_BG2PB:
	case GBA_REG_BG2PC:
	case GBA_REG_BG2PD:
	case GBA_REG_BG2X_LO:
	case GBA_REG_BG2X_HI:
	case GBA_REG_BG2Y_LO:
	case GBA_REG_BG2Y_HI:
	case GBA_REG_BG3PA:
	case GBA_REG_BG3PB:
	case GBA_REG_BG3PC:
	case GBA_REG_BG3PD:
	case GBA_REG_BG3X_LO:
	case GBA_REG_BG3X_HI:
	case GBA_REG_BG3Y_LO:
	case GBA_REG_BG3Y_HI:
	case GBA_REG_WIN0H:
	case GBA_REG_WIN1H:
	case GBA_REG_WIN0V:
	case GBA_REG_WIN1V:
	case GBA_REG_MOSAIC:
	case GBA_REG_BLDY:
	case GBA_REG_FIFO_A_LO:
	case GBA_REG_FIFO_A_HI:
	case GBA_REG_FIFO_B_LO:
	case GBA_REG_FIFO_B_HI:
	case GBA_REG_DMA0SAD_LO:
	case GBA_REG_DMA0SAD_HI:
	case GBA_REG_DMA0DAD_LO:
	case GBA_REG_DMA0DAD_HI:
	case GBA_REG_DMA1SAD_LO:
	case GBA_REG_DMA1SAD_HI:
	case GBA_REG_DMA1DAD_LO:
	case GBA_REG_DMA1DAD_HI:
	case GBA_REG_DMA2SAD_LO:
	case GBA_REG_DMA2SAD_HI:
	case GBA_REG_DMA2DAD_LO:
	case GBA_REG_DMA2DAD_HI:
	case GBA_REG_DMA3SAD_LO:
	case GBA_REG_DMA3SAD_HI:
	case GBA_REG_DMA3DAD_LO:
	case GBA_REG_DMA3DAD_HI:
		// Write-only register
		mLOG(GBA_IO, GAME_ERROR, "Read from write-only I/O register: %03X", address);
		return GBALoadBad(gba->cpu);

	case GBA_REG_DMA0CNT_LO:
	case GBA_REG_DMA1CNT_LO:
	case GBA_REG_DMA2CNT_LO:
	case GBA_REG_DMA3CNT_LO:
		// Many, many things read from the DMA register
	case GBA_REG_MAX:
		// Some bad interrupt libraries will read from this
		// (Silent) write-only register
		return 0;

	case GBA_REG_JOY_RECV_LO:
	case GBA_REG_JOY_RECV_HI:
		gba->memory.io[GBA_REG(JOYSTAT)] &= ~JOYSTAT_RECV;
		break;

	// Wave RAM can be written and read even if the audio hardware is disabled.
	// However, it is not possible to switch between the two banks because it
	// isn't possible to write to register SOUND3CNT_LO.
	case GBA_REG_WAVE_RAM0_LO:
		return GBAAudioReadWaveRAM(&gba->audio, 0) & 0xFFFF;
	case GBA_REG_WAVE_RAM0_HI:
		return GBAAudioReadWaveRAM(&gba->audio, 0) >> 16;
	case GBA_REG_WAVE_RAM1_LO:
		return GBAAudioReadWaveRAM(&gba->audio, 1) & 0xFFFF;
	case GBA_REG_WAVE_RAM1_HI:
		return GBAAudioReadWaveRAM(&gba->audio, 1) >> 16;
	case GBA_REG_WAVE_RAM2_LO:
		return GBAAudioReadWaveRAM(&gba->audio, 2) & 0xFFFF;
	case GBA_REG_WAVE_RAM2_HI:
		return GBAAudioReadWaveRAM(&gba->audio, 2) >> 16;
	case GBA_REG_WAVE_RAM3_LO:
		return GBAAudioReadWaveRAM(&gba->audio, 3) & 0xFFFF;
	case GBA_REG_WAVE_RAM3_HI:
		return GBAAudioReadWaveRAM(&gba->audio, 3) >> 16;

	case GBA_REG_SOUND1CNT_LO:
	case GBA_REG_SOUND1CNT_HI:
	case GBA_REG_SOUND1CNT_X:
	case GBA_REG_SOUND2CNT_LO:
	case GBA_REG_SOUND2CNT_HI:
	case GBA_REG_SOUND3CNT_LO:
	case GBA_REG_SOUND3CNT_HI:
	case GBA_REG_SOUND3CNT_X:
	case GBA_REG_SOUND4CNT_LO:
	case GBA_REG_SOUND4CNT_HI:
	case GBA_REG_SOUNDCNT_LO:
		if (!GBAudioEnableIsEnable(gba->memory.io[GBA_REG(SOUNDCNT_X)])) {
			// TODO: Is writing allowed when the circuit is disabled?
			return 0;
		}
		// Fall through
	case GBA_REG_DISPCNT:
	case GBA_REG_STEREOCNT:
	case GBA_REG_DISPSTAT:
	case GBA_REG_VCOUNT:
	case GBA_REG_BG0CNT:
	case GBA_REG_BG1CNT:
	case GBA_REG_BG2CNT:
	case GBA_REG_BG3CNT:
	case GBA_REG_WININ:
	case GBA_REG_WINOUT:
	case GBA_REG_BLDCNT:
	case GBA_REG_BLDALPHA:
	case GBA_REG_SOUNDCNT_HI:
	case GBA_REG_SOUNDCNT_X:
	case GBA_REG_SOUNDBIAS:
	case GBA_REG_DMA0CNT_HI:
	case GBA_REG_DMA1CNT_HI:
	case GBA_REG_DMA2CNT_HI:
	case GBA_REG_DMA3CNT_HI:
	case GBA_REG_TM0CNT_HI:
	case GBA_REG_TM1CNT_HI:
	case GBA_REG_TM2CNT_HI:
	case GBA_REG_TM3CNT_HI:
	case GBA_REG_KEYCNT:
	case GBA_REG_SIOMULTI0:
	case GBA_REG_SIOMULTI1:
	case GBA_REG_SIOMULTI2:
	case GBA_REG_SIOMULTI3:
	case GBA_REG_SIOMLT_SEND:
	case GBA_REG_JOYCNT:
	case GBA_REG_JOY_TRANS_LO:
	case GBA_REG_JOY_TRANS_HI:
	case GBA_REG_JOYSTAT:
	case GBA_REG_IE:
	case GBA_REG_IF:
	case GBA_REG_WAITCNT:
	case GBA_REG_IME:
	case GBA_REG_POSTFLG:
		// Handled transparently by registers
		break;
	case 0x066:
	case 0x06A:
	case 0x06E:
	case 0x076:
	case 0x07A:
	case 0x07E:
	case 0x086:
	case 0x08A:
	case 0x136:
	case 0x142:
	case 0x15A:
	case 0x206:
	case 0x302:
		mLOG(GBA_IO, GAME_ERROR, "Read from unused I/O register: %03X", address);
		return 0;
	// These registers sit outside of the normal I/O block, so we need to stash them somewhere unused
	case GBA_REG_EXWAITCNT_LO:
	case GBA_REG_EXWAITCNT_HI:
		address += GBA_REG_INTERNAL_EXWAITCNT_LO - GBA_REG_EXWAITCNT_LO;
		break;
	case GBA_REG_DEBUG_ENABLE:
		if (gba->debug) {
			return 0x1DEA;
		}
		// Fall through
	default:
		mLOG(GBA_IO, GAME_ERROR, "Read from unused I/O register: %03X", address);
		return GBALoadBad(gba->cpu);
	}
	return gba->memory.io[address >> 1];
}

void GBAIOSerialize(struct GBA* gba, struct GBASerializedState* state) {
	int i;
	for (i = 0; i < GBA_REG_INTERNAL_MAX; i += 2) {
		if (_isRSpecialRegister[i >> 1]) {
			STORE_16(gba->memory.io[i >> 1], i, state->io);
		} else if (_isValidRegister[i >> 1]) {
			uint16_t reg = GBAIORead(gba, i);
			STORE_16(reg, i, state->io);
		}
	}

	for (i = 0; i < 4; ++i) {
		STORE_16(gba->memory.io[(GBA_REG_DMA0CNT_LO + i * 12) >> 1], (GBA_REG_DMA0CNT_LO + i * 12), state->io);
		STORE_16(gba->timers[i].reload, 0, &state->timers[i].reload);
		STORE_32(gba->timers[i].lastEvent - mTimingCurrentTime(&gba->timing), 0, &state->timers[i].lastEvent);
		STORE_32(gba->timers[i].event.when - mTimingCurrentTime(&gba->timing), 0, &state->timers[i].nextEvent);
		STORE_32(gba->timers[i].flags, 0, &state->timers[i].flags);
	}
	STORE_32(gba->bus, 0, &state->bus);

	GBADMASerialize(gba, state);
	GBAHardwareSerialize(&gba->memory.hw, state);
}

void GBAIODeserialize(struct GBA* gba, const struct GBASerializedState* state) {
	LOAD_16(gba->memory.io[GBA_REG(SOUNDCNT_X)], GBA_REG_SOUNDCNT_X, state->io);
	GBAAudioWriteSOUNDCNT_X(&gba->audio, gba->memory.io[GBA_REG(SOUNDCNT_X)]);

	int i;
	for (i = 0; i < GBA_REG_MAX; i += 2) {
		if (_isWSpecialRegister[i >> 1]) {
			LOAD_16(gba->memory.io[i >> 1], i, state->io);
		} else if (_isValidRegister[i >> 1]) {
			uint16_t reg;
			LOAD_16(reg, i, state->io);
			GBAIOWrite(gba, i, reg);
		}
	}
	if (state->versionMagic >= 0x01000006) {
		GBAIOWrite(gba, GBA_REG_EXWAITCNT_HI, gba->memory.io[GBA_REG(INTERNAL_EXWAITCNT_HI)]);
	}

	uint32_t when;
	for (i = 0; i < 4; ++i) {
		LOAD_16(gba->timers[i].reload, 0, &state->timers[i].reload);
		LOAD_32(gba->timers[i].flags, 0, &state->timers[i].flags);
		LOAD_32(when, 0, &state->timers[i].lastEvent);
		gba->timers[i].lastEvent = when + mTimingCurrentTime(&gba->timing);
		LOAD_32(when, 0, &state->timers[i].nextEvent);
		if ((i < 1 || !GBATimerFlagsIsCountUp(gba->timers[i].flags)) && GBATimerFlagsIsEnable(gba->timers[i].flags)) {
			mTimingSchedule(&gba->timing, &gba->timers[i].event, when);
		} else {
			gba->timers[i].event.when = when + mTimingCurrentTime(&gba->timing);
		}
	}
	gba->sio.siocnt = gba->memory.io[GBA_REG(SIOCNT)];
	GBASIOWriteRCNT(&gba->sio, gba->memory.io[GBA_REG(RCNT)]);

	LOAD_32(gba->bus, 0, &state->bus);
	GBADMADeserialize(gba, state);
	GBAHardwareDeserialize(&gba->memory.hw, state);
}

/* ===== Imported from reference implementation/input.c ===== */
GBA_EXPORT const struct InputPlatformInfo GBAInputInfo = {
	.platformName = "gba",
	.keyId = (const char*[]) {
		"A",
		"B",
		"Select",
		"Start",
		"Right",
		"Left",
		"Up",
		"Down",
		"R",
		"L"
	},
	.nKeys = GBA_KEY_MAX,
	.hat = {
		.up = GBA_KEY_UP,
		.left = GBA_KEY_LEFT,
		.down = GBA_KEY_DOWN,
		.right = GBA_KEY_RIGHT
	}
};

/* ===== Imported from reference implementation/overwrides.c ===== */
static const struct GBACartridgeOverride _overrides[] = {
	// Advance Wars
	{ "AWRE", GBA_SAVEDATA_FLASH512, HW_NONE, 0x8038810 },
	{ "AWRP", GBA_SAVEDATA_FLASH512, HW_NONE, 0x8038810 },

	// Advance Wars 2: Black Hole Rising
	{ "AW2E", GBA_SAVEDATA_FLASH512, HW_NONE, 0x8036E08 },
	{ "AW2P", GBA_SAVEDATA_FLASH512, HW_NONE, 0x803719C },

	// Boktai: The Sun is in Your Hand
	{ "U3IJ", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },
	{ "U3IE", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },
	{ "U3IP", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },

	// Boktai 2: Solar Boy Django
	{ "U32J", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },
	{ "U32E", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },
	{ "U32P", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },

	// Crash Bandicoot 2 - N-Tranced
	{ "AC8J", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "AC8E", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "AC8P", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

	// DigiCommunication Nyo - Datou! Black Gemagema Dan
	{ "BDKJ", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Dragon Ball Z - The Legacy of Goku
	{ "ALGP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Dragon Ball Z - The Legacy of Goku II
	{ "ALFJ", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "ALFE", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "ALFP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Dragon Ball Z - Taiketsu
	{ "BDBE", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BDBP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Drill Dozer
	{ "V49J", GBA_SAVEDATA_SRAM, HW_RUMBLE, GBA_IDLE_LOOP_NONE },
	{ "V49E", GBA_SAVEDATA_SRAM, HW_RUMBLE, GBA_IDLE_LOOP_NONE },
	{ "V49P", GBA_SAVEDATA_SRAM, HW_RUMBLE, GBA_IDLE_LOOP_NONE },

	// e-Reader
	{ "PEAJ", GBA_SAVEDATA_FLASH1M, HW_EREADER, GBA_IDLE_LOOP_NONE },
	{ "PSAJ", GBA_SAVEDATA_FLASH1M, HW_EREADER, GBA_IDLE_LOOP_NONE },
	{ "PSAE", GBA_SAVEDATA_FLASH1M, HW_EREADER, GBA_IDLE_LOOP_NONE },

	// Final Fantasy Tactics Advance
	{ "AFXE", GBA_SAVEDATA_FLASH512, HW_NONE, 0x8000428 },

	// F-Zero - Climax
	{ "BFTJ", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Goodboy Galaxy
	{ "2GBP", GBA_SAVEDATA_SRAM, HW_RUMBLE, GBA_IDLE_LOOP_NONE },

	// Iridion II
	{ "AI2E", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "AI2P", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Game Boy Wars Advance 1+2
	{ "BGWJ", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Golden Sun: The Lost Age
	{ "AGFE", GBA_SAVEDATA_FLASH512, HW_NONE, 0x801353A },

	// Koro Koro Puzzle - Happy Panechu!
	{ "KHPJ", GBA_SAVEDATA_EEPROM, HW_TILT, GBA_IDLE_LOOP_NONE },

	// Legendz - Yomigaeru Shiren no Shima
	{ "BLJJ", GBA_SAVEDATA_FLASH512, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "BLJK", GBA_SAVEDATA_FLASH512, HW_RTC, GBA_IDLE_LOOP_NONE },

	// Legendz - Sign of Nekuromu
	{ "BLVJ", GBA_SAVEDATA_FLASH512, HW_RTC, GBA_IDLE_LOOP_NONE },

	// Mega Man Battle Network
	{ "AREE", GBA_SAVEDATA_SRAM, HW_NONE, 0x800032E },

	// Mega Man Zero
	{ "AZCE", GBA_SAVEDATA_SRAM, HW_NONE, 0x80004E8 },

	// Metal Slug Advance
	{ "BSME", GBA_SAVEDATA_EEPROM, HW_NONE, 0x8000290 },

	// Pokemon Ruby
	{ "AXVJ", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXVE", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXVP", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXVI", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXVS", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXVD", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXVF", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },

	// Pokemon Sapphire
	{ "AXPJ", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXPE", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXPP", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXPI", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXPS", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXPD", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },
	{ "AXPF", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },

	// Pokemon Emerald
	{ "BPEJ", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
	{ "BPEE", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
	{ "BPEP", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
	{ "BPEI", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
	{ "BPES", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
	{ "BPED", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },
	{ "BPEF", GBA_SAVEDATA_FLASH1M, HW_RTC, 0x80008C6 },

	// Pokemon Mystery Dungeon
	{ "B24E", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "B24P", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Pokemon FireRed
	{ "BPRJ", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPRE", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPRP", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPRI", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPRS", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPRD", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPRF", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Pokemon LeafGreen
	{ "BPGJ", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPGE", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPGP", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPGI", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPGS", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPGD", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "BPGF", GBA_SAVEDATA_FLASH1M, HW_NONE, GBA_IDLE_LOOP_NONE },

	// RockMan EXE 4.5 - Real Operation
	{ "BR4J", GBA_SAVEDATA_FLASH512, HW_RTC, GBA_IDLE_LOOP_NONE },

	// Rocky
	{ "AR8E", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "AROP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Sennen Kazoku
	{ "BKAJ", GBA_SAVEDATA_FLASH1M, HW_RTC, GBA_IDLE_LOOP_NONE },

	// Shin Bokura no Taiyou: Gyakushuu no Sabata
	{ "U33J", GBA_SAVEDATA_EEPROM, HW_RTC | HW_LIGHT_SENSOR, GBA_IDLE_LOOP_NONE },

	// Stuart Little 2
	{ "ASLE", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "ASLF", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Super Mario Advance 2
	{ "AA2J", GBA_SAVEDATA_EEPROM, HW_NONE, 0x800052E },
	{ "AA2E", GBA_SAVEDATA_EEPROM, HW_NONE, 0x800052E },
	{ "AA2P", GBA_SAVEDATA_AUTODETECT, HW_NONE, 0x800052E },

	// Super Mario Advance 3
	{ "A3AJ", GBA_SAVEDATA_EEPROM, HW_NONE, 0x8002B9C },
	{ "A3AE", GBA_SAVEDATA_EEPROM, HW_NONE, 0x8002B9C },
	{ "A3AP", GBA_SAVEDATA_EEPROM, HW_NONE, 0x8002B9C },

	// Super Mario Advance 4
	{ "AX4J", GBA_SAVEDATA_FLASH1M, HW_NONE, 0x800072A },
	{ "AX4E", GBA_SAVEDATA_FLASH1M, HW_NONE, 0x800072A },
	{ "AX4P", GBA_SAVEDATA_FLASH1M, HW_NONE, 0x800072A },

	// Super Monkey Ball Jr.
	{ "ALUE", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },
	{ "ALUP", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Top Gun - Combat Zones
	{ "A2YE", GBA_SAVEDATA_FORCE_NONE, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Ueki no Housoku - Jingi Sakuretsu! Nouryokusha Battle
	{ "BUHJ", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE },

	// Wario Ware Twisted
	{ "RZWJ", GBA_SAVEDATA_SRAM, HW_RUMBLE | HW_GYRO, GBA_IDLE_LOOP_NONE },
	{ "RZWE", GBA_SAVEDATA_SRAM, HW_RUMBLE | HW_GYRO, GBA_IDLE_LOOP_NONE },
	{ "RZWP", GBA_SAVEDATA_SRAM, HW_RUMBLE | HW_GYRO, GBA_IDLE_LOOP_NONE },

	// Yoshi's Universal Gravitation
	{ "KYGJ", GBA_SAVEDATA_EEPROM, HW_TILT, GBA_IDLE_LOOP_NONE },
	{ "KYGE", GBA_SAVEDATA_EEPROM, HW_TILT, GBA_IDLE_LOOP_NONE },
	{ "KYGP", GBA_SAVEDATA_EEPROM, HW_TILT, GBA_IDLE_LOOP_NONE },

	// Aging cartridge
	{ "TCHK", GBA_SAVEDATA_EEPROM, HW_NONE, GBA_IDLE_LOOP_NONE, },

	{ { 0, 0, 0, 0 }, 0, 0, GBA_IDLE_LOOP_NONE, false }
};

bool GBAOverrideFindConfig(const struct Configuration* config, struct GBACartridgeOverride* override) {
	bool found = false;
	if (config) {
		char sectionName[16];
		snprintf(sectionName, sizeof(sectionName), "override.%c%c%c%c", override->id[0], override->id[1], override->id[2], override->id[3]);
		const char* savetype = ConfigurationGetValue(config, sectionName, "savetype");
		const char* hardware = ConfigurationGetValue(config, sectionName, "hardware");
		const char* idleLoop = ConfigurationGetValue(config, sectionName, "idleLoop");

		if (savetype) {
			if (strcasecmp(savetype, "SRAM") == 0) {
				found = true;
				override->savetype = GBA_SAVEDATA_SRAM;
			} else if (strcasecmp(savetype, "SRAM512") == 0) {
				found = true;
				override->savetype = GBA_SAVEDATA_SRAM512;
			} else if (strcasecmp(savetype, "EEPROM") == 0) {
				found = true;
				override->savetype = GBA_SAVEDATA_EEPROM;
			} else if (strcasecmp(savetype, "EEPROM512") == 0) {
				found = true;
				override->savetype = GBA_SAVEDATA_EEPROM512;
			} else if (strcasecmp(savetype, "FLASH512") == 0) {
				found = true;
				override->savetype = GBA_SAVEDATA_FLASH512;
			} else if (strcasecmp(savetype, "FLASH1M") == 0) {
				found = true;
				override->savetype = GBA_SAVEDATA_FLASH1M;
			} else if (strcasecmp(savetype, "NONE") == 0) {
				found = true;
				override->savetype = GBA_SAVEDATA_FORCE_NONE;
			}
		}

		if (hardware) {
			char* end;
			long type = strtoul(hardware, &end, 0);
			if (end && !*end) {
				override->hardware = type & ~HW_NO_OVERRIDE;
				found = true;
			}
		}

		if (idleLoop) {
			char* end;
			uint32_t address = strtoul(idleLoop, &end, 16);
			if (end && !*end) {
				override->idleLoop = address;
				found = true;
			}
		}
	}
	return found;
}

bool GBAOverrideFind(const struct Configuration* config, struct GBACartridgeOverride* override) {
	override->savetype = GBA_SAVEDATA_AUTODETECT;
	override->hardware = HW_NO_OVERRIDE;
	override->idleLoop = GBA_IDLE_LOOP_NONE;
	override->vbaBugCompat = false;
	bool found = false;

	int i;
	for (i = 0; _overrides[i].id[0]; ++i) {
		if (memcmp(override->id, _overrides[i].id, sizeof(override->id)) == 0) {
			*override = _overrides[i];
			found = true;
			break;
		}
	}
	if (!found && override->id[0] == 'F') {
		// Classic NES Series
		override->savetype = GBA_SAVEDATA_EEPROM;
		found = true;
	}

	if (config) {
		found = GBAOverrideFindConfig(config, override) || found;
	}
	return found;
}

void GBAOverrideSave(struct Configuration* config, const struct GBACartridgeOverride* override) {
	char sectionName[16];
	snprintf(sectionName, sizeof(sectionName), "override.%c%c%c%c", override->id[0], override->id[1], override->id[2], override->id[3]);
	const char* savetype = 0;
	switch (override->savetype) {
	case GBA_SAVEDATA_SRAM:
		savetype = "SRAM";
		break;
	case GBA_SAVEDATA_SRAM512:
		savetype = "SRAM512";
		break;
	case GBA_SAVEDATA_EEPROM:
		savetype = "EEPROM";
		break;
	case GBA_SAVEDATA_EEPROM512:
		savetype = "EEPROM512";
		break;
	case GBA_SAVEDATA_FLASH512:
		savetype = "FLASH512";
		break;
	case GBA_SAVEDATA_FLASH1M:
		savetype = "FLASH1M";
		break;
	case GBA_SAVEDATA_FORCE_NONE:
		savetype = "NONE";
		break;
	case GBA_SAVEDATA_AUTODETECT:
		break;
	}
	ConfigurationSetValue(config, sectionName, "savetype", savetype);

	if (override->hardware != HW_NO_OVERRIDE) {
		ConfigurationSetIntValue(config, sectionName, "hardware", override->hardware);
	} else {
		ConfigurationClearValue(config, sectionName, "hardware");
	}

	if (override->idleLoop != GBA_IDLE_LOOP_NONE) {
		ConfigurationSetUIntValue(config, sectionName, "idleLoop", override->idleLoop);
	} else {
		ConfigurationClearValue(config, sectionName, "idleLoop");
	}
}

void GBAOverrideApply(struct GBA* gba, const struct GBACartridgeOverride* override) {
	if (override->savetype != GBA_SAVEDATA_AUTODETECT) {
		GBASavedataForceType(&gba->memory.savedata, override->savetype);
	}

	gba->vbaBugCompat = override->vbaBugCompat;

	if (override->hardware != HW_NO_OVERRIDE) {
		GBAHardwareClear(&gba->memory.hw);
		gba->memory.hw.devices &= ~HW_NO_OVERRIDE;

		if (override->hardware & HW_RTC) {
			GBAHardwareInitRTC(&gba->memory.hw);
			GBASavedataRTCRead(&gba->memory.savedata);
		}

		if (override->hardware & HW_GYRO) {
			GBAHardwareInitGyro(&gba->memory.hw);
		}

		if (override->hardware & HW_RUMBLE) {
			GBAHardwareInitRumble(&gba->memory.hw);
		}

		if (override->hardware & HW_LIGHT_SENSOR) {
			GBAHardwareInitLight(&gba->memory.hw);
		}

		if (override->hardware & HW_TILT) {
			GBAHardwareInitTilt(&gba->memory.hw);
		}

		if (override->hardware & HW_EREADER) {
			GBACartEReaderInit(&gba->memory.ereader);
		}

		if (override->hardware & HW_GB_PLAYER_DETECTION) {
			gba->memory.hw.devices |= HW_GB_PLAYER_DETECTION;
		} else {
			gba->memory.hw.devices &= ~HW_GB_PLAYER_DETECTION;
		}
	}

	if (override->idleLoop != GBA_IDLE_LOOP_NONE) {
		gba->idleLoop = override->idleLoop;
		if (gba->idleOptimization == IDLE_LOOP_DETECT) {
			gba->idleOptimization = IDLE_LOOP_REMOVE;
		}
	}
}

void GBAOverrideApplyDefaults(struct GBA* gba, const struct Configuration* overrides) {
	struct GBACartridgeOverride override = { .idleLoop = GBA_IDLE_LOOP_NONE };
	const struct GBACartridge* cart = (const struct GBACartridge*) gba->memory.rom;
	if (cart) {
		if (gba->memory.unl.type == GBA_UNL_CART_MULTICART) {
			override.savetype = GBA_SAVEDATA_SRAM;
			GBAOverrideApply(gba, &override);
			return;
		}

		memcpy(override.id, &cart->id, sizeof(override.id));

		static const uint32_t pokemonTable[] = {
			// Emerald
			0x4881F3F8, // BPEJ
			0x8C4D3108, // BPES
			0x1F1C08FB, // BPEE
			0x34C9DF89, // BPED
			0xA3FDCCB1, // BPEF
			0xA0AEC80A, // BPEI

			// FireRed
			0x1A81EEDF, // BPRD
			0x3B2056E9, // BPRJ
			0x5DC668F6, // BPRF
			0x73A72167, // BPRI
			0x84EE4776, // BPRE rev 1
			0x9F08064E, // BPRS
			0xBB640DF7, // BPRJ rev 1
			0xDD88761C, // BPRE

			// Ruby
			0x61641576, // AXVE rev 1
			0xAEAC73E6, // AXVE rev 2
			0xF0815EE7, // AXVE
		};

		bool isPokemon = false;
		isPokemon = isPokemon || !strncmp("pokemon red version", &((const char*) gba->memory.rom)[0x108], 20);
		isPokemon = isPokemon || !strncmp("pokemon emerald version", &((const char*) gba->memory.rom)[0x108], 24);
		isPokemon = isPokemon || !strncmp("AXVE", &((const char*) gba->memory.rom)[0xAC], 4);
		bool isKnownPokemon = false;
		if (isPokemon) {
			size_t i;
			for (i = 0; !isKnownPokemon && i < sizeof(pokemonTable) / sizeof(*pokemonTable); ++i) {
				isKnownPokemon = gba->romCrc32 == pokemonTable[i];
			}
		}

		if (isPokemon && !isKnownPokemon) {
			// Enable FLASH1M and RTC on PokÃ©mon ROM hacks
			override.savetype = GBA_SAVEDATA_FLASH1M;
			override.hardware = HW_RTC;
			override.vbaBugCompat = true;
			// Allow overrides from config file but not from defaults
			GBAOverrideFindConfig(overrides, &override);
			GBAOverrideApply(gba, &override);
		} else if (GBAOverrideFind(overrides, &override)) {
			GBAOverrideApply(gba, &override);
		}
	}
}
