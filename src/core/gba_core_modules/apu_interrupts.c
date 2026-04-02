#include "../gba_core.h"
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#ifndef GBA_CORE_ENABLE_OS_DOLPHIN_LINK
#define GBA_CORE_ENABLE_OS_DOLPHIN_LINK 0
#endif

/* ===== Imported from reference implementation/sio.c ===== */
mLOG_DEFINE_CATEGORY(GBA_SIO, "GBA Serial I/O", "gba.sio");

static const int GBASIOCyclesPerTransfer[4][MAX_GBAS] = {
	{ 31976, 63427, 94884, 125829 },
	{ 8378, 16241, 24104, 31457 },
	{ 5750, 10998, 16241, 20972 },
	{ 3140, 5755, 8376, 10486 }
};

static void _sioFinish(struct mTiming* timing, void* user, uint32_t cyclesLate);

static const char* _modeName(enum GBASIOMode mode) {
	switch (mode) {
	case GBA_SIO_NORMAL_8:
		return "NORMAL8";
	case GBA_SIO_NORMAL_32:
		return "NORMAL32";
	case GBA_SIO_MULTI:
		return "MULTI";
	case GBA_SIO_JOYBUS:
		return "JOYBUS";
	case GBA_SIO_GPIO:
		return "GPIO";
	default:
		return "(unknown)";
	}
}

static void _switchMode(struct GBASIO* sio) {
	unsigned mode = ((sio->rcnt & 0xC000) | (sio->siocnt & 0x3000)) >> 12;
	enum GBASIOMode newMode;
	if (mode < 8) {
		newMode = (enum GBASIOMode) (mode & 0x3);
	} else {
		newMode = (enum GBASIOMode) (mode & 0xC);
	}
	if (newMode != sio->mode) {
		if (sio->mode != (enum GBASIOMode) -1) {
			mLOG(GBA_SIO, DEBUG, "Switching mode from %s to %s", _modeName(sio->mode), _modeName(newMode));
		}
		sio->mode = newMode;
		if (sio->driver && sio->driver->setMode) {
			sio->driver->setMode(sio->driver, newMode);
		}

		int id = 0;
		switch (newMode) {
		case GBA_SIO_MULTI:
			if (sio->driver && sio->driver->deviceId) {
				id = sio->driver->deviceId(sio->driver);
			}
			sio->rcnt = GBASIORegisterRCNTSetSi(sio->rcnt, !!id);
			break;
		default:
			// TODO
			break;
		}
	}
}

void GBASIOInit(struct GBASIO* sio) {
	sio->driver = NULL;

	sio->completeEvent.context = sio;
	sio->completeEvent.name = "GBA SIO Complete";
	sio->completeEvent.callback = _sioFinish;
	sio->completeEvent.priority = 0x80;

	sio->gbp.p = sio->p;
	GBASIOPlayerInit(&sio->gbp);

	GBASIOReset(sio);
}

void GBASIODeinit(struct GBASIO* sio) {
	if (sio->driver && sio->driver->deinit) {
		sio->driver->deinit(sio->driver);
	}
}

void GBASIOReset(struct GBASIO* sio) {
	if (sio->driver && sio->driver->reset) {
		sio->driver->reset(sio->driver);
	}
	sio->rcnt = RCNT_INITIAL;
	sio->siocnt = 0;
	sio->mode = -1;
	_switchMode(sio);

	GBASIOPlayerReset(&sio->gbp);
}

void GBASIOSetDriver(struct GBASIO* sio, struct GBASIODriver* driver) {
	if (sio->driver && sio->driver->deinit) {
		sio->driver->deinit(sio->driver);
	}
	sio->driver = driver;
	if (driver) {
		driver->p = sio;

		if (driver->init) {
			if (!driver->init(driver)) {
				driver->deinit(driver);
				mLOG(GBA_SIO, ERROR, "Could not initialize SIO driver");
				return;
			}
		}
	}
}

void GBASIOWriteRCNT(struct GBASIO* sio, uint16_t value) {
	sio->rcnt &= 0x1FF;
	sio->rcnt |= value & 0xC000;
	_switchMode(sio);
	if (sio->driver && sio->driver->writeRCNT) {
		switch (sio->mode) {
		case GBA_SIO_GPIO:
			sio->rcnt = (sio->driver->writeRCNT(sio->driver, value) & 0x01FF) | (sio->rcnt & 0xC000);
			break;
		default:
			sio->rcnt = (sio->driver->writeRCNT(sio->driver, value) & 0x01F0) | (sio->rcnt & 0xC00F);
		}
	} else if (sio->mode == GBA_SIO_GPIO) {
		sio->rcnt &= 0xC000;
		sio->rcnt |= value & 0x1FF;
	} else {
		sio->rcnt &= 0xC00F;
		sio->rcnt |= value & 0x1F0;
	}
}

static void _startTransfer(struct GBASIO* sio) {
	if (sio->driver && sio->driver->start) {
		if (!sio->driver->start(sio->driver)) {
			// Transfer completion is handled internally to the driver
			return;
		}
	}
	int connected = 0;
	if (sio->driver && sio->driver->connectedDevices) {
		connected = sio->driver->connectedDevices(sio->driver);
	}
	mTimingDeschedule(&sio->p->timing, &sio->completeEvent);
	mTimingSchedule(&sio->p->timing, &sio->completeEvent, GBASIOTransferCycles(sio->mode, sio->siocnt, connected));
}

void GBASIOWriteSIOCNT(struct GBASIO* sio, uint16_t value) {
	if ((value ^ sio->siocnt) & 0x3000) {
		sio->siocnt = value & 0x3000;
		_switchMode(sio);
	}
	int id = 0;
	int connected = 0;
	bool handled = false;
	if (sio->driver) {
		handled = sio->driver->handlesMode(sio->driver, sio->mode);
		if (handled) {
			if (sio->driver->deviceId) {
				id = sio->driver->deviceId(sio->driver);
			}
			connected = sio->driver->connectedDevices(sio->driver);
			handled = !!sio->driver->writeSIOCNT;
		}
	}

	switch (sio->mode) {
	case GBA_SIO_MULTI:
		value &= 0xFF83;
		value = GBASIOMultiplayerSetSlave(value, id || !connected);
		value = GBASIOMultiplayerSetId(value, id);
		value |= sio->siocnt & 0x00FC;

		// SC appears to float in multi mode when not doing a transfer. While
		// it does spike at the end of a transfer, it appears to die down after
		// around 20-30 microseconds. However, the docs on akkit.org
		// (http://www.akkit.org/info/gba_comms.html) say this is high until
		// a transfer starts and low while active. Further, the Mario Bros.
		// multiplayer expects SC to be high in multi mode. This needs better
		// investigation than I managed, apparently.
		sio->rcnt = GBASIORegisterRCNTFillSc(sio->rcnt);

		if (GBASIOMultiplayerIsBusy(value) && !GBASIOMultiplayerIsBusy(sio->siocnt)) {
			if (!id) {
				sio->p->memory.io[GBA_REG(SIOMULTI0)] = 0xFFFF;
				sio->p->memory.io[GBA_REG(SIOMULTI1)] = 0xFFFF;
				sio->p->memory.io[GBA_REG(SIOMULTI2)] = 0xFFFF;
				sio->p->memory.io[GBA_REG(SIOMULTI3)] = 0xFFFF;
				sio->rcnt = GBASIORegisterRCNTClearSc(sio->rcnt);
				_startTransfer(sio);
			} else {
				// TODO
			}
		}
		break;
	case GBA_SIO_NORMAL_8:
	case GBA_SIO_NORMAL_32:
		// This line is pulled up by the clock owner while the clock is idle.
		// If there is no clock owner it's just hi-Z.
		if (GBASIONormalGetSc(value)) {
			sio->rcnt = GBASIORegisterRCNTFillSc(sio->rcnt);
		}
		if (GBASIONormalIsStart(value) && !GBASIONormalIsStart(sio->siocnt)) {
			_startTransfer(sio);
		}
		break;
	default:
		// TODO
		break;
	}
	if (handled) {
		value = sio->driver->writeSIOCNT(sio->driver, value);
	} else {
		// Dummy drivers
		switch (sio->mode) {
		case GBA_SIO_NORMAL_8:
		case GBA_SIO_NORMAL_32:
			value = GBASIONormalFillSi(value);
			break;
		case GBA_SIO_MULTI:
			value = GBASIOMultiplayerFillReady(value);
			break;
		default:
			// TODO
			break;
		}
	}
	sio->siocnt = value;
}

uint16_t GBASIOWriteRegister(struct GBASIO* sio, uint32_t address, uint16_t value) {
	int id = 0;
	if (sio->driver && sio->driver->deviceId) {
		id = sio->driver->deviceId(sio->driver);
	}

	bool handled = true;
	switch (sio->mode) {
	case GBA_SIO_JOYBUS:
		switch (address) {
		case GBA_REG_SIODATA8:
			mLOG(GBA_SIO, DEBUG, "JOY write: SIODATA8 (?) <- %04X", value);
			break;
		case GBA_REG_JOYCNT:
			mLOG(GBA_SIO, DEBUG, "JOY write: CNT <- %04X", value);
			value = (value & 0x0040) | (sio->p->memory.io[GBA_REG(JOYCNT)] & ~(value & 0x7) & ~0x0040);
			break;
		case GBA_REG_JOYSTAT:
			mLOG(GBA_SIO, DEBUG, "JOY write: STAT <- %04X", value);
			value = (value & 0x0030) | (sio->p->memory.io[GBA_REG(JOYSTAT)] & ~0x30);
			break;
		case GBA_REG_JOY_TRANS_LO:
			mLOG(GBA_SIO, DEBUG, "JOY write: TRANS_LO <- %04X", value);
			break;
		case GBA_REG_JOY_TRANS_HI:
			mLOG(GBA_SIO, DEBUG, "JOY write: TRANS_HI <- %04X", value);
			break;
		default:
			mLOG(GBA_SIO, GAME_ERROR, "JOY write: Unhandled %s <- %04X", GBAIORegisterNames[address >> 1], value);
			handled = false;
			break;
		}
		break;
	case GBA_SIO_NORMAL_8:
		switch (address) {
		case GBA_REG_SIODATA8:
			mLOG(GBA_SIO, DEBUG, "NORMAL8 %i write: SIODATA8 <- %04X", id, value);
			break;
		case GBA_REG_JOYCNT:
			mLOG(GBA_SIO, DEBUG, "NORMAL8 %i write: JOYCNT (?) <- %04X", id, value);
			value = (value & 0x0040) | (sio->p->memory.io[GBA_REG(JOYCNT)] & ~(value & 0x7) & ~0x0040);
			break;
		default:
			mLOG(GBA_SIO, GAME_ERROR, "NORMAL8 %i write: Unhandled %s <- %04X", id, GBAIORegisterNames[address >> 1], value);
			handled = false;
			break;
		}
		break;
	case GBA_SIO_NORMAL_32:
		switch (address) {
		case GBA_REG_SIODATA32_LO:
			mLOG(GBA_SIO, DEBUG, "NORMAL32 %i write: SIODATA32_LO <- %04X", id, value);
			break;
		case GBA_REG_SIODATA32_HI:
			mLOG(GBA_SIO, DEBUG, "NORMAL32 %i write: SIODATA32_HI <- %04X", id, value);
			break;
		case GBA_REG_SIODATA8:
			mLOG(GBA_SIO, DEBUG, "NORMAL32 %i write: SIODATA8 (?) <- %04X", id, value);
			break;
		case GBA_REG_JOYCNT:
			mLOG(GBA_SIO, DEBUG, "NORMAL32 %i write: JOYCNT (?) <- %04X", id, value);
			value = (value & 0x0040) | (sio->p->memory.io[GBA_REG(JOYCNT)] & ~(value & 0x7) & ~0x0040);
			break;
		default:
			mLOG(GBA_SIO, GAME_ERROR, "NORMAL32 %i write: Unhandled %s <- %04X", id, GBAIORegisterNames[address >> 1], value);
			handled = false;
			break;
		}
		break;
	case GBA_SIO_MULTI:
		switch (address) {
		case GBA_REG_SIOMLT_SEND:
			mLOG(GBA_SIO, DEBUG, "MULTI %i write: SIOMLT_SEND <- %04X", id, value);
			break;
		case GBA_REG_JOYCNT:
			mLOG(GBA_SIO, DEBUG, "MULTI %i write: JOYCNT (?) <- %04X", id, value);
			value = (value & 0x0040) | (sio->p->memory.io[GBA_REG(JOYCNT)] & ~(value & 0x7) & ~0x0040);
			break;
		default:
			mLOG(GBA_SIO, GAME_ERROR, "MULTI %i write: Unhandled %s <- %04X", id, GBAIORegisterNames[address >> 1], value);
			handled = false;
			break;
		}
		break;
	case GBA_SIO_UART:
		switch (address) {
		case GBA_REG_SIODATA8:
			mLOG(GBA_SIO, DEBUG, "UART write: SIODATA8 <- %04X", value);
			break;
		case GBA_REG_JOYCNT:
			mLOG(GBA_SIO, DEBUG, "UART write: JOYCNT (?) <- %04X", value);
			value = (value & 0x0040) | (sio->p->memory.io[GBA_REG(JOYCNT)] & ~(value & 0x7) & ~0x0040);
			break;
		default:
			mLOG(GBA_SIO, GAME_ERROR, "UART write: Unhandled %s <- %04X", GBAIORegisterNames[address >> 1], value);
			handled = false;
			break;
		}
		break;
	case GBA_SIO_GPIO:
		mLOG(GBA_SIO, STUB, "GPIO write: Unhandled %s <- %04X", GBAIORegisterNames[address >> 1], value);
		handled = false;
		break;
	}
	if (!handled) {
		value = sio->p->memory.io[address >> 1];
	}
	return value;
}

int32_t GBASIOTransferCycles(enum GBASIOMode mode, uint16_t siocnt, int connected) {
	if (connected < 0 || connected >= MAX_GBAS) {
		mLOG(GBA_SIO, ERROR, "Invalid device count %i", connected);
		return 0;
	}

	switch (mode) {
	case GBA_SIO_MULTI:
		return GBASIOCyclesPerTransfer[GBASIOMultiplayerGetBaud(siocnt)][connected];
	case GBA_SIO_NORMAL_8:
		return 8 * GBA_ARM7TDMI_FREQUENCY / ((GBASIONormalIsInternalSc(siocnt) ? 2048 : 256) * 1024);
	case GBA_SIO_NORMAL_32:
		return 32 * GBA_ARM7TDMI_FREQUENCY / ((GBASIONormalIsInternalSc(siocnt) ? 2048 : 256) * 1024);
	default:
		mLOG(GBA_SIO, STUB, "No cycle count implemented for mode %s", _modeName(mode));
		break;
	}
	return 0;
}

void GBASIOMultiplayerFinishTransfer(struct GBASIO* sio, uint16_t data[4], uint32_t cyclesLate) {
	int id = 0;
	if (sio->driver && sio->driver->deviceId) {
		id = sio->driver->deviceId(sio->driver);
	}
	sio->p->memory.io[GBA_REG(SIOMULTI0)] = data[0];
	sio->p->memory.io[GBA_REG(SIOMULTI1)] = data[1];
	sio->p->memory.io[GBA_REG(SIOMULTI2)] = data[2];
	sio->p->memory.io[GBA_REG(SIOMULTI3)] = data[3];

	sio->siocnt = GBASIOMultiplayerClearBusy(sio->siocnt);
	sio->siocnt = GBASIOMultiplayerSetId(sio->siocnt, id);

	sio->rcnt = GBASIORegisterRCNTFillSc(sio->rcnt);

	if (GBASIOMultiplayerIsIrq(sio->siocnt)) {
		GBARaiseIRQ(sio->p, GBA_IRQ_SIO, cyclesLate);
	}
}

void GBASIONormal8FinishTransfer(struct GBASIO* sio, uint8_t data, uint32_t cyclesLate) {
	sio->siocnt = GBASIONormalClearStart(sio->siocnt);
	sio->p->memory.io[GBA_REG(SIODATA8)] = data;
	if (GBASIONormalIsIrq(sio->siocnt)) {
		GBARaiseIRQ(sio->p, GBA_IRQ_SIO, cyclesLate);
	}
}

void GBASIONormal32FinishTransfer(struct GBASIO* sio, uint32_t data, uint32_t cyclesLate) {
	sio->siocnt = GBASIONormalClearStart(sio->siocnt);
	sio->p->memory.io[GBA_REG(SIODATA32_LO)] = data;
	sio->p->memory.io[GBA_REG(SIODATA32_HI)] = data >> 16;
	if (GBASIONormalIsIrq(sio->siocnt)) {
		GBARaiseIRQ(sio->p, GBA_IRQ_SIO, cyclesLate);
	}
}

static void _sioFinish(struct mTiming* timing, void* user, uint32_t cyclesLate) {
	UNUSED(timing);
	struct GBASIO* sio = user;
	union {
		uint16_t multi[4];
		uint8_t normal8;
		uint32_t normal32;
	} data = {0};
	switch (sio->mode) {
	case GBA_SIO_MULTI:
		if (sio->driver && sio->driver->finishMultiplayer) {
			sio->driver->finishMultiplayer(sio->driver, data.multi);
		}
		GBASIOMultiplayerFinishTransfer(sio, data.multi, cyclesLate);
		break;
	case GBA_SIO_NORMAL_8:
		if (sio->driver && sio->driver->finishNormal8) {
			data.normal8 = sio->driver->finishNormal8(sio->driver);
		}
		GBASIONormal8FinishTransfer(sio, data.normal8, cyclesLate);
		break;
	case GBA_SIO_NORMAL_32:
		if (sio->driver && sio->driver->finishNormal32) {
			data.normal32 = sio->driver->finishNormal32(sio->driver);
		}
		GBASIONormal32FinishTransfer(sio, data.normal32, cyclesLate);
		break;
	default:
		// TODO
		mLOG(GBA_SIO, STUB, "No dummy finish implemented for mode %s", _modeName(sio->mode));
		break;
	}
}

int GBASIOJOYSendCommand(struct GBASIODriver* sio, enum GBASIOJOYCommand command, uint8_t* data) {
	switch (command) {
	case JOY_RESET:
		sio->p->p->memory.io[GBA_REG(JOYCNT)] |= JOYCNT_RESET;
		if (sio->p->p->memory.io[GBA_REG(JOYCNT)] & 0x40) {
			GBARaiseIRQ(sio->p->p, GBA_IRQ_SIO, 0);
		}
		// Fall through
	case JOY_POLL:
		data[0] = 0x00;
		data[1] = 0x04;
		data[2] = sio->p->p->memory.io[GBA_REG(JOYSTAT)];

		mLOG(GBA_SIO, DEBUG, "JOY %s: %02X (%02X)", command == JOY_POLL ? "poll" : "reset", data[2], sio->p->p->memory.io[GBA_REG(JOYCNT)]);
		return 3;
	case JOY_RECV:
		sio->p->p->memory.io[GBA_REG(JOYCNT)] |= JOYCNT_RECV;
		sio->p->p->memory.io[GBA_REG(JOYSTAT)] |= JOYSTAT_RECV;

		sio->p->p->memory.io[GBA_REG(JOY_RECV_LO)] = data[0] | (data[1] << 8);
		sio->p->p->memory.io[GBA_REG(JOY_RECV_HI)] = data[2] | (data[3] << 8);

		data[0] = sio->p->p->memory.io[GBA_REG(JOYSTAT)];

		mLOG(GBA_SIO, DEBUG, "JOY recv: %02X (%02X)", data[0], sio->p->p->memory.io[GBA_REG(JOYCNT)]);

		if (sio->p->p->memory.io[GBA_REG(JOYCNT)] & 0x40) {
			GBARaiseIRQ(sio->p->p, GBA_IRQ_SIO, 0);
		}
		return 1;
	case JOY_TRANS:
		data[0] = sio->p->p->memory.io[GBA_REG(JOY_TRANS_LO)];
		data[1] = sio->p->p->memory.io[GBA_REG(JOY_TRANS_LO)] >> 8;
		data[2] = sio->p->p->memory.io[GBA_REG(JOY_TRANS_HI)];
		data[3] = sio->p->p->memory.io[GBA_REG(JOY_TRANS_HI)] >> 8;
		data[4] = sio->p->p->memory.io[GBA_REG(JOYSTAT)];

		sio->p->p->memory.io[GBA_REG(JOYCNT)] |= JOYCNT_TRANS;
		sio->p->p->memory.io[GBA_REG(JOYSTAT)] &= ~JOYSTAT_TRANS;

		mLOG(GBA_SIO, DEBUG, "JOY trans: %02X%02X%02X%02X:%02X (%02X)", data[0], data[1], data[2], data[3], data[4], sio->p->p->memory.io[GBA_REG(JOYCNT)]);

		if (sio->p->p->memory.io[GBA_REG(JOYCNT)] & 0x40) {
			GBARaiseIRQ(sio->p->p, GBA_IRQ_SIO, 0);
		}
		return 5;
	}
	return 0;
}

/* ===== Imported from reference implementation/dolphin.c ===== */
#if GBA_CORE_ENABLE_OS_DOLPHIN_LINK
#define BITS_PER_SECOND 115200 // This is wrong, but we need to maintain compat for the time being
#define CYCLES_PER_BIT (GBA_ARM7TDMI_FREQUENCY / BITS_PER_SECOND)
#define CLOCK_GRAIN (CYCLES_PER_BIT * 8)
#define CLOCK_WAIT 500

const uint16_t DOLPHIN_CLOCK_PORT = 49420;
const uint16_t DOLPHIN_DATA_PORT = 54970;

enum {
	WAIT_FOR_FIRST_CLOCK = 0,
	WAIT_FOR_CLOCK,
	WAIT_FOR_COMMAND,
};

static bool GBASIODolphinInit(struct GBASIODriver* driver);
static void GBASIODolphinReset(struct GBASIODriver* driver);
static void GBASIODolphinSetMode(struct GBASIODriver* driver, enum GBASIOMode mode);
static bool GBASIODolphinHandlesMode(struct GBASIODriver* driver, enum GBASIOMode mode);
static int GBASIODolphinConnectedDevices(struct GBASIODriver* driver);
static void GBASIODolphinProcessEvents(struct mTiming* timing, void* context, uint32_t cyclesLate);

static int32_t _processCommand(struct GBASIODolphin* dol, uint32_t cyclesLate);
static void _flush(struct GBASIODolphin* dol);

void GBASIODolphinCreate(struct GBASIODolphin* dol) {
	memset(&dol->d, 0, sizeof(dol->d));
	dol->d.init = GBASIODolphinInit;
	dol->d.reset = GBASIODolphinReset;
	dol->d.setMode = GBASIODolphinSetMode;
	dol->d.handlesMode = GBASIODolphinHandlesMode;
	dol->d.connectedDevices = GBASIODolphinConnectedDevices;
	dol->event.context = dol;
	dol->event.name = "GB SIO Lockstep";
	dol->event.callback = GBASIODolphinProcessEvents;
	dol->event.priority = 0x80;

	dol->data = INVALID_SOCKET;
	dol->clock = INVALID_SOCKET;
	dol->active = false;
}

void GBASIODolphinDestroy(struct GBASIODolphin* dol) {
	if (!SOCKET_FAILED(dol->data)) {
		SocketClose(dol->data);
		dol->data = INVALID_SOCKET;
	}

	if (!SOCKET_FAILED(dol->clock)) {
		SocketClose(dol->clock);
		dol->clock = INVALID_SOCKET;
	}
}

bool GBASIODolphinConnect(struct GBASIODolphin* dol, const struct Address* address, short dataPort, short clockPort) {
	if (!SOCKET_FAILED(dol->data)) {
		SocketClose(dol->data);
		dol->data = INVALID_SOCKET;
	}
	if (!dataPort) {
		dataPort = DOLPHIN_DATA_PORT;
	}

	if (!SOCKET_FAILED(dol->clock)) {
		SocketClose(dol->clock);
		dol->clock = INVALID_SOCKET;
	}
	if (!clockPort) {
		clockPort = DOLPHIN_CLOCK_PORT;
	}

	dol->data = SocketConnectTCP(dataPort, address);
	if (SOCKET_FAILED(dol->data)) {
		return false;
	}

	dol->clock = SocketConnectTCP(clockPort, address);
	if (SOCKET_FAILED(dol->clock)) {
		SocketClose(dol->data);
		dol->data = INVALID_SOCKET;
		return false;
	}

	SocketSetBlocking(dol->data, false);
	SocketSetBlocking(dol->clock, false);
	SocketSetTCPPush(dol->data, true);
	return true;
}

static bool GBASIODolphinInit(struct GBASIODriver* driver) {
	struct GBASIODolphin* dol = (struct GBASIODolphin*) driver;
	dol->clockSlice = 0;
	dol->state = WAIT_FOR_FIRST_CLOCK;
	GBASIODolphinReset(driver);
	return true;
}

static void GBASIODolphinReset(struct GBASIODriver* driver) {
	struct GBASIODolphin* dol = (struct GBASIODolphin*) driver;
	dol->active = false;
	_flush(dol);
	mTimingDeschedule(&dol->d.p->p->timing, &dol->event);
	mTimingSchedule(&dol->d.p->p->timing, &dol->event, 0);
}

static void GBASIODolphinSetMode(struct GBASIODriver* driver, enum GBASIOMode mode) {
	struct GBASIODolphin* dol = (struct GBASIODolphin*) driver;
	dol->active = mode == GBA_SIO_JOYBUS;
}

static bool GBASIODolphinHandlesMode(struct GBASIODriver* driver, enum GBASIOMode mode) {
	UNUSED(driver);
	return mode == GBA_SIO_JOYBUS;
}

static int GBASIODolphinConnectedDevices(struct GBASIODriver* driver) {
	UNUSED(driver);
	return 1;
}

void GBASIODolphinProcessEvents(struct mTiming* timing, void* context, uint32_t cyclesLate) {
	struct GBASIODolphin* dol = context;
	if (SOCKET_FAILED(dol->data)) {
		return;
	}

	dol->clockSlice -= cyclesLate;

	int32_t clockSlice;

	int32_t nextEvent = CLOCK_GRAIN;
	switch (dol->state) {
	case WAIT_FOR_FIRST_CLOCK:
		dol->clockSlice = 0;
		// Fall through
	case WAIT_FOR_CLOCK:
		if (dol->clockSlice < 0) {
			Socket r = dol->clock;
			SocketPoll(1, &r, 0, 0, CLOCK_WAIT);
		}
		if (SocketRecv(dol->clock, &clockSlice, 4) == 4) {
			clockSlice = ntohl(clockSlice);
			dol->clockSlice += clockSlice;
			dol->state = WAIT_FOR_COMMAND;
			nextEvent = 0;
		}
		// Fall through
	case WAIT_FOR_COMMAND:
		if (dol->clockSlice < -VIDEO_TOTAL_LENGTH * 4) {
			Socket r = dol->data;
			SocketPoll(1, &r, 0, 0, CLOCK_WAIT);
		}
		if (_processCommand(dol, cyclesLate) >= 0) {
			dol->state = WAIT_FOR_CLOCK;
			nextEvent = CLOCK_GRAIN;
		}
		break;
	}

	dol->clockSlice -= nextEvent;
	mTimingSchedule(timing, &dol->event, nextEvent);
}

void _flush(struct GBASIODolphin* dol) {
	uint8_t buffer[32];
	while (SocketRecv(dol->clock, buffer, sizeof(buffer)) == sizeof(buffer));
	while (SocketRecv(dol->data, buffer, sizeof(buffer)) == sizeof(buffer));
}

int32_t _processCommand(struct GBASIODolphin* dol, uint32_t cyclesLate) {
	// This does not include the stop bits due to compatibility reasons
	int bitsOnLine = 8;
	uint8_t buffer[6];
	int gotten = SocketRecv(dol->data, buffer, 1);
	if (gotten < 1) {
		return -1;
	}

	switch (buffer[0]) {
	case JOY_RESET:
	case JOY_POLL:
		bitsOnLine += 24;
		break;
	case JOY_RECV:
		gotten = SocketRecv(dol->data, &buffer[1], 4);
		if (gotten < 4) {
			return -1;
		}
		mLOG(GBA_SIO, DEBUG, "DOL recv: %02X%02X%02X%02X", buffer[1], buffer[2], buffer[3], buffer[4]);
		// Fall through
	case JOY_TRANS:
		bitsOnLine += 40;
		break;
	}

	if (!dol->active) {
		return 0;
	}

	int sent = GBASIOJOYSendCommand(&dol->d, buffer[0], &buffer[1]);
	SocketSend(dol->data, &buffer[1], sent);

	return bitsOnLine * CYCLES_PER_BIT - cyclesLate;
}

bool GBASIODolphinIsConnected(struct GBASIODolphin* dol) {
	return dol->data != INVALID_SOCKET;
}
#else
const uint16_t DOLPHIN_CLOCK_PORT = 49420;
const uint16_t DOLPHIN_DATA_PORT = 54970;

void GBASIODolphinCreate(struct GBASIODolphin* dol) {
	memset(&dol->d, 0, sizeof(dol->d));
	dol->data = INVALID_SOCKET;
	dol->clock = INVALID_SOCKET;
	dol->active = false;
}

void GBASIODolphinDestroy(struct GBASIODolphin* dol) {
	UNUSED(dol);
}

bool GBASIODolphinConnect(struct GBASIODolphin* dol, const struct Address* address, short dataPort, short clockPort) {
	UNUSED(dol);
	UNUSED(address);
	UNUSED(dataPort);
	UNUSED(clockPort);
	return false;
}

bool GBASIODolphinIsConnected(struct GBASIODolphin* dol) {
	UNUSED(dol);
	return false;
}
#endif

/* ===== Imported from reference implementation/gbp.c ===== */
static uint16_t _gbpRead(struct mKeyCallback*);
static uint16_t _gbpSioWriteSIOCNT(struct GBASIODriver* driver, uint16_t value);
static bool _gbpSioHandlesMode(struct GBASIODriver* driver, enum GBASIOMode mode);
static int _gbpSioConnectedDevices(struct GBASIODriver* driver);
static bool _gbpSioStart(struct GBASIODriver* driver);
static uint32_t _gbpSioFinishNormal32(struct GBASIODriver* driver);

static const uint8_t _logoPalette[] = {
	0xDF, 0xFF, 0x0C, 0x64, 0x0C, 0xE4, 0x2D, 0xE4, 0x4E, 0x64, 0x4E, 0xE4, 0x6E, 0xE4, 0xAF, 0x68,
	0xB0, 0xE8, 0xD0, 0x68, 0xF0, 0x68, 0x11, 0x69, 0x11, 0xE9, 0x32, 0x6D, 0x32, 0xED, 0x73, 0xED,
	0x93, 0x6D, 0x94, 0xED, 0xB4, 0x6D, 0xD5, 0xF1, 0xF5, 0x71, 0xF6, 0xF1, 0x16, 0x72, 0x57, 0x72,
	0x57, 0xF6, 0x78, 0x76, 0x78, 0xF6, 0x99, 0xF6, 0xB9, 0xF6, 0xD9, 0x76, 0xDA, 0xF6, 0x1B, 0x7B,
	0x1B, 0xFB, 0x3C, 0xFB, 0x5C, 0x7B, 0x7D, 0x7B, 0x7D, 0xFF, 0x9D, 0x7F, 0xBE, 0x7F, 0xFF, 0x7F,
	0x2D, 0x64, 0x8E, 0x64, 0x8F, 0xE8, 0xF1, 0xE8, 0x52, 0x6D, 0x73, 0x6D, 0xB4, 0xF1, 0x16, 0xF2,
	0x37, 0x72, 0x98, 0x76, 0xFA, 0x7A, 0xFA, 0xFA, 0x5C, 0xFB, 0xBE, 0xFF, 0xDE, 0x7F, 0xFF, 0xFF,
	0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

static const uint32_t _logoHash = 0xEEDA6963;

static const uint32_t _gbpTxData[] = {
	0x0000494E, 0x0000494E,
	0xB6B1494E, 0xB6B1544E,
	0xABB1544E, 0xABB14E45,
	0xB1BA4E45, 0xB1BA4F44,
	0xB0BB4F44, 0xB0BB8002,
	0x10000010, 0x20000013,
	0x30000003
};

void GBASIOPlayerInit(struct GBASIOPlayer* gbp) {
	gbp->callback.d.readKeys = _gbpRead;
	gbp->callback.d.requireOpposingDirections = true;
	gbp->callback.p = gbp;
	memset(&gbp->d, 0, sizeof(gbp->d));
	gbp->d.writeSIOCNT = _gbpSioWriteSIOCNT;
	gbp->d.handlesMode = _gbpSioHandlesMode;
	gbp->d.connectedDevices = _gbpSioConnectedDevices;
	gbp->d.start = _gbpSioStart;
	gbp->d.finishNormal32 = _gbpSioFinishNormal32;
}

void GBASIOPlayerReset(struct GBASIOPlayer* gbp) {
	if (gbp->p->sio.driver == &gbp->d) {
		GBASIOSetDriver(&gbp->p->sio, NULL);
	}
}

bool GBASIOPlayerCheckScreen(const struct GBAVideo* video) {
	if (memcmp(video->palette, _logoPalette, sizeof(_logoPalette)) != 0) {
		return false;
	}
	uint32_t hash = hash32(&video->renderer->vram[0x4000], 0x4000, 0);
	return hash == _logoHash;
}

void GBASIOPlayerUpdate(struct GBA* gba) {
	if (gba->memory.hw.devices & HW_GB_PLAYER) {
		if (GBASIOPlayerCheckScreen(&gba->video)) {
			++gba->sio.gbp.inputsPosted;
			gba->sio.gbp.inputsPosted %= 3;
		} else {
			gba->keyCallback = gba->sio.gbp.oldCallback;
		}
		gba->sio.gbp.txPosition = 0;
		return;
	}
	if (gba->keyCallback) {
		return;
	}
	if (GBASIOPlayerCheckScreen(&gba->video)) {
		gba->memory.hw.devices |= HW_GB_PLAYER;
		gba->sio.gbp.inputsPosted = 0;
		gba->sio.gbp.oldCallback = gba->keyCallback;
		gba->keyCallback = &gba->sio.gbp.callback.d;
		if (!gba->sio.driver) {
			GBASIOSetDriver(&gba->sio, &gba->sio.gbp.d);
		}
	}
}

uint16_t _gbpRead(struct mKeyCallback* callback) {
	struct GBASIOPlayerKeyCallback* gbpCallback = (struct GBASIOPlayerKeyCallback*) callback;
	if (gbpCallback->p->inputsPosted == 2) {
		return 0xF0;
	}
	return 0;
}

uint16_t _gbpSioWriteSIOCNT(struct GBASIODriver* driver, uint16_t value) {
	UNUSED(driver);
	return value & 0x78FB;
}

bool _gbpSioStart(struct GBASIODriver* driver) {
	struct GBASIOPlayer* gbp = (struct GBASIOPlayer*) driver;
	uint32_t rx = gbp->p->memory.io[GBA_REG(SIODATA32_LO)] | (gbp->p->memory.io[GBA_REG(SIODATA32_HI)] << 16);
	if (gbp->txPosition < 12 && gbp->txPosition > 0) {
		// TODO: Check expected
	} else if (gbp->txPosition >= 12) {
		// 0x00 = Stop
		// 0x11 = Hard Stop
		// 0x22 = Start
		if (gbp->p->rumble) {
			int32_t currentTime = mTimingCurrentTime(&gbp->p->timing);
			gbp->p->rumble->setRumble(gbp->p->rumble, (rx & 0x33) == 0x22, currentTime - gbp->p->lastRumble);
			gbp->p->lastRumble = currentTime;
		}
	}
	return true;
}

static bool _gbpSioHandlesMode(struct GBASIODriver* driver, enum GBASIOMode mode) {
	UNUSED(driver);
	return mode == GBA_SIO_NORMAL_32;
}

static int _gbpSioConnectedDevices(struct GBASIODriver* driver) {
	UNUSED(driver);
	return 1;
}

uint32_t _gbpSioFinishNormal32(struct GBASIODriver* driver) {
	struct GBASIOPlayer* gbp = (struct GBASIOPlayer*) driver;
	uint32_t tx = 0;
	int txPosition = gbp->txPosition;
	if (txPosition > 16) {
		gbp->txPosition = 0;
		txPosition = 0;
	} else if (txPosition > 12) {
		txPosition = 12;
	}
	tx = _gbpTxData[txPosition];
	++gbp->txPosition;
	return tx;
}
