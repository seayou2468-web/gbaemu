#include "../gba_core.h"
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* ===== Imported/adapted from tv/unlicensed.c + tv/vfame.c ===== */

static uint32_t _vfamePatternRightShift2(uint32_t addr) {
	uint32_t value = addr & 0xFFFF;
	value >>= 2;
	value += (addr & 3) == 2 ? 0x8000 : 0;
	value += (addr & 0x10000) ? 0x4000 : 0;
	return value;
}

static uint32_t _vfamePattern16(uint32_t addr) {
	addr &= 0x1FFFFF;
	uint32_t value = 0;
	switch (addr & 0x1F0000) {
	case 0x000000:
	case 0x010000:
		value = (addr >> 1) & 0xFFFF;
		break;
	case 0x020000:
		value = addr & 0xFFFF;
		break;
	case 0x030000:
		value = (addr & 0xFFFF) + 1;
		break;
	case 0x040000:
		value = 0xFFFF - (addr & 0xFFFF);
		break;
	case 0x050000:
		value = (0xFFFF - (addr & 0xFFFF)) - 1;
		break;
	case 0x060000:
		value = (addr & 0xFFFF) ^ 0xAAAA;
		break;
	case 0x070000:
		value = ((addr & 0xFFFF) ^ 0xAAAA) + 1;
		break;
	case 0x080000:
		value = (addr & 0xFFFF) ^ 0x5555;
		break;
	case 0x090000:
		value = ((addr & 0xFFFF) ^ 0x5555) - 1;
		break;
	case 0x0A0000:
	case 0x0B0000:
		value = _vfamePatternRightShift2(addr);
		break;
	case 0x0C0000:
	case 0x0D0000:
		value = 0xFFFF - _vfamePatternRightShift2(addr);
		break;
	case 0x0E0000:
	case 0x0F0000:
		value = _vfamePatternRightShift2(addr) ^ 0xAAAA;
		break;
	case 0x100000:
	case 0x110000:
		value = _vfamePatternRightShift2(addr) ^ 0x5555;
		break;
	case 0x120000:
		value = 0xFFFF - ((addr & 0xFFFF) >> 1);
		break;
	case 0x130000:
		value = 0xFFFF - ((addr & 0xFFFF) >> 1) - 0x8000;
		break;
	case 0x140000:
	case 0x150000:
		value = ((addr >> 1) & 0xFFFF) ^ 0xAAAA;
		break;
	case 0x160000:
	case 0x170000:
		value = ((addr >> 1) & 0xFFFF) ^ 0x5555;
		break;
	case 0x180000:
	case 0x190000:
		value = ((addr >> 1) & 0xFFFF) ^ 0xF0F0;
		break;
	case 0x1A0000:
	case 0x1B0000:
		value = ((addr >> 1) & 0xFFFF) ^ 0x0F0F;
		break;
	case 0x1C0000:
	case 0x1D0000:
		value = ((addr >> 1) & 0xFFFF) ^ 0xFF00;
		break;
	case 0x1E0000:
	case 0x1F0000:
		value = ((addr >> 1) & 0xFFFF) ^ 0x00FF;
		break;
	}
	return value & 0xFFFF;
}

void GBAUnlCartInit(struct GBA* gba) {
	if (!gba) {
		return;
	}
	gba->memory.unl.type = GBA_UNL_CART_NONE;
}

void GBAUnlCartReset(struct GBA* gba) {
	if (!gba) {
		return;
	}
	if (gba->memory.unl.type != GBA_UNL_CART_VFAME) {
		gba->memory.unl.type = GBA_UNL_CART_NONE;
	}
}

void GBAUnlCartWriteROM(struct GBA* gba, uint32_t address, uint16_t value) {
	UNUSED(gba);
	UNUSED(address);
	UNUSED(value);
}

void GBAUnlCartWriteSRAM(struct GBA* gba, uint32_t address, uint8_t value) {
	if (!gba || !gba->memory.savedata.data) {
		return;
	}
	gba->memory.savedata.data[address & (GBA_SIZE_SRAM - 1)] = value;
	gba->memory.savedata.dirty |= mSAVEDATA_DIRT_NEW;
}

uint32_t GBAVFameGetPatternValue(uint32_t address, int bits) {
	switch (bits) {
	case 8:
		if (address & 1) {
			return _vfamePattern16(address) & 0xFF;
		}
		return (_vfamePattern16(address) & 0xFF00) >> 8;
	case 16:
		return _vfamePattern16(address);
	case 32:
		return (_vfamePattern16(address) << 16) | _vfamePattern16(address + 2);
	default:
		return 0;
	}
}

uint32_t GBAVFrameGetPatternValue(uint32_t address, int bits) {
	return GBAVFameGetPatternValue(address, bits);
}
