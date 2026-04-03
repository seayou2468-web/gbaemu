#include "../gba_core.h"
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

/* ===== Imported from reference implementation/video.c ===== */
mLOG_DEFINE_CATEGORY(GBA_VIDEO, "GBA Video", "gba.video");

static void GBAVideoDummyRendererInit(struct GBAVideoRenderer* renderer);
static void GBAVideoDummyRendererReset(struct GBAVideoRenderer* renderer);
static void GBAVideoDummyRendererDeinit(struct GBAVideoRenderer* renderer);
static uint16_t GBAVideoDummyRendererWriteVideoRegister(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value);
static void GBAVideoDummyRendererWriteVRAM(struct GBAVideoRenderer* renderer, uint32_t address);
static void GBAVideoDummyRendererWritePalette(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value);
static void GBAVideoDummyRendererWriteOAM(struct GBAVideoRenderer* renderer, uint32_t oam);
static void GBAVideoDummyRendererDrawScanline(struct GBAVideoRenderer* renderer, int y);
static void GBAVideoDummyRendererFinishFrame(struct GBAVideoRenderer* renderer);
static void GBAVideoDummyRendererGetPixels(struct GBAVideoRenderer* renderer, size_t* stride, const void** pixels);
static void GBAVideoDummyRendererPutPixels(struct GBAVideoRenderer* renderer, size_t stride, const void* pixels);

static void _startHblank(struct mTiming*, void* context, uint32_t cyclesLate);
static void _startHdraw(struct mTiming*, void* context, uint32_t cyclesLate);
static unsigned _calculateStallMask(struct GBA* gba, unsigned dispcnt);

MGBA_EXPORT const int GBAVideoObjSizes[16][2] = {
	{ 8, 8 },
	{ 16, 16 },
	{ 32, 32 },
	{ 64, 64 },
	{ 16, 8 },
	{ 32, 8 },
	{ 32, 16 },
	{ 64, 32 },
	{ 8, 16 },
	{ 8, 32 },
	{ 16, 32 },
	{ 32, 64 },
	{ 0, 0 },
	{ 0, 0 },
	{ 0, 0 },
	{ 0, 0 },
};

void GBAVideoInit(struct GBAVideo* video) {
	video->renderer = NULL;
	video->vram = anonymousMemoryMap(GBA_SIZE_VRAM);
	video->frameskip = 0;
	video->event.name = "GBA Video";
	video->event.callback = NULL;
	video->event.context = video;
	video->event.priority = 8;
}

void GBAVideoReset(struct GBAVideo* video) {
	int32_t nextEvent = VIDEO_HDRAW_LENGTH;
	if (video->p->memory.fullBios) {
		video->vcount = 0;
	} else {
		// TODO: Verify exact scanline on hardware
		video->vcount = 0x7E;
		nextEvent = 120;
	}
	video->p->memory.io[GBA_REG(VCOUNT)] = video->vcount;

	video->event.callback = _startHblank;
	mTimingSchedule(&video->p->timing, &video->event, nextEvent);

	video->frameCounter = 0;
	video->frameskipCounter = 0;
	video->stallMask = 0;

	memset(video->palette, 0, sizeof(video->palette));
	memset(video->oam.raw, 0, sizeof(video->oam.raw));
	memset(video->vram, 0, GBA_SIZE_VRAM);

	if (!video->renderer) {
		mLOG(GBA_VIDEO, FATAL, "No renderer associated");
		return;
	}
	video->renderer->vram = video->vram;
	video->renderer->reset(video->renderer);
}

void GBAVideoDeinit(struct GBAVideo* video) {
	video->renderer->deinit(video->renderer);
	mappedMemoryFree(video->vram, GBA_SIZE_VRAM);
}

void GBAVideoDummyRendererCreate(struct GBAVideoRenderer* renderer) {
	static const struct GBAVideoRenderer dummyRenderer = {
		.init = GBAVideoDummyRendererInit,
		.reset = GBAVideoDummyRendererReset,
		.deinit = GBAVideoDummyRendererDeinit,
		.writeVideoRegister = GBAVideoDummyRendererWriteVideoRegister,
		.writeVRAM = GBAVideoDummyRendererWriteVRAM,
		.writePalette = GBAVideoDummyRendererWritePalette,
		.writeOAM = GBAVideoDummyRendererWriteOAM,
		.drawScanline = GBAVideoDummyRendererDrawScanline,
		.finishFrame = GBAVideoDummyRendererFinishFrame,
		.getPixels = GBAVideoDummyRendererGetPixels,
		.putPixels = GBAVideoDummyRendererPutPixels,
	};
	memcpy(renderer, &dummyRenderer, sizeof(*renderer));
}

void GBAVideoAssociateRenderer(struct GBAVideo* video, struct GBAVideoRenderer* renderer) {
	if (video->renderer) {
		video->renderer->deinit(video->renderer);
		renderer->cache = video->renderer->cache;
	} else {
		renderer->cache = NULL;
	}
	video->renderer = renderer;
	renderer->palette = video->palette;
	renderer->vram = video->vram;
	renderer->oam = &video->oam;
	video->renderer->init(video->renderer);
	video->renderer->reset(video->renderer);
	renderer->writeVideoRegister(renderer, GBA_REG_DISPCNT, video->p->memory.io[GBA_REG(DISPCNT)]);
	renderer->writeVideoRegister(renderer, GBA_REG_STEREOCNT, video->p->memory.io[GBA_REG(STEREOCNT)]);
	int address;
	for (address = GBA_REG_BG0CNT; address < 0x56; address += 2) {
		if (address == 0x4E) {
			continue;
		}
		renderer->writeVideoRegister(renderer, address, video->p->memory.io[address >> 1]);
	}
}

void _startHdraw(struct mTiming* timing, void* context, uint32_t cyclesLate) {
	struct GBAVideo* video = context;
	video->event.callback = _startHblank;
	mTimingSchedule(timing, &video->event, VIDEO_HDRAW_LENGTH - cyclesLate);

	++video->vcount;
	if (video->vcount == VIDEO_VERTICAL_TOTAL_PIXELS) {
		video->vcount = 0;
	}
	video->p->memory.io[GBA_REG(VCOUNT)] = video->vcount;

	if (video->vcount < GBA_VIDEO_VERTICAL_PIXELS) {
		unsigned dispcnt = video->p->memory.io[GBA_REG(DISPCNT)];
		video->stallMask = _calculateStallMask(video->p, dispcnt);
	}

	GBARegisterDISPSTAT dispstat = video->p->memory.io[GBA_REG(DISPSTAT)];
	dispstat = GBARegisterDISPSTATClearInHblank(dispstat);
	if (video->vcount == GBARegisterDISPSTATGetVcountSetting(dispstat)) {
		dispstat = GBARegisterDISPSTATFillVcounter(dispstat);
		if (GBARegisterDISPSTATIsVcounterIRQ(dispstat)) {
			GBARaiseIRQ(video->p, GBA_IRQ_VCOUNTER, cyclesLate);
		}
	} else {
		dispstat = GBARegisterDISPSTATClearVcounter(dispstat);
	}
	video->p->memory.io[GBA_REG(DISPSTAT)] = dispstat;

	// Note: state may be recorded during callbacks, so ensure it is consistent!
	switch (video->vcount) {
	case 0:
		GBAFrameStarted(video->p);
		break;
	case GBA_VIDEO_VERTICAL_PIXELS:
		video->p->memory.io[GBA_REG(DISPSTAT)] = GBARegisterDISPSTATFillInVblank(dispstat);
		if (video->frameskipCounter <= 0) {
			video->renderer->finishFrame(video->renderer);
		}
		GBADMARunVblank(video->p, -cyclesLate);
		if (GBARegisterDISPSTATIsVblankIRQ(dispstat)) {
			GBARaiseIRQ(video->p, GBA_IRQ_VBLANK, cyclesLate);
		}
		GBAFrameEnded(video->p);
		mCoreSyncPostFrame(video->p->sync);
		--video->frameskipCounter;
		if (video->frameskipCounter < 0) {
			video->frameskipCounter = video->frameskip;
		}
		++video->frameCounter;
		GBAInterrupt(video->p);
		break;
	case VIDEO_VERTICAL_TOTAL_PIXELS - 1:
		video->p->memory.io[GBA_REG(DISPSTAT)] = GBARegisterDISPSTATClearInVblank(dispstat);
		break;
	}
}

void _startHblank(struct mTiming* timing, void* context, uint32_t cyclesLate) {
	struct GBAVideo* video = context;
	video->event.callback = _startHdraw;
	mTimingSchedule(timing, &video->event, VIDEO_HBLANK_LENGTH - cyclesLate);

	// Begin Hblank
	GBARegisterDISPSTAT dispstat = video->p->memory.io[GBA_REG(DISPSTAT)];
	dispstat = GBARegisterDISPSTATFillInHblank(dispstat);
	if (video->vcount < GBA_VIDEO_VERTICAL_PIXELS && video->frameskipCounter <= 0) {
		video->renderer->drawScanline(video->renderer, video->vcount);
	}

	if (video->vcount < GBA_VIDEO_VERTICAL_PIXELS) {
		GBADMARunHblank(video->p, -cyclesLate);
	}
	if (video->vcount >= 2 && video->vcount < GBA_VIDEO_VERTICAL_PIXELS + 2) {
		GBADMARunDisplayStart(video->p, -cyclesLate);
	}
	if (GBARegisterDISPSTATIsHblankIRQ(dispstat)) {
		GBARaiseIRQ(video->p, GBA_IRQ_HBLANK, cyclesLate - 6); // TODO: Where does this fudge factor come from?
	}
	video->stallMask = 0;
	video->p->memory.io[GBA_REG(DISPSTAT)] = dispstat;
}

uint16_t GBAVideoWriteDISPSTAT(struct GBAVideo* video, uint16_t value) {
	GBARegisterDISPSTAT dispstat = video->p->memory.io[GBA_REG(DISPSTAT)] & 0x7;
	dispstat |= value & 0xFFF8;

	if (video->vcount == GBARegisterDISPSTATGetVcountSetting(dispstat)) {
		// Edge trigger only
		if (GBARegisterDISPSTATIsVcounterIRQ(dispstat) && !GBARegisterDISPSTATIsVcounter(dispstat)) {
			GBARaiseIRQ(video->p, GBA_IRQ_VCOUNTER, 0);
		}
		dispstat = GBARegisterDISPSTATFillVcounter(dispstat);
	} else {
		dispstat = GBARegisterDISPSTATClearVcounter(dispstat);
	}
	return dispstat;
}

static unsigned _calculateStallMask(struct GBA* gba, unsigned dispcnt) {
	unsigned mask = 0;

	if (GBARegisterDISPCNTIsForcedBlank(dispcnt)) {
		return 0;
	}

	switch (GBARegisterDISPCNTGetMode(dispcnt)) {
	case 0:
		if (GBARegisterDISPCNTIsBg0Enable(dispcnt)) {
			if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG0CNT)])) {
				mask |= GBA_VSTALL_T8(0);
			} else {
				mask |= GBA_VSTALL_T4(0);
			}
		}
		if (GBARegisterDISPCNTIsBg1Enable(dispcnt)) {
			if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG1CNT)])) {
				mask |= GBA_VSTALL_T8(1);
			} else {
				mask |= GBA_VSTALL_T4(1);
			}
		}
		if (GBARegisterDISPCNTIsBg2Enable(dispcnt)) {
			if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG2CNT)])) {
				mask |= GBA_VSTALL_T8(2);
			} else {
				mask |= GBA_VSTALL_T4(2);
			}
		}
		if (GBARegisterDISPCNTIsBg3Enable(dispcnt)) {
			if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG3CNT)])) {
				mask |= GBA_VSTALL_T8(3);
			} else {
				mask |= GBA_VSTALL_T4(3);
			}
		}
		break;
	case 1:
		if (GBARegisterDISPCNTIsBg0Enable(dispcnt)) {
			if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG0CNT)])) {
				mask |= GBA_VSTALL_T8(0);
			} else {
				mask |= GBA_VSTALL_T4(0);
			}
		}
		if (GBARegisterDISPCNTIsBg1Enable(dispcnt)) {
			if (GBARegisterBGCNTIs256Color(gba->memory.io[GBA_REG(BG1CNT)])) {
				mask |= GBA_VSTALL_T8(1);
			} else {
				mask |= GBA_VSTALL_T4(1);
			}
		}
		if (GBARegisterDISPCNTIsBg2Enable(dispcnt)) {
			mask |= GBA_VSTALL_A2;
		}
		break;
	case 2:
		if (GBARegisterDISPCNTIsBg2Enable(dispcnt)) {
			mask |= GBA_VSTALL_A2;
		}
		if (GBARegisterDISPCNTIsBg3Enable(dispcnt)) {
			mask |= GBA_VSTALL_A3;
		}
		break;
	case 3:
	case 4:
	case 5:
		if (GBARegisterDISPCNTIsBg2Enable(dispcnt)) {
			mask |= GBA_VSTALL_B;
		}
		break;
	default:
		break;
	}
	return mask;
}

static void GBAVideoDummyRendererInit(struct GBAVideoRenderer* renderer) {
	UNUSED(renderer);
	// Nothing to do
}

static void GBAVideoDummyRendererReset(struct GBAVideoRenderer* renderer) {
	UNUSED(renderer);
	// Nothing to do
}

static void GBAVideoDummyRendererDeinit(struct GBAVideoRenderer* renderer) {
	UNUSED(renderer);
	// Nothing to do
}

static uint16_t GBAVideoDummyRendererWriteVideoRegister(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value) {
	if (renderer->cache) {
		GBAVideoCacheWriteVideoRegister(renderer->cache, address, value);
	}
	switch (address) {
	case GBA_REG_DISPCNT:
		value &= 0xFFF7;
		break;
	case GBA_REG_BG0CNT:
	case GBA_REG_BG1CNT:
		value &= 0xDFFF;
		break;
	case GBA_REG_BG2CNT:
	case GBA_REG_BG3CNT:
		value &= 0xFFFF;
		break;
	case GBA_REG_BG0HOFS:
	case GBA_REG_BG0VOFS:
	case GBA_REG_BG1HOFS:
	case GBA_REG_BG1VOFS:
	case GBA_REG_BG2HOFS:
	case GBA_REG_BG2VOFS:
	case GBA_REG_BG3HOFS:
	case GBA_REG_BG3VOFS:
		value &= 0x01FF;
		break;
	case GBA_REG_BLDCNT:
		value &= 0x3FFF;
		break;
	case GBA_REG_BLDALPHA:
		value &= 0x1F1F;
		break;
	case GBA_REG_WININ:
	case GBA_REG_WINOUT:
		value &= 0x3F3F;
		break;
	default:
		break;
	}
	return value;
}

static void GBAVideoDummyRendererWriteVRAM(struct GBAVideoRenderer* renderer, uint32_t address) {
	if (renderer->cache) {
		mCacheSetWriteVRAM(renderer->cache, address);
	}
}

static void GBAVideoDummyRendererWritePalette(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value) {
	if (renderer->cache) {
		mCacheSetWritePalette(renderer->cache, address >> 1, mColorFrom555(value));
	}
}

static void GBAVideoDummyRendererWriteOAM(struct GBAVideoRenderer* renderer, uint32_t oam) {
	UNUSED(renderer);
	UNUSED(oam);
	// Nothing to do
}

static void GBAVideoDummyRendererDrawScanline(struct GBAVideoRenderer* renderer, int y) {
	UNUSED(renderer);
	UNUSED(y);
	// Nothing to do
}

static void GBAVideoDummyRendererFinishFrame(struct GBAVideoRenderer* renderer) {
	UNUSED(renderer);
	// Nothing to do
}

static void GBAVideoDummyRendererGetPixels(struct GBAVideoRenderer* renderer, size_t* stride, const void** pixels) {
	UNUSED(renderer);
	UNUSED(stride);
	UNUSED(pixels);
	// Nothing to do
}

static void GBAVideoDummyRendererPutPixels(struct GBAVideoRenderer* renderer, size_t stride, const void* pixels) {
	UNUSED(renderer);
	UNUSED(stride);
	UNUSED(pixels);
	// Nothing to do
}

void GBAVideoSerialize(const struct GBAVideo* video, struct GBASerializedState* state) {
	memcpy(state->vram, video->vram, GBA_SIZE_VRAM);
	memcpy(state->oam, video->oam.raw, GBA_SIZE_OAM);
	memcpy(state->pram, video->palette, GBA_SIZE_PALETTE_RAM);
	STORE_32(video->event.when - mTimingCurrentTime(&video->p->timing), 0, &state->video.nextEvent);
	int32_t flags = 0;
	if (video->event.callback == _startHdraw) {
		flags = GBASerializedVideoFlagsSetMode(flags, 1);
	} else if (video->event.callback == _startHblank) {
		flags = GBASerializedVideoFlagsSetMode(flags, 2);
	}
	STORE_32(flags, 0, &state->video.flags);
	STORE_32(video->frameCounter, 0, &state->video.frameCounter);
}

void GBAVideoDeserialize(struct GBAVideo* video, const struct GBASerializedState* state) {
	memcpy(video->vram, state->vram, GBA_SIZE_VRAM);
	uint16_t value;
	int i;
	for (i = 0; i < GBA_SIZE_OAM; i += 2) {
		LOAD_16(value, i, state->oam);
		GBAStore16(video->p->cpu, GBA_BASE_OAM | i, value, 0);
	}
	for (i = 0; i < GBA_SIZE_PALETTE_RAM; i += 2) {
		LOAD_16(value, i, state->pram);
		GBAStore16(video->p->cpu, GBA_BASE_PALETTE_RAM | i, value, 0);
	}
	LOAD_32(video->frameCounter, 0, &state->video.frameCounter);

	video->stallMask = 0;
	int32_t flags;
	LOAD_32(flags, 0, &state->video.flags);
	GBARegisterDISPSTAT dispstat = state->io[GBA_REG(DISPSTAT)];
	switch (GBASerializedVideoFlagsGetMode(flags)) {
	case 0:
		if (GBARegisterDISPSTATIsInHblank(dispstat)) {
			video->event.callback = _startHdraw;
		} else {
			video->event.callback = _startHblank;
		}
		break;
	case 1:
		video->event.callback = _startHdraw;
		break;
	case 2:
		video->event.callback = _startHblank;
		video->stallMask = _calculateStallMask(video->p, state->io[GBA_REG(DISPCNT)]);
		break;
	case 3:
		video->event.callback = _startHdraw;
		break;
	}
	uint32_t when;
	if (state->versionMagic < 0x01000007) {
		// This field was moved in v7
		LOAD_32(when, 0, &state->audio.lastSample);
	} else {
		LOAD_32(when, 0, &state->video.nextEvent);
	}
	mTimingSchedule(&video->p->timing, &video->event, when);

	LOAD_16(video->vcount, GBA_REG_VCOUNT, state->io);
	video->renderer->reset(video->renderer);
}

/* ===== Imported from reference implementation/video-software.c ===== */
#define DIRTY_SCANLINE(R, Y) R->scanlineDirty[Y >> 5] |= (1U << (Y & 0x1F))
#define CLEAN_SCANLINE(R, Y) R->scanlineDirty[Y >> 5] &= ~(1U << (Y & 0x1F))
#define SOFTWARE_MAGIC 0x6E727773

static void GBAVideoSoftwareRendererInit(struct GBAVideoRenderer* renderer);
static void GBAVideoSoftwareRendererDeinit(struct GBAVideoRenderer* renderer);
static void GBAVideoSoftwareRendererReset(struct GBAVideoRenderer* renderer);
static uint32_t GBAVideoSoftwareRendererId(const struct GBAVideoRenderer* renderer);
static bool GBAVideoSoftwareRendererLoadState(struct GBAVideoRenderer* renderer, const void* state, size_t size);
static void GBAVideoSoftwareRendererSaveState(struct GBAVideoRenderer* renderer, void** state, size_t* size);
static void GBAVideoSoftwareRendererWriteVRAM(struct GBAVideoRenderer* renderer, uint32_t address);
static void GBAVideoSoftwareRendererWriteOAM(struct GBAVideoRenderer* renderer, uint32_t oam);
static void GBAVideoSoftwareRendererWritePalette(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value);
static uint16_t GBAVideoSoftwareRendererWriteVideoRegister(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value);
static void GBAVideoSoftwareRendererDrawScanline(struct GBAVideoRenderer* renderer, int y);
static void GBAVideoSoftwareRendererFinishFrame(struct GBAVideoRenderer* renderer);
static void GBAVideoSoftwareRendererGetPixels(struct GBAVideoRenderer* renderer, size_t* stride, const void** pixels);
static void GBAVideoSoftwareRendererPutPixels(struct GBAVideoRenderer* renderer, size_t stride, const void* pixels);

static void GBAVideoSoftwareRendererUpdateDISPCNT(struct GBAVideoSoftwareRenderer* renderer);
static void GBAVideoSoftwareRendererWriteBGCNT(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* bg, uint16_t value);
static void GBAVideoSoftwareRendererWriteBGX_LO(struct GBAVideoSoftwareBackground* bg, uint16_t value);
static void GBAVideoSoftwareRendererWriteBGX_HI(struct GBAVideoSoftwareBackground* bg, uint16_t value);
static void GBAVideoSoftwareRendererWriteBGY_LO(struct GBAVideoSoftwareBackground* bg, uint16_t value);
static void GBAVideoSoftwareRendererWriteBGY_HI(struct GBAVideoSoftwareBackground* bg, uint16_t value);
static void GBAVideoSoftwareRendererWriteBLDCNT(struct GBAVideoSoftwareRenderer* renderer, uint16_t value);

static void GBAVideoSoftwareRendererStepWindow(struct GBAVideoSoftwareRenderer* renderer, int y);
static void GBAVideoSoftwareRendererPreprocessBuffer(struct GBAVideoSoftwareRenderer* renderer);
static void GBAVideoSoftwareRendererPostprocessBuffer(struct GBAVideoSoftwareRenderer* renderer);
static int GBAVideoSoftwareRendererPreprocessSpriteLayer(struct GBAVideoSoftwareRenderer* renderer, int y);

static void _updatePalettes(struct GBAVideoSoftwareRenderer* renderer);
static void _updateFlags(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* bg);

static void _breakWindow(struct GBAVideoSoftwareRenderer* softwareRenderer, struct WindowN* win);
static void _breakWindowInner(struct GBAVideoSoftwareRenderer* softwareRenderer, struct WindowN* win);

void GBAVideoSoftwareRendererCreate(struct GBAVideoSoftwareRenderer* renderer) {
	memset(renderer, 0, sizeof(*renderer));
	renderer->d.init = GBAVideoSoftwareRendererInit;
	renderer->d.reset = GBAVideoSoftwareRendererReset;
	renderer->d.deinit = GBAVideoSoftwareRendererDeinit;
	renderer->d.rendererId = GBAVideoSoftwareRendererId;
	renderer->d.loadState = GBAVideoSoftwareRendererLoadState;
	renderer->d.saveState = GBAVideoSoftwareRendererSaveState;
	renderer->d.writeVideoRegister = GBAVideoSoftwareRendererWriteVideoRegister;
	renderer->d.writeVRAM = GBAVideoSoftwareRendererWriteVRAM;
	renderer->d.writeOAM = GBAVideoSoftwareRendererWriteOAM;
	renderer->d.writePalette = GBAVideoSoftwareRendererWritePalette;
	renderer->d.drawScanline = GBAVideoSoftwareRendererDrawScanline;
	renderer->d.finishFrame = GBAVideoSoftwareRendererFinishFrame;
	renderer->d.getPixels = GBAVideoSoftwareRendererGetPixels;
	renderer->d.putPixels = GBAVideoSoftwareRendererPutPixels;

	renderer->d.disableBG[0] = false;
	renderer->d.disableBG[1] = false;
	renderer->d.disableBG[2] = false;
	renderer->d.disableBG[3] = false;
	renderer->d.disableOBJ = false;
	renderer->d.disableWIN[0] = false;
	renderer->d.disableWIN[1] = false;
	renderer->d.disableOBJWIN = false;

	renderer->d.highlightBG[0] = false;
	renderer->d.highlightBG[1] = false;
	renderer->d.highlightBG[2] = false;
	renderer->d.highlightBG[3] = false;
	int i;
	for (i = 0; i < 128; ++i) {
		renderer->d.highlightOBJ[i] = false;
	}
	renderer->d.highlightColor = M_COLOR_WHITE;
	renderer->d.highlightAmount = 0;

	renderer->temporaryBuffer = NULL;
}

static void GBAVideoSoftwareRendererInit(struct GBAVideoRenderer* renderer) {
	GBAVideoSoftwareRendererReset(renderer);

	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;

	int y;
	for (y = 0; y < GBA_VIDEO_VERTICAL_PIXELS; ++y) {
		mColor* row = &softwareRenderer->outputBuffer[softwareRenderer->outputBufferStride * y];
		int x;
		for (x = 0; x < GBA_VIDEO_HORIZONTAL_PIXELS; ++x) {
			row[x] = M_COLOR_WHITE;
		}
	}
}

static void GBAVideoSoftwareRendererReset(struct GBAVideoRenderer* renderer) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;
	int i;

	softwareRenderer->dispcnt = 0x0080;

	softwareRenderer->target1Obj = 0;
	softwareRenderer->target1Bd = 0;
	softwareRenderer->target2Obj = 0;
	softwareRenderer->target2Bd = 0;
	softwareRenderer->blendEffect = BLEND_NONE;
	for (i = 0; i < 1024; i += 2) {
		uint16_t entry;
		LOAD_16(entry, i, softwareRenderer->d.palette);
		GBAVideoSoftwareRendererWritePalette(renderer, i, entry);
	}
	softwareRenderer->blendDirty = false;
	_updatePalettes(softwareRenderer);

	softwareRenderer->blda = 0;
	softwareRenderer->bldb = 0;
	softwareRenderer->bldy = 0;

	softwareRenderer->winN[0] = (struct WindowN) { .control = { .priority = 0 } };
	softwareRenderer->winN[1] = (struct WindowN) { .control = { .priority = 1 } };
	softwareRenderer->objwin = (struct WindowControl) { .priority = 2 };
	softwareRenderer->winout = (struct WindowControl) { .priority = 3 };
	softwareRenderer->oamDirty = 1;
	softwareRenderer->oamMax = 0;

	softwareRenderer->mosaic = 0;
	softwareRenderer->stereo = false;
	softwareRenderer->nextY = 0;

	softwareRenderer->objOffsetX = 0;
	softwareRenderer->objOffsetY = 0;

	memset(softwareRenderer->scanlineDirty, 0xFFFFFFFF, sizeof(softwareRenderer->scanlineDirty));
	memset(softwareRenderer->cache, 0, sizeof(softwareRenderer->cache));
	memset(softwareRenderer->nextIo, 0, sizeof(softwareRenderer->nextIo));

	softwareRenderer->lastHighlightAmount = 0;

	for (i = 0; i < 4; ++i) {
		struct GBAVideoSoftwareBackground* bg = &softwareRenderer->bg[i];
		memset(bg, 0, sizeof(*bg));
		bg->index = i;
		bg->dx = 256;
		bg->dmy = 256;
		bg->yCache = -1;
	}
}

static void GBAVideoSoftwareRendererDeinit(struct GBAVideoRenderer* renderer) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;
	UNUSED(softwareRenderer);
}

static uint32_t GBAVideoSoftwareRendererId(const struct GBAVideoRenderer* renderer) {
	UNUSED(renderer);
	return SOFTWARE_MAGIC;
}

static bool GBAVideoSoftwareRendererLoadState(struct GBAVideoRenderer* renderer, const void* state, size_t size) {
	UNUSED(renderer);
	UNUSED(state);
	UNUSED(size);
	// TODO
	return false;
}

static void GBAVideoSoftwareRendererSaveState(struct GBAVideoRenderer* renderer, void** state, size_t* size) {
	UNUSED(renderer);
	*state = NULL;
	*size = 0;
	// TODO
}

static uint16_t GBAVideoSoftwareRendererWriteVideoRegister(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;
	if (renderer->cache) {
		GBAVideoCacheWriteVideoRegister(renderer->cache, address, value);
	}

	switch (address) {
	case GBA_REG_DISPCNT:
		value &= 0xFFF7;
		softwareRenderer->dispcnt = value;
		GBAVideoSoftwareRendererUpdateDISPCNT(softwareRenderer);
		break;
	case GBA_REG_STEREOCNT:
		softwareRenderer->stereo = value & 1;
		break;
	case GBA_REG_BG0CNT:
		value &= 0xDFFF;
		GBAVideoSoftwareRendererWriteBGCNT(softwareRenderer, &softwareRenderer->bg[0], value);
		break;
	case GBA_REG_BG1CNT:
		value &= 0xDFFF;
		GBAVideoSoftwareRendererWriteBGCNT(softwareRenderer, &softwareRenderer->bg[1], value);
		break;
	case GBA_REG_BG2CNT:
		value &= 0xFFFF;
		GBAVideoSoftwareRendererWriteBGCNT(softwareRenderer, &softwareRenderer->bg[2], value);
		break;
	case GBA_REG_BG3CNT:
		value &= 0xFFFF;
		GBAVideoSoftwareRendererWriteBGCNT(softwareRenderer, &softwareRenderer->bg[3], value);
		break;
	case GBA_REG_BG0HOFS:
		value &= 0x01FF;
		softwareRenderer->bg[0].x = value;
		break;
	case GBA_REG_BG0VOFS:
		value &= 0x01FF;
		softwareRenderer->bg[0].y = value;
		break;
	case GBA_REG_BG1HOFS:
		value &= 0x01FF;
		softwareRenderer->bg[1].x = value;
		break;
	case GBA_REG_BG1VOFS:
		value &= 0x01FF;
		softwareRenderer->bg[1].y = value;
		break;
	case GBA_REG_BG2HOFS:
		value &= 0x01FF;
		softwareRenderer->bg[2].x = value;
		break;
	case GBA_REG_BG2VOFS:
		value &= 0x01FF;
		softwareRenderer->bg[2].y = value;
		break;
	case GBA_REG_BG3HOFS:
		value &= 0x01FF;
		softwareRenderer->bg[3].x = value;
		break;
	case GBA_REG_BG3VOFS:
		value &= 0x01FF;
		softwareRenderer->bg[3].y = value;
		break;
	case GBA_REG_BG2PA:
		softwareRenderer->bg[2].dx = value;
		break;
	case GBA_REG_BG2PB:
		softwareRenderer->bg[2].dmx = value;
		break;
	case GBA_REG_BG2PC:
		softwareRenderer->bg[2].dy = value;
		break;
	case GBA_REG_BG2PD:
		softwareRenderer->bg[2].dmy = value;
		break;
	case GBA_REG_BG2X_LO:
		GBAVideoSoftwareRendererWriteBGX_LO(&softwareRenderer->bg[2], value);
		if (softwareRenderer->bg[2].sx != softwareRenderer->cache[softwareRenderer->nextY].scale[0][0]) {
			DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
		}
		break;
	case GBA_REG_BG2X_HI:
		GBAVideoSoftwareRendererWriteBGX_HI(&softwareRenderer->bg[2], value);
		if (softwareRenderer->bg[2].sx != softwareRenderer->cache[softwareRenderer->nextY].scale[0][0]) {
			DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
		}
		break;
	case GBA_REG_BG2Y_LO:
		GBAVideoSoftwareRendererWriteBGY_LO(&softwareRenderer->bg[2], value);
		if (softwareRenderer->bg[2].sy != softwareRenderer->cache[softwareRenderer->nextY].scale[0][1]) {
			DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
		}
		break;
	case GBA_REG_BG2Y_HI:
		GBAVideoSoftwareRendererWriteBGY_HI(&softwareRenderer->bg[2], value);
		if (softwareRenderer->bg[2].sy != softwareRenderer->cache[softwareRenderer->nextY].scale[0][1]) {
			DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
		}
		break;
	case GBA_REG_BG3PA:
		softwareRenderer->bg[3].dx = value;
		break;
	case GBA_REG_BG3PB:
		softwareRenderer->bg[3].dmx = value;
		break;
	case GBA_REG_BG3PC:
		softwareRenderer->bg[3].dy = value;
		break;
	case GBA_REG_BG3PD:
		softwareRenderer->bg[3].dmy = value;
		break;
	case GBA_REG_BG3X_LO:
		GBAVideoSoftwareRendererWriteBGX_LO(&softwareRenderer->bg[3], value);
		if (softwareRenderer->bg[3].sx != softwareRenderer->cache[softwareRenderer->nextY].scale[1][0]) {
			DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
		}
		break;
	case GBA_REG_BG3X_HI:
		GBAVideoSoftwareRendererWriteBGX_HI(&softwareRenderer->bg[3], value);
		if (softwareRenderer->bg[3].sx != softwareRenderer->cache[softwareRenderer->nextY].scale[1][0]) {
			DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
		}
		break;
	case GBA_REG_BG3Y_LO:
		GBAVideoSoftwareRendererWriteBGY_LO(&softwareRenderer->bg[3], value);
		if (softwareRenderer->bg[3].sy != softwareRenderer->cache[softwareRenderer->nextY].scale[1][1]) {
			DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
		}
		break;
	case GBA_REG_BG3Y_HI:
		GBAVideoSoftwareRendererWriteBGY_HI(&softwareRenderer->bg[3], value);
		if (softwareRenderer->bg[3].sy != softwareRenderer->cache[softwareRenderer->nextY].scale[1][1]) {
			DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
		}
		break;
	case GBA_REG_BLDCNT:
		GBAVideoSoftwareRendererWriteBLDCNT(softwareRenderer, value);
		value &= 0x3FFF;
		break;
	case GBA_REG_BLDALPHA:
		softwareRenderer->blda = value & 0x1F;
		if (softwareRenderer->blda > 0x10) {
			softwareRenderer->blda = 0x10;
		}
		softwareRenderer->bldb = (value >> 8) & 0x1F;
		if (softwareRenderer->bldb > 0x10) {
			softwareRenderer->bldb = 0x10;
		}
		value &= 0x1F1F;
		break;
	case GBA_REG_BLDY:
		value &= 0x1F;
		if (value > 0x10) {
			value = 0x10;
		}
		if (softwareRenderer->bldy != value) {
			softwareRenderer->bldy = value;
			softwareRenderer->blendDirty = true;
		}
		break;
	case GBA_REG_WIN0H:
		softwareRenderer->winN[0].h.end = value;
		softwareRenderer->winN[0].h.start = value >> 8;
		if (softwareRenderer->winN[0].h.start > GBA_VIDEO_HORIZONTAL_PIXELS && softwareRenderer->winN[0].h.start > softwareRenderer->winN[0].h.end) {
			softwareRenderer->winN[0].h.start = 0;
		}
		if (softwareRenderer->winN[0].h.end > GBA_VIDEO_HORIZONTAL_PIXELS) {
			softwareRenderer->winN[0].h.end = GBA_VIDEO_HORIZONTAL_PIXELS;
			if (softwareRenderer->winN[0].h.start > GBA_VIDEO_HORIZONTAL_PIXELS) {
				softwareRenderer->winN[0].h.start = GBA_VIDEO_HORIZONTAL_PIXELS;
			}
		}
		break;
	case GBA_REG_WIN1H:
		softwareRenderer->winN[1].h.end = value;
		softwareRenderer->winN[1].h.start = value >> 8;
		if (softwareRenderer->winN[1].h.start > GBA_VIDEO_HORIZONTAL_PIXELS && softwareRenderer->winN[1].h.start > softwareRenderer->winN[1].h.end) {
			softwareRenderer->winN[1].h.start = 0;
		}
		if (softwareRenderer->winN[1].h.end > GBA_VIDEO_HORIZONTAL_PIXELS) {
			softwareRenderer->winN[1].h.end = GBA_VIDEO_HORIZONTAL_PIXELS;
			if (softwareRenderer->winN[1].h.start > GBA_VIDEO_HORIZONTAL_PIXELS) {
				softwareRenderer->winN[1].h.start = GBA_VIDEO_HORIZONTAL_PIXELS;
			}
		}
		break;
	case GBA_REG_WIN0V:
		softwareRenderer->winN[0].v.end = value;
		softwareRenderer->winN[0].v.start = value >> 8;
		break;
	case GBA_REG_WIN1V:
		softwareRenderer->winN[1].v.end = value;
		softwareRenderer->winN[1].v.start = value >> 8;
		break;
	case GBA_REG_WININ:
		value &= 0x3F3F;
		softwareRenderer->winN[0].control.packed = value;
		softwareRenderer->winN[1].control.packed = value >> 8;
		break;
	case GBA_REG_WINOUT:
		value &= 0x3F3F;
		softwareRenderer->winout.packed = value;
		softwareRenderer->objwin.packed = value >> 8;
		break;
	case GBA_REG_MOSAIC:
		softwareRenderer->mosaic = value;
		break;
	default:
		mLOG(GBA_VIDEO, GAME_ERROR, "Invalid video register: 0x%03X", address);
	}
	softwareRenderer->nextIo[address >> 1] = value;
	if (softwareRenderer->cache[softwareRenderer->nextY].io[address >> 1] != value) {
		softwareRenderer->cache[softwareRenderer->nextY].io[address >> 1] = value;
		DIRTY_SCANLINE(softwareRenderer, softwareRenderer->nextY);
	}
	return value;
}

static void GBAVideoSoftwareRendererWriteVRAM(struct GBAVideoRenderer* renderer, uint32_t address) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;
	if (renderer->cache) {
		mCacheSetWriteVRAM(renderer->cache, address);
	}
	memset(softwareRenderer->scanlineDirty, 0xFFFFFFFF, sizeof(softwareRenderer->scanlineDirty));
	softwareRenderer->bg[0].yCache = -1;
	softwareRenderer->bg[1].yCache = -1;
	softwareRenderer->bg[2].yCache = -1;
	softwareRenderer->bg[3].yCache = -1;
}

static void GBAVideoSoftwareRendererWriteOAM(struct GBAVideoRenderer* renderer, uint32_t oam) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;
	UNUSED(oam);
	softwareRenderer->oamDirty = 1;
	memset(softwareRenderer->scanlineDirty, 0xFFFFFFFF, sizeof(softwareRenderer->scanlineDirty));
}

static void GBAVideoSoftwareRendererWritePalette(struct GBAVideoRenderer* renderer, uint32_t address, uint16_t value) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;
	mColor color = mColorFrom555(value);
	softwareRenderer->normalPalette[address >> 1] = color;
	if (softwareRenderer->blendEffect == BLEND_BRIGHTEN) {
		softwareRenderer->variantPalette[address >> 1] = _brighten(color, softwareRenderer->bldy);
	} else if (softwareRenderer->blendEffect == BLEND_DARKEN) {
		softwareRenderer->variantPalette[address >> 1] = _darken(color, softwareRenderer->bldy);
	}
	int highlightAmount = renderer->highlightAmount >> 4;
	if (highlightAmount) {
		softwareRenderer->highlightPalette[address >> 1] = mColorMix5Bit(0x10 - highlightAmount, softwareRenderer->normalPalette[address >> 1], highlightAmount, renderer->highlightColor);
		softwareRenderer->highlightVariantPalette[address >> 1] = mColorMix5Bit(0x10 - highlightAmount, softwareRenderer->variantPalette[address >> 1], highlightAmount, renderer->highlightColor);
	} else {
		softwareRenderer->highlightPalette[address >> 1] = softwareRenderer->normalPalette[address >> 1];
		softwareRenderer->highlightVariantPalette[address >> 1] = softwareRenderer->variantPalette[address >> 1];
	}
	if (renderer->cache) {
		mCacheSetWritePalette(renderer->cache, address >> 1, color);
	}
	memset(softwareRenderer->scanlineDirty, 0xFFFFFFFF, sizeof(softwareRenderer->scanlineDirty));
}

static void _breakWindow(struct GBAVideoSoftwareRenderer* softwareRenderer, struct WindowN* win) {
	if (win->h.end > GBA_VIDEO_HORIZONTAL_PIXELS || win->h.end < win->h.start) {
		struct WindowN splits[2] = { *win, *win };
		splits[0].h.start = 0;
		splits[1].h.end = GBA_VIDEO_HORIZONTAL_PIXELS;
		_breakWindowInner(softwareRenderer, &splits[0]);
		_breakWindowInner(softwareRenderer, &splits[1]);
	} else {
		_breakWindowInner(softwareRenderer, win);
	}
}

static void _breakWindowInner(struct GBAVideoSoftwareRenderer* softwareRenderer, struct WindowN* win) {
	int activeWindow;
	int startX = 0;
	if (win->h.end > 0) {
		for (activeWindow = 0; activeWindow < softwareRenderer->nWindows; ++activeWindow) {
			if (win->h.start < softwareRenderer->windows[activeWindow].endX) {
				// Insert a window before the end of the active window
				struct Window oldWindow = softwareRenderer->windows[activeWindow];
				if (win->h.start > startX) {
					// And after the start of the active window
					int nextWindow = softwareRenderer->nWindows;
					++softwareRenderer->nWindows;
					for (; nextWindow > activeWindow; --nextWindow) {
						softwareRenderer->windows[nextWindow] = softwareRenderer->windows[nextWindow - 1];
					}
					softwareRenderer->windows[activeWindow].endX = win->h.start;
					++activeWindow;
				}
				softwareRenderer->windows[activeWindow].control = win->control;
				softwareRenderer->windows[activeWindow].endX = win->h.end;
				if (win->h.end >= oldWindow.endX) {
					// Trim off extra windows we've overwritten
					for (++activeWindow; softwareRenderer->nWindows > activeWindow + 1 && win->h.end >= softwareRenderer->windows[activeWindow].endX; ++activeWindow) {
						if (VIDEO_CHECKS && activeWindow >= MAX_WINDOW) {
							mLOG(GBA_VIDEO, FATAL, "Out of bounds window write will occur");
							return;
						}
						softwareRenderer->windows[activeWindow] = softwareRenderer->windows[activeWindow + 1];
						--softwareRenderer->nWindows;
					}
				} else {
					++activeWindow;
					int nextWindow = softwareRenderer->nWindows;
					++softwareRenderer->nWindows;
					for (; nextWindow > activeWindow; --nextWindow) {
						softwareRenderer->windows[nextWindow] = softwareRenderer->windows[nextWindow - 1];
					}
					softwareRenderer->windows[activeWindow] = oldWindow;
				}
				break;
			}
			startX = softwareRenderer->windows[activeWindow].endX;
		}
	}
#ifdef DEBUG
	if (softwareRenderer->nWindows > MAX_WINDOW) {
		mLOG(GBA_VIDEO, FATAL, "Out of bounds window write occurred!");
	}
#endif
}

static void GBAVideoSoftwareRendererPrepareWindow(struct GBAVideoSoftwareRenderer* renderer) {
	int objwinSlowPath = GBARegisterDISPCNTIsObjwinEnable(renderer->dispcnt);
	if (objwinSlowPath) {
		renderer->bg[0].objwinForceEnable = GBAWindowControlIsBg0Enable(renderer->objwin.packed) &&
		    GBAWindowControlIsBg0Enable(renderer->currentWindow.packed);
		renderer->bg[0].objwinOnly = !GBAWindowControlIsBg0Enable(renderer->objwin.packed);
		renderer->bg[1].objwinForceEnable = GBAWindowControlIsBg1Enable(renderer->objwin.packed) &&
		    GBAWindowControlIsBg1Enable(renderer->currentWindow.packed);
		renderer->bg[1].objwinOnly = !GBAWindowControlIsBg1Enable(renderer->objwin.packed);
		renderer->bg[2].objwinForceEnable = GBAWindowControlIsBg2Enable(renderer->objwin.packed) &&
		    GBAWindowControlIsBg2Enable(renderer->currentWindow.packed);
		renderer->bg[2].objwinOnly = !GBAWindowControlIsBg2Enable(renderer->objwin.packed);
		renderer->bg[3].objwinForceEnable = GBAWindowControlIsBg3Enable(renderer->objwin.packed) &&
		    GBAWindowControlIsBg3Enable(renderer->currentWindow.packed);
		renderer->bg[3].objwinOnly = !GBAWindowControlIsBg3Enable(renderer->objwin.packed);
	}

	switch (GBARegisterDISPCNTGetMode(renderer->dispcnt)) {
	case 0:
		if (renderer->bg[0].enabled == ENABLED_MAX) {
			_updateFlags(renderer, &renderer->bg[0]);
		}
		if (renderer->bg[1].enabled == ENABLED_MAX) {
			_updateFlags(renderer, &renderer->bg[1]);
		}
		// Fall through
	case 2:
		if (renderer->bg[3].enabled == ENABLED_MAX) {
			_updateFlags(renderer, &renderer->bg[3]);
		}
		// Fall through
	case 3:
	case 4:
	case 5:
		if (renderer->bg[2].enabled == ENABLED_MAX) {
			_updateFlags(renderer, &renderer->bg[2]);
		}
		break;
	case 1:
		if (renderer->bg[0].enabled == ENABLED_MAX) {
			_updateFlags(renderer, &renderer->bg[0]);
		}
		if (renderer->bg[1].enabled == ENABLED_MAX) {
			_updateFlags(renderer, &renderer->bg[1]);
		}
		if (renderer->bg[2].enabled == ENABLED_MAX) {
			_updateFlags(renderer, &renderer->bg[2]);
		}
		break;
	}
}

static void GBAVideoSoftwareRendererDrawScanline(struct GBAVideoRenderer* renderer, int y) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;

	if (y == GBA_VIDEO_VERTICAL_PIXELS - 1) {
		softwareRenderer->nextY = 0;
	} else {
		softwareRenderer->nextY = y + 1;
	}

	bool dirty = softwareRenderer->scanlineDirty[y >> 5] & (1U << (y & 0x1F));
	if (memcmp(softwareRenderer->nextIo, softwareRenderer->cache[y].io, sizeof(softwareRenderer->nextIo))) {
		memcpy(softwareRenderer->cache[y].io, softwareRenderer->nextIo, sizeof(softwareRenderer->nextIo));
		dirty = true;
	}

	if (GBARegisterDISPCNTGetMode(softwareRenderer->dispcnt) != 0) {
		if (softwareRenderer->cache[y].scale[0][0] != softwareRenderer->bg[2].sx ||
		    softwareRenderer->cache[y].scale[0][1] != softwareRenderer->bg[2].sy ||
		    softwareRenderer->cache[y].scale[1][0] != softwareRenderer->bg[3].sx ||
		    softwareRenderer->cache[y].scale[1][1] != softwareRenderer->bg[3].sy) {
			dirty = true;
		}
	}
	softwareRenderer->cache[y].scale[0][0] = softwareRenderer->bg[2].sx;
	softwareRenderer->cache[y].scale[0][1] = softwareRenderer->bg[2].sy;
	softwareRenderer->cache[y].scale[1][0] = softwareRenderer->bg[3].sx;
	softwareRenderer->cache[y].scale[1][1] = softwareRenderer->bg[3].sy;

	GBAVideoSoftwareRendererStepWindow(softwareRenderer, y);
	if (softwareRenderer->cache[y].windowOn[0] != softwareRenderer->winN[0].on ||
	    softwareRenderer->cache[y].windowOn[1] != softwareRenderer->winN[1].on) {
		dirty = true;
	}
	softwareRenderer->cache[y].windowOn[0] = softwareRenderer->winN[0].on;
	softwareRenderer->cache[y].windowOn[1] = softwareRenderer->winN[1].on;

	if (!dirty) {
		if (GBARegisterDISPCNTGetMode(softwareRenderer->dispcnt) != 0) {
			if (softwareRenderer->bg[2].enabled == ENABLED_MAX) {
				softwareRenderer->bg[2].sx += softwareRenderer->bg[2].dmx;
				softwareRenderer->bg[2].sy += softwareRenderer->bg[2].dmy;
			}
			if (softwareRenderer->bg[3].enabled == ENABLED_MAX) {
				softwareRenderer->bg[3].sx += softwareRenderer->bg[3].dmx;
				softwareRenderer->bg[3].sy += softwareRenderer->bg[3].dmy;
			}
		}
		return;
	}

	CLEAN_SCANLINE(softwareRenderer, y);

	mColor* row = &softwareRenderer->outputBuffer[softwareRenderer->outputBufferStride * y];
	if (GBARegisterDISPCNTIsForcedBlank(softwareRenderer->dispcnt)) {
		int x;
		for (x = 0; x < GBA_VIDEO_HORIZONTAL_PIXELS; ++x) {
			row[x] = M_COLOR_WHITE;
		}
		return;
	}

	GBAVideoSoftwareRendererPreprocessBuffer(softwareRenderer);
	softwareRenderer->spriteCyclesRemaining = GBARegisterDISPCNTIsHblankIntervalFree(softwareRenderer->dispcnt) ? OBJ_HBLANK_FREE_LENGTH : OBJ_LENGTH;
	int spriteLayers = GBAVideoSoftwareRendererPreprocessSpriteLayer(softwareRenderer, y);

	int w;
	unsigned priority;
	softwareRenderer->end = 0;
	for (w = 0; w < softwareRenderer->nWindows; ++w) {
		softwareRenderer->start = softwareRenderer->end;
		softwareRenderer->end = softwareRenderer->windows[w].endX;
		softwareRenderer->currentWindow = softwareRenderer->windows[w].control;
		GBAVideoSoftwareRendererPrepareWindow(softwareRenderer);
		for (priority = 0; priority < 4; ++priority) {
			if (spriteLayers & (1 << priority)) {
				GBAVideoSoftwareRendererPostprocessSprite(softwareRenderer, priority);
			}
			if (TEST_LAYER_ENABLED(0) && GBARegisterDISPCNTGetMode(softwareRenderer->dispcnt) < 2) {
				GBAVideoSoftwareRendererDrawBackgroundMode0(softwareRenderer, &softwareRenderer->bg[0], y);
			}
			if (TEST_LAYER_ENABLED(1) && GBARegisterDISPCNTGetMode(softwareRenderer->dispcnt) < 2) {
				GBAVideoSoftwareRendererDrawBackgroundMode0(softwareRenderer, &softwareRenderer->bg[1], y);
			}
			if (TEST_LAYER_ENABLED(2)) {
				switch (GBARegisterDISPCNTGetMode(softwareRenderer->dispcnt)) {
				case 0:
					GBAVideoSoftwareRendererDrawBackgroundMode0(softwareRenderer, &softwareRenderer->bg[2], y);
					break;
				case 1:
				case 2:
					GBAVideoSoftwareRendererDrawBackgroundMode2(softwareRenderer, &softwareRenderer->bg[2], y);
					break;
				case 3:
					GBAVideoSoftwareRendererDrawBackgroundMode3(softwareRenderer, &softwareRenderer->bg[2], y);
					break;
				case 4:
					GBAVideoSoftwareRendererDrawBackgroundMode4(softwareRenderer, &softwareRenderer->bg[2], y);
					break;
				case 5:
					GBAVideoSoftwareRendererDrawBackgroundMode5(softwareRenderer, &softwareRenderer->bg[2], y);
					break;
				}
			}
			if (TEST_LAYER_ENABLED(3)) {
				switch (GBARegisterDISPCNTGetMode(softwareRenderer->dispcnt)) {
				case 0:
					GBAVideoSoftwareRendererDrawBackgroundMode0(softwareRenderer, &softwareRenderer->bg[3], y);
					break;
				case 2:
					GBAVideoSoftwareRendererDrawBackgroundMode2(softwareRenderer, &softwareRenderer->bg[3], y);
					break;
				}
			}
		}
	}

	GBAVideoSoftwareRendererPostprocessBuffer(softwareRenderer);

	if (GBARegisterDISPCNTGetMode(softwareRenderer->dispcnt) != 0) {
		if (softwareRenderer->bg[2].enabled == ENABLED_MAX) {
			softwareRenderer->bg[2].sx += softwareRenderer->bg[2].dmx;
			softwareRenderer->bg[2].sy += softwareRenderer->bg[2].dmy;
		}
		if (softwareRenderer->bg[3].enabled == ENABLED_MAX) {
			softwareRenderer->bg[3].sx += softwareRenderer->bg[3].dmx;
			softwareRenderer->bg[3].sy += softwareRenderer->bg[3].dmy;
		}
	}

	if (softwareRenderer->bg[0].enabled != 0 && softwareRenderer->bg[0].enabled < ENABLED_MAX) {
		++softwareRenderer->bg[0].enabled;
		DIRTY_SCANLINE(softwareRenderer, y);
	}
	if (softwareRenderer->bg[1].enabled != 0 && softwareRenderer->bg[1].enabled < ENABLED_MAX) {
		++softwareRenderer->bg[1].enabled;
		DIRTY_SCANLINE(softwareRenderer, y);
	}
	if (softwareRenderer->bg[2].enabled != 0 && softwareRenderer->bg[2].enabled < ENABLED_MAX) {
		++softwareRenderer->bg[2].enabled;
		DIRTY_SCANLINE(softwareRenderer, y);
	}
	if (softwareRenderer->bg[3].enabled != 0 && softwareRenderer->bg[3].enabled < ENABLED_MAX) {
		++softwareRenderer->bg[3].enabled;
		DIRTY_SCANLINE(softwareRenderer, y);
	}

	int x;
	if (softwareRenderer->stereo) {
		for (x = 0; x < GBA_VIDEO_HORIZONTAL_PIXELS; x += 4) {
			row[x] = softwareRenderer->row[x] & (M_COLOR_RED | M_COLOR_BLUE);
			row[x] |= softwareRenderer->row[x + 1] & M_COLOR_GREEN;
			row[x + 1] = softwareRenderer->row[x + 1] & (M_COLOR_RED | M_COLOR_BLUE);
			row[x + 1] |= softwareRenderer->row[x] & M_COLOR_GREEN;
			row[x + 2] = softwareRenderer->row[x + 2] & (M_COLOR_RED | M_COLOR_BLUE);
			row[x + 2] |= softwareRenderer->row[x + 3] & M_COLOR_GREEN;
			row[x + 3] = softwareRenderer->row[x + 3] & (M_COLOR_RED | M_COLOR_BLUE);
			row[x + 3] |= softwareRenderer->row[x + 2] & M_COLOR_GREEN;

		}
	} else {
#ifdef COLOR_16_BIT
		for (x = 0; x < GBA_VIDEO_HORIZONTAL_PIXELS; x += 4) {
			row[x] = softwareRenderer->row[x];
			row[x + 1] = softwareRenderer->row[x + 1];
			row[x + 2] = softwareRenderer->row[x + 2];
			row[x + 3] = softwareRenderer->row[x + 3];
		}
#else
		memcpy(row, softwareRenderer->row, GBA_VIDEO_HORIZONTAL_PIXELS * sizeof(*row));
#endif
	}
}

static void GBAVideoSoftwareRendererFinishFrame(struct GBAVideoRenderer* renderer) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;

	softwareRenderer->nextY = 0;
	if (softwareRenderer->temporaryBuffer) {
		mappedMemoryFree(softwareRenderer->temporaryBuffer, GBA_VIDEO_HORIZONTAL_PIXELS * GBA_VIDEO_VERTICAL_PIXELS * 4);
		softwareRenderer->temporaryBuffer = 0;
	}
	softwareRenderer->bg[2].sx = softwareRenderer->bg[2].refx;
	softwareRenderer->bg[2].sy = softwareRenderer->bg[2].refy;
	softwareRenderer->bg[3].sx = softwareRenderer->bg[3].refx;
	softwareRenderer->bg[3].sy = softwareRenderer->bg[3].refy;

	if (softwareRenderer->bg[0].enabled > 0) {
		softwareRenderer->bg[0].enabled = ENABLED_MAX;
	}
	if (softwareRenderer->bg[1].enabled > 0) {
		softwareRenderer->bg[1].enabled = ENABLED_MAX;
	}
	if (softwareRenderer->bg[2].enabled > 0) {
		softwareRenderer->bg[2].enabled = ENABLED_MAX;
	}
	if (softwareRenderer->bg[3].enabled > 0) {
		softwareRenderer->bg[3].enabled = ENABLED_MAX;
	}

	int i;
	for (i = 0; i < 2; ++i) {
		struct WindowN* win = &softwareRenderer->winN[i];
		if (win->v.end >= GBA_VIDEO_VERTICAL_PIXELS && win->v.end < VIDEO_VERTICAL_TOTAL_PIXELS) {
			win->on = false;
		}

		if (win->v.start >= GBA_VIDEO_VERTICAL_PIXELS &&
		    win->v.start < VIDEO_VERTICAL_TOTAL_PIXELS &&
		    win->v.start > win->v.end) {
			win->on = true;
		}
	}
}

static void GBAVideoSoftwareRendererGetPixels(struct GBAVideoRenderer* renderer, size_t* stride, const void** pixels) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;
	*stride = softwareRenderer->outputBufferStride;
	*pixels = softwareRenderer->outputBuffer;
}

static void GBAVideoSoftwareRendererPutPixels(struct GBAVideoRenderer* renderer, size_t stride, const void* pixels) {
	struct GBAVideoSoftwareRenderer* softwareRenderer = (struct GBAVideoSoftwareRenderer*) renderer;

	const mColor* colorPixels = pixels;
	unsigned i;
	for (i = 0; i < GBA_VIDEO_VERTICAL_PIXELS; ++i) {
		memmove(&softwareRenderer->outputBuffer[softwareRenderer->outputBufferStride * i], &colorPixels[stride * i], GBA_VIDEO_HORIZONTAL_PIXELS * BYTES_PER_PIXEL);
	}
}

static void _enableBg(struct GBAVideoSoftwareRenderer* renderer, int bg, bool active) {
	int wasActive = renderer->bg[bg].enabled;
	if (!active) {
		if (renderer->nextY == 0 || (wasActive > 0 && wasActive < ENABLED_MAX)) {
			renderer->bg[bg].enabled = 0;
		} else if (wasActive == ENABLED_MAX) {
			renderer->bg[bg].enabled = -2;
		}
	} else if (!wasActive && active) {
		if (renderer->nextY == 0) {
			// TODO: Investigate in more depth how switching background works in different modes
			renderer->bg[bg].enabled = ENABLED_MAX;
		} else if (GBARegisterDISPCNTGetMode(renderer->dispcnt) > 2) {
			renderer->bg[bg].enabled = 2;
		} else {
			renderer->bg[bg].enabled = 1;
		}
	} else if (wasActive < 0 && active) {
		renderer->bg[bg].enabled = ENABLED_MAX;
	}
}

static void GBAVideoSoftwareRendererUpdateDISPCNT(struct GBAVideoSoftwareRenderer* renderer) {
	_enableBg(renderer, 0, GBARegisterDISPCNTGetBg0Enable(renderer->dispcnt));
	_enableBg(renderer, 1, GBARegisterDISPCNTGetBg1Enable(renderer->dispcnt));
	_enableBg(renderer, 2, GBARegisterDISPCNTGetBg2Enable(renderer->dispcnt));
	_enableBg(renderer, 3, GBARegisterDISPCNTGetBg3Enable(renderer->dispcnt));
}

static void GBAVideoSoftwareRendererWriteBGCNT(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* bg, uint16_t value) {
	UNUSED(renderer);
	bg->priority = GBARegisterBGCNTGetPriority(value);
	bg->charBase = GBARegisterBGCNTGetCharBase(value) << 14;
	bg->mosaic = GBARegisterBGCNTGetMosaic(value);
	bg->multipalette = GBARegisterBGCNTGet256Color(value);
	bg->screenBase = GBARegisterBGCNTGetScreenBase(value) << 11;
	bg->overflow = GBARegisterBGCNTGetOverflow(value);
	bg->size = GBARegisterBGCNTGetSize(value);
	bg->yCache = -1;

	_updateFlags(renderer, bg);
}

static void GBAVideoSoftwareRendererWriteBGX_LO(struct GBAVideoSoftwareBackground* bg, uint16_t value) {
	bg->refx = (bg->refx & 0xFFFF0000) | value;
	bg->sx = bg->refx;
}

static void GBAVideoSoftwareRendererWriteBGX_HI(struct GBAVideoSoftwareBackground* bg, uint16_t value) {
	bg->refx = (bg->refx & 0x0000FFFF) | (value << 16);
	bg->refx <<= 4;
	bg->refx >>= 4;
	bg->sx = bg->refx;
}

static void GBAVideoSoftwareRendererWriteBGY_LO(struct GBAVideoSoftwareBackground* bg, uint16_t value) {
	bg->refy = (bg->refy & 0xFFFF0000) | value;
	bg->sy = bg->refy;
}

static void GBAVideoSoftwareRendererWriteBGY_HI(struct GBAVideoSoftwareBackground* bg, uint16_t value) {
	bg->refy = (bg->refy & 0x0000FFFF) | (value << 16);
	bg->refy <<= 4;
	bg->refy >>= 4;
	bg->sy = bg->refy;
}

static void GBAVideoSoftwareRendererWriteBLDCNT(struct GBAVideoSoftwareRenderer* renderer, uint16_t value) {
	enum GBAVideoBlendEffect oldEffect = renderer->blendEffect;

	renderer->bg[0].target1 = GBARegisterBLDCNTGetTarget1Bg0(value);
	renderer->bg[1].target1 = GBARegisterBLDCNTGetTarget1Bg1(value);
	renderer->bg[2].target1 = GBARegisterBLDCNTGetTarget1Bg2(value);
	renderer->bg[3].target1 = GBARegisterBLDCNTGetTarget1Bg3(value);
	renderer->bg[0].target2 = GBARegisterBLDCNTGetTarget2Bg0(value);
	renderer->bg[1].target2 = GBARegisterBLDCNTGetTarget2Bg1(value);
	renderer->bg[2].target2 = GBARegisterBLDCNTGetTarget2Bg2(value);
	renderer->bg[3].target2 = GBARegisterBLDCNTGetTarget2Bg3(value);

	renderer->blendEffect = GBARegisterBLDCNTGetEffect(value);
	renderer->target1Obj = GBARegisterBLDCNTGetTarget1Obj(value);
	renderer->target1Bd = GBARegisterBLDCNTGetTarget1Bd(value);
	renderer->target2Obj = GBARegisterBLDCNTGetTarget2Obj(value);
	renderer->target2Bd = GBARegisterBLDCNTGetTarget2Bd(value);

	if (oldEffect != renderer->blendEffect) {
		renderer->blendDirty = true;
	}
}

void GBAVideoSoftwareRendererStepWindow(struct GBAVideoSoftwareRenderer* softwareRenderer, int y) {
	int i;
	for (i = 0; i < 2; ++i) {
		struct WindowN* win = &softwareRenderer->winN[i];
		if (y == win->v.start + win->offsetY) {
			win->on = true;
		}
		if (y == win->v.end + win->offsetY) {
			win->on = false;
		}
	}
}

void GBAVideoSoftwareRendererPreprocessBuffer(struct GBAVideoSoftwareRenderer* softwareRenderer) {
	int x;
	for (x = 0; x < GBA_VIDEO_HORIZONTAL_PIXELS; x += 4) {
		softwareRenderer->spriteLayer[x] = FLAG_UNWRITTEN;
		softwareRenderer->spriteLayer[x + 1] = FLAG_UNWRITTEN;
		softwareRenderer->spriteLayer[x + 2] = FLAG_UNWRITTEN;
		softwareRenderer->spriteLayer[x + 3] = FLAG_UNWRITTEN;
	}

	softwareRenderer->windows[0].endX = GBA_VIDEO_HORIZONTAL_PIXELS;
	softwareRenderer->nWindows = 1;
	if (GBARegisterDISPCNTIsWin0Enable(softwareRenderer->dispcnt) || GBARegisterDISPCNTIsWin1Enable(softwareRenderer->dispcnt) || GBARegisterDISPCNTIsObjwinEnable(softwareRenderer->dispcnt)) {
		softwareRenderer->windows[0].control = softwareRenderer->winout;
		if (GBARegisterDISPCNTIsWin1Enable(softwareRenderer->dispcnt) && !softwareRenderer->d.disableWIN[1] && softwareRenderer->winN[1].on) {
			_breakWindow(softwareRenderer, &softwareRenderer->winN[1]);
		}
		if (GBARegisterDISPCNTIsWin0Enable(softwareRenderer->dispcnt) && !softwareRenderer->d.disableWIN[0] && softwareRenderer->winN[0].on) {
			_breakWindow(softwareRenderer, &softwareRenderer->winN[0]);
		}
	} else {
		softwareRenderer->windows[0].control.packed = 0xFF;
	}

	GBAVideoSoftwareRendererUpdateDISPCNT(softwareRenderer);

	if (softwareRenderer->lastHighlightAmount != softwareRenderer->d.highlightAmount) {
		softwareRenderer->lastHighlightAmount = softwareRenderer->d.highlightAmount;
		if (softwareRenderer->lastHighlightAmount) {
			softwareRenderer->blendDirty = true;
		}
	}

	if (softwareRenderer->blendDirty) {
		_updatePalettes(softwareRenderer);
		softwareRenderer->blendDirty = false;
	}
	softwareRenderer->forceTarget1 = false;

	int w;
	x = 0;
	for (w = 0; w < softwareRenderer->nWindows; ++w) {
		// TOOD: handle objwin on backdrop
		uint32_t backdrop = FLAG_UNWRITTEN | FLAG_PRIORITY | FLAG_IS_BACKGROUND;
		if (!softwareRenderer->target1Bd || softwareRenderer->blendEffect == BLEND_NONE || softwareRenderer->blendEffect == BLEND_ALPHA || !GBAWindowControlIsBlendEnable(softwareRenderer->windows[w].control.packed)) {
			backdrop |= softwareRenderer->normalPalette[0];
		} else {
			backdrop |= softwareRenderer->variantPalette[0];
		}
		int end = softwareRenderer->windows[w].endX;
		for (; x & 3; ++x) {
			softwareRenderer->row[x] = backdrop;
		}
		for (; x < end - 3; x += 4) {
			softwareRenderer->row[x] = backdrop;
			softwareRenderer->row[x + 1] = backdrop;
			softwareRenderer->row[x + 2] = backdrop;
			softwareRenderer->row[x + 3] = backdrop;
		}
		for (; x < end; ++x) {
			softwareRenderer->row[x] = backdrop;
		}
	}

	softwareRenderer->bg[0].highlight = softwareRenderer->d.highlightBG[0];
	softwareRenderer->bg[1].highlight = softwareRenderer->d.highlightBG[1];
	softwareRenderer->bg[2].highlight = softwareRenderer->d.highlightBG[2];
	softwareRenderer->bg[3].highlight = softwareRenderer->d.highlightBG[3];
}

void GBAVideoSoftwareRendererPostprocessBuffer(struct GBAVideoSoftwareRenderer* softwareRenderer) {
	int x, w;
	if ((softwareRenderer->forceTarget1 || softwareRenderer->bg[0].target1 || softwareRenderer->bg[1].target1 || softwareRenderer->bg[2].target1 || softwareRenderer->bg[3].target1) && softwareRenderer->target2Bd) {
		x = 0;
		for (w = 0; w < softwareRenderer->nWindows; ++w) {
			uint32_t backdrop = 0;
			if (!softwareRenderer->target1Bd || softwareRenderer->blendEffect == BLEND_NONE || softwareRenderer->blendEffect == BLEND_ALPHA || !GBAWindowControlIsBlendEnable(softwareRenderer->windows[w].control.packed)) {
				backdrop |= softwareRenderer->normalPalette[0];
			} else {
				backdrop |= softwareRenderer->variantPalette[0];
			}
			int end = softwareRenderer->windows[w].endX;
			for (; x < end; ++x) {
				uint32_t color = softwareRenderer->row[x];
				if (color & FLAG_TARGET_1) {
					softwareRenderer->row[x] = mColorMix5Bit(softwareRenderer->bldb, backdrop, softwareRenderer->blda, color);
				}
			}
		}
	}
	if (softwareRenderer->forceTarget1 && (softwareRenderer->blendEffect == BLEND_DARKEN || softwareRenderer->blendEffect == BLEND_BRIGHTEN)) {
		x = 0;
		for (w = 0; w < softwareRenderer->nWindows; ++w) {
			int end = softwareRenderer->windows[w].endX;
			uint32_t mask = FLAG_REBLEND | FLAG_IS_BACKGROUND;
			uint32_t match = FLAG_REBLEND;
			bool objBlend = GBAWindowControlIsBlendEnable(softwareRenderer->objwin.packed);
			bool winBlend = GBAWindowControlIsBlendEnable(softwareRenderer->windows[w].control.packed);
			if (GBARegisterDISPCNTIsObjwinEnable(softwareRenderer->dispcnt) && objBlend != winBlend) {
				mask |= FLAG_OBJWIN;
				if (objBlend) {
					match |= FLAG_OBJWIN;
				}
			} else if (!winBlend) {
				x = end;
				continue;
			}
			if (softwareRenderer->blendEffect == BLEND_DARKEN) {
				for (; x < end; ++x) {
					uint32_t color = softwareRenderer->row[x];
					if ((color & mask) == match) {
						softwareRenderer->row[x] = _darken(color, softwareRenderer->bldy);
					}
				}
			} else if (softwareRenderer->blendEffect == BLEND_BRIGHTEN) {
				for (; x < end; ++x) {
					uint32_t color = softwareRenderer->row[x];
					if ((color & mask) == match) {
						softwareRenderer->row[x] = _brighten(color, softwareRenderer->bldy);
					}
				}
			}
		}
	}
}

int GBAVideoSoftwareRendererPreprocessSpriteLayer(struct GBAVideoSoftwareRenderer* renderer, int y) {
	int w;
	int spriteLayers = 0;
	if (GBARegisterDISPCNTIsObjEnable(renderer->dispcnt) && !renderer->d.disableOBJ) {
		if (renderer->oamDirty) {
			renderer->oamMax = GBAVideoRendererCleanOAM(renderer->d.oam->obj, renderer->sprites, renderer->objOffsetY);
			renderer->oamDirty = false;
		}
		int mosaicV = GBAMosaicControlGetObjV(renderer->mosaic) + 1;
		int mosaicY = y - (y % mosaicV);
		int lastIndex = 0;
		int i;
		for (i = 0; i < renderer->oamMax; ++i) {
			struct GBAVideoRendererSprite* sprite = &renderer->sprites[i];
			int localY = y;
			renderer->end = 0;
			renderer->spriteCyclesRemaining -= 2 * (sprite->index - lastIndex);
			lastIndex = sprite->index;
			if (renderer->spriteCyclesRemaining <= 0) {
				break;
			}
			if (y < sprite->y || y >= sprite->endY) {
				continue;
			}
			if (GBAObjAttributesAIsMosaic(sprite->obj.a) && mosaicV > 1) {
				localY = mosaicY;
				if (localY < sprite->y && sprite->y < GBA_VIDEO_VERTICAL_PIXELS) {
					localY = sprite->y;
				}
				if (localY >= (sprite->endY & 0xFF)) {
					localY = sprite->endY - 1;
				}
			}
			for (w = 0; w < renderer->nWindows; ++w) {
				renderer->currentWindow = renderer->windows[w].control;
				renderer->start = renderer->end;
				renderer->end = renderer->windows[w].endX;
				// TODO: partial sprite drawing
				if (!GBAWindowControlIsObjEnable(renderer->currentWindow.packed) && !GBARegisterDISPCNTIsObjwinEnable(renderer->dispcnt)) {
					continue;
				}

				int drawn = GBAVideoSoftwareRendererPreprocessSprite(renderer, &sprite->obj, sprite->index, localY);
				spriteLayers |= drawn << GBAObjAttributesCGetPriority(sprite->obj.c);
			}
			renderer->spriteCyclesRemaining -= sprite->cycles;
		}
	}
	return spriteLayers;
}

static void _updatePalettes(struct GBAVideoSoftwareRenderer* renderer) {
	int i;
	if (renderer->blendEffect == BLEND_BRIGHTEN) {
		for (i = 0; i < 512; ++i) {
			renderer->variantPalette[i] = _brighten(renderer->normalPalette[i], renderer->bldy);
		}
	} else if (renderer->blendEffect == BLEND_DARKEN) {
		for (i = 0; i < 512; ++i) {
			renderer->variantPalette[i] = _darken(renderer->normalPalette[i], renderer->bldy);
		}
	} else {
		for (i = 0; i < 512; ++i) {
			renderer->variantPalette[i] = renderer->normalPalette[i];
		}
	}
	unsigned highlightAmount = renderer->d.highlightAmount >> 4;

	if (highlightAmount) {
		for (i = 0; i < 512; ++i) {
			renderer->highlightPalette[i] = mColorMix5Bit(0x10 - highlightAmount, renderer->normalPalette[i], highlightAmount, renderer->d.highlightColor);
			renderer->highlightVariantPalette[i] = mColorMix5Bit(0x10 - highlightAmount, renderer->variantPalette[i], highlightAmount, renderer->d.highlightColor);
		}
	}
}

void _updateFlags(struct GBAVideoSoftwareRenderer* renderer, struct GBAVideoSoftwareBackground* background) {
	uint32_t flags = (background->priority << OFFSET_PRIORITY) | (background->index << OFFSET_INDEX) | FLAG_IS_BACKGROUND;
	if (background->target2) {
		flags |= FLAG_TARGET_2;
	}
	uint32_t objwinFlags = flags;
	if (renderer->blendEffect == BLEND_ALPHA) {
		if (renderer->blda == 0x10 && renderer->bldb == 0) {
			flags &= ~FLAG_TARGET_2;
			objwinFlags &= ~FLAG_TARGET_2;
		} else if (background->target1) {
			if (GBAWindowControlIsBlendEnable(renderer->currentWindow.packed)) {
				flags |= FLAG_TARGET_1;
			}
			if (GBAWindowControlIsBlendEnable(renderer->objwin.packed)) {
				objwinFlags |= FLAG_TARGET_1;
			}
		}
	}
	background->flags = flags;
	background->objwinFlags = objwinFlags;
	background->variant = background->target1 && GBAWindowControlIsBlendEnable(renderer->currentWindow.packed) && (renderer->blendEffect == BLEND_BRIGHTEN || renderer->blendEffect == BLEND_DARKEN);
}

/* ===== Imported from reference implementation/software-private.c ===== */
#ifdef NDEBUG
#define VIDEO_CHECKS false
#else
#define VIDEO_CHECKS true
#endif

#define ENABLED_MAX 4

void GBAVideoSoftwareRendererDrawBackgroundMode0(struct GBAVideoSoftwareRenderer* renderer,
                                                 struct GBAVideoSoftwareBackground* background, int y);
void GBAVideoSoftwareRendererDrawBackgroundMode2(struct GBAVideoSoftwareRenderer* renderer,
                                                 struct GBAVideoSoftwareBackground* background, int y);
void GBAVideoSoftwareRendererDrawBackgroundMode3(struct GBAVideoSoftwareRenderer* renderer,
                                                 struct GBAVideoSoftwareBackground* background, int y);
void GBAVideoSoftwareRendererDrawBackgroundMode4(struct GBAVideoSoftwareRenderer* renderer,
                                                 struct GBAVideoSoftwareBackground* background, int y);
void GBAVideoSoftwareRendererDrawBackgroundMode5(struct GBAVideoSoftwareRenderer* renderer,
                                                 struct GBAVideoSoftwareBackground* background, int y);

int GBAVideoSoftwareRendererPreprocessSprite(struct GBAVideoSoftwareRenderer* renderer, struct GBAObj* sprite, int index, int y);
void GBAVideoSoftwareRendererPostprocessSprite(struct GBAVideoSoftwareRenderer* renderer, unsigned priority);

static inline unsigned _brighten(unsigned color, int y);
static inline unsigned _darken(unsigned color, int y);

// We stash the priority on the top bits so we can do a one-operator comparison
// The lower the number, the higher the priority, and sprites take precedence over backgrounds
// We want to do special processing if the color pixel is target 1, however

static inline void _compositeBlendObjwin(struct GBAVideoSoftwareRenderer* renderer, uint32_t* pixel, uint32_t color, uint32_t current) {
	if (color >= current) {
		if (current & FLAG_TARGET_1 && color & FLAG_TARGET_2) {
			color = mColorMix5Bit(renderer->blda, current, renderer->bldb, color);
		} else {
			color = current & (0x00FFFFFF | FLAG_REBLEND | FLAG_OBJWIN);
		}
	} else {
		color = (color & ~FLAG_TARGET_2) | (current & FLAG_OBJWIN);
	}
	*pixel = color;
}

static inline void _compositeBlendNoObjwin(struct GBAVideoSoftwareRenderer* renderer, uint32_t* pixel, uint32_t color, uint32_t current) {
	if (color >= current) {
		if (current & FLAG_TARGET_1 && color & FLAG_TARGET_2) {
			color = mColorMix5Bit(renderer->blda, current, renderer->bldb, color);
		} else {
			color = current & (0x00FFFFFF | FLAG_REBLEND | FLAG_OBJWIN);
		}
	} else {
		color = color & ~FLAG_TARGET_2;
	}
	*pixel = color;
}

static inline void _compositeNoBlendObjwin(struct GBAVideoSoftwareRenderer* renderer, uint32_t* pixel, uint32_t color,
                                           uint32_t current) {
	UNUSED(renderer);
	if (color < current) {
		color |= (current & FLAG_OBJWIN);
	} else {
		color = current & (0x00FFFFFF | FLAG_REBLEND | FLAG_OBJWIN);
	}
	*pixel = color;
}

static inline void _compositeNoBlendNoObjwin(struct GBAVideoSoftwareRenderer* renderer, uint32_t* pixel, uint32_t color,
                                             uint32_t current) {
	UNUSED(renderer);
	if (color >= current) {
		color = current & (0x00FFFFFF | FLAG_REBLEND | FLAG_OBJWIN);
	}
	*pixel = color;
}

#define COMPOSITE_16_OBJWIN(BLEND, IDX)  \
	if (background->objwinForceEnable || (!(current & FLAG_OBJWIN)) == background->objwinOnly) { \
		unsigned color; \
		unsigned mergedFlags = flags; \
		if (current & FLAG_OBJWIN) { \
			mergedFlags = objwinFlags; \
			color = objwinPalette[paletteData | pixelData]; \
		} else if ((current & (FLAG_IS_BACKGROUND | FLAG_REBLEND)) == FLAG_REBLEND) { \
			color = renderer->normalPalette[paletteData | pixelData]; \
		} else { \
			color = palette[paletteData | pixelData]; \
		} \
		_composite ## BLEND ## Objwin(renderer, &pixel[IDX], color | mergedFlags, current); \
	}

#define COMPOSITE_16_NO_OBJWIN(BLEND, IDX) \
	{ \
		unsigned color; \
		if ((current & (FLAG_IS_BACKGROUND | FLAG_REBLEND)) == FLAG_REBLEND) { \
			color = renderer->normalPalette[paletteData | pixelData]; \
		} else { \
			color = palette[paletteData | pixelData]; \
		} \
		_composite ## BLEND ## NoObjwin(renderer, &pixel[IDX], color | flags, current); \
	}

#define COMPOSITE_256_OBJWIN(BLEND, IDX) \
	if (background->objwinForceEnable || (!(current & FLAG_OBJWIN)) == background->objwinOnly) { \
		unsigned color; \
		unsigned mergedFlags = flags; \
		if (current & FLAG_OBJWIN) { \
			mergedFlags = objwinFlags; \
			color = objwinPalette[pixelData]; \
		} else if ((current & (FLAG_IS_BACKGROUND | FLAG_REBLEND)) == FLAG_REBLEND) { \
			color = renderer->normalPalette[pixelData]; \
		} else { \
			color = palette[pixelData]; \
		} \
		_composite ## BLEND ## Objwin(renderer, &pixel[IDX], color | mergedFlags, current); \
	}

#define COMPOSITE_256_NO_OBJWIN(BLEND, IDX) \
	{ \
		unsigned color; \
		if ((current & (FLAG_IS_BACKGROUND | FLAG_REBLEND)) == FLAG_REBLEND) { \
			color = renderer->normalPalette[pixelData]; \
		} else { \
			color = palette[pixelData]; \
		} \
		_composite ## BLEND ## NoObjwin(renderer, &pixel[IDX], color | flags, current); \
	}

#define BACKGROUND_DRAW_PIXEL_16(BLEND, OBJWIN, IDX) \
	pixelData = tileData & 0xF; \
	current = pixel[IDX]; \
	if (pixelData && IS_WRITABLE(current)) { \
		COMPOSITE_16_ ## OBJWIN (BLEND, IDX); \
	} \
	tileData >>= 4;

#define BACKGROUND_DRAW_PIXEL_256(BLEND, OBJWIN, IDX) \
	pixelData = tileData & 0xFF; \
	current = pixel[IDX]; \
	if (pixelData && IS_WRITABLE(current)) { \
		COMPOSITE_256_ ## OBJWIN (BLEND, IDX); \
	} \
	tileData >>= 8;

// TODO: Remove UNUSEDs after implementing OBJWIN for modes 3 - 5
#define PREPARE_OBJWIN                                                                            \
	int objwinSlowPath = GBARegisterDISPCNTIsObjwinEnable(renderer->dispcnt);                     \
	mColor* objwinPalette = renderer->normalPalette;                                             \
	if (renderer->d.highlightAmount && background->highlight) {                                   \
		objwinPalette = renderer->highlightPalette;                                               \
	}                                                                                             \
	UNUSED(objwinPalette);                                                                        \
	if (objwinSlowPath) {                                                                         \
		if (background->target1 && GBAWindowControlIsBlendEnable(renderer->objwin.packed) &&      \
		    (renderer->blendEffect == BLEND_BRIGHTEN || renderer->blendEffect == BLEND_DARKEN)) { \
			objwinPalette = renderer->variantPalette;                                             \
			if (renderer->d.highlightAmount && background->highlight) {                           \
				palette = renderer->highlightVariantPalette;                                      \
			}                                                                                     \
		}                                                                                         \
	}

#define BACKGROUND_BITMAP_INIT                                                                                        \
	int32_t x = background->sx + (renderer->start - 1) * background->dx;                                              \
	int32_t y = background->sy + (renderer->start - 1) * background->dy;                                              \
	int mosaicH = 0;                                                                                                  \
	int mosaicWait = 0;                                                                                               \
	int32_t localX;                                                                                                   \
	int32_t localY;                                                                                                   \
	if (background->mosaic) {                                                                                         \
		int mosaicV = GBAMosaicControlGetBgV(renderer->mosaic) + 1;                                                   \
		mosaicH = GBAMosaicControlGetBgH(renderer->mosaic) + 1;                                                       \
		mosaicWait = (mosaicH - renderer->start + GBA_VIDEO_HORIZONTAL_PIXELS * mosaicH) % mosaicH;                   \
		int32_t startX = renderer->start - (renderer->start % mosaicH);                                               \
		--mosaicH;                                                                                                    \
		localX = -(inY % mosaicV) * background->dmx;                                                                  \
		localY = -(inY % mosaicV) * background->dmy;                                                                  \
		x += localX;                                                                                                  \
		y += localY;                                                                                                  \
		localX += background->sx + startX * background->dx;                                                           \
		localY += background->sy + startX * background->dy;                                                           \
	}                                                                                                                 \
                                                                                                                      \
	uint32_t flags = background->flags;                                                                               \
	uint32_t objwinFlags = background->objwinFlags;                                                                   \
	bool variant = background->variant;                                                                               \
	mColor* palette = renderer->normalPalette;                                                                       \
	if (renderer->d.highlightAmount && background->highlight) {                                                       \
		palette = renderer->highlightPalette;                                                                         \
	}                                                                                                                 \
	if (variant) {                                                                                                    \
		palette = renderer->variantPalette;                                                                           \
		if (renderer->d.highlightAmount && background->highlight) {                                                   \
			palette = renderer->highlightVariantPalette;                                                              \
		}                                                                                                             \
	}                                                                                                                 \
	UNUSED(palette);                                                                                                  \
	PREPARE_OBJWIN;

#define TEST_LAYER_ENABLED(X) \
	!softwareRenderer->d.disableBG[X] && \
	(softwareRenderer->bg[X].enabled == ENABLED_MAX && \
	(GBAWindowControlIsBg ## X ## Enable(softwareRenderer->currentWindow.packed) || \
	(GBARegisterDISPCNTIsObjwinEnable(softwareRenderer->dispcnt) && GBAWindowControlIsBg ## X ## Enable (softwareRenderer->objwin.packed))) && \
	softwareRenderer->bg[X].priority == priority)

static inline unsigned _brighten(unsigned color, int y) {
	unsigned c = 0;
	unsigned a;
#ifdef COLOR_16_BIT
	a = color & 0x1F;
	c |= (a + ((0x1F - a) * y) / 16) & 0x1F;

#ifdef COLOR_5_6_5
	a = color & 0x7C0;
	c |= (a + ((0x7C0 - a) * y) / 16) & 0x7C0;

	a = color & 0xF800;
	c |= (a + ((0xF800 - a) * y) / 16) & 0xF800;
#else
	a = color & 0x3E0;
	c |= (a + ((0x3E0 - a) * y) / 16) & 0x3E0;

	a = color & 0x7C00;
	c |= (a + ((0x7C00 - a) * y) / 16) & 0x7C00;
#endif
#else
	a = color & 0xFF;
	c |= (a + ((0xFF - a) * y) / 16) & 0xFF;

	a = color & 0xFF00;
	c |= (a + ((0xFF00 - a) * y) / 16) & 0xFF00;

	a = color & 0xFF0000;
	c |= (a + ((0xFF0000 - a) * y) / 16) & 0xFF0000;
#endif
	return c;
}

static inline unsigned _darken(unsigned color, int y) {
	unsigned c = 0;
	unsigned a;
#ifdef COLOR_16_BIT
	a = color & 0x1F;
	c |= (a - (a * y) / 16) & 0x1F;

#ifdef COLOR_5_6_5
	a = color & 0x7C0;
	c |= (a - (a * y) / 16) & 0x7C0;

	a = color & 0xF800;
	c |= (a - (a * y) / 16) & 0xF800;
#else
	a = color & 0x3E0;
	c |= (a - (a * y) / 16) & 0x3E0;

	a = color & 0x7C00;
	c |= (a - (a * y) / 16) & 0x7C00;
#endif
#else
	a = color & 0xFF;
	c |= (a - (a * y) / 16) & 0xFF;

	a = color & 0xFF00;
	c |= (a - (a * y) / 16) & 0xFF00;

	a = color & 0xFF0000;
	c |= (a - (a * y) / 16) & 0xFF0000;
#endif
	return c;
}

/* ===== Imported from reference implementation/common.c ===== */
int GBAVideoRendererCleanOAM(struct GBAObj* oam, struct GBAVideoRendererSprite* sprites, int offsetY) {
	int i;
	int oamMax = 0;
	for (i = 0; i < 128; ++i) {
		struct GBAObj obj;
		LOAD_16LE(obj.a, 0, &oam[i].a);
		LOAD_16LE(obj.b, 0, &oam[i].b);
		LOAD_16LE(obj.c, 0, &oam[i].c);
		if (GBAObjAttributesAIsTransformed(obj.a) || !GBAObjAttributesAIsDisable(obj.a)) {
			int width = GBAVideoObjSizes[GBAObjAttributesAGetShape(obj.a) * 4 + GBAObjAttributesBGetSize(obj.b)][0];
			int height = GBAVideoObjSizes[GBAObjAttributesAGetShape(obj.a) * 4 + GBAObjAttributesBGetSize(obj.b)][1];
			int32_t x = (uint32_t) GBAObjAttributesBGetX(obj.b) << 23;
			x >>= 23;
			int cycles;
			if (GBAObjAttributesAIsTransformed(obj.a)) {
				height <<= GBAObjAttributesAGetDoubleSize(obj.a);
				width <<= GBAObjAttributesAGetDoubleSize(obj.a);
				cycles = 8 + width * 2;
				if (x < 0) {
					cycles += x;
				}
			} else {
				cycles = width - 2;
				if (x < 0) {
					if (x + width < 0) {
						continue;
					}
					cycles += x >> 1;
				}
			}
			if (GBAObjAttributesAGetY(obj.a) >= GBA_VIDEO_VERTICAL_PIXELS && GBAObjAttributesAGetY(obj.a) + height < VIDEO_VERTICAL_TOTAL_PIXELS) {
				continue;
			}
			if (GBAObjAttributesBGetX(obj.b) >= GBA_VIDEO_HORIZONTAL_PIXELS && GBAObjAttributesBGetX(obj.b) + width < 512) {
				continue;
			}
			int y = GBAObjAttributesAGetY(obj.a) + offsetY;
			if (y + height > 256) {
				y -= 256;
			}
			sprites[oamMax].y = y;
			sprites[oamMax].endY = y + height;
			sprites[oamMax].cycles = cycles;
			sprites[oamMax].obj = obj;
			sprites[oamMax].index = i;
			++oamMax;
		}
	}
	return oamMax;
}

