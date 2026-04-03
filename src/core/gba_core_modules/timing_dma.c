#if defined(__cplusplus)
#include "../../../reference implementation/gba/gba.h"

void CPUCheckDMA(int reason, int dmamask)
{
    // DMA 0
    if ((DM0CNT_H & 0x8000) && (dmamask & 1)) {
        if (((DM0CNT_H >> 12) & 3) == reason) {
            uint32_t sourceIncrement = 4;
            uint32_t destIncrement = 4;
            switch ((DM0CNT_H >> 7) & 3) {
            case 0:
                break;
            case 1:
                sourceIncrement = (uint32_t)-4;
                break;
            case 2:
                sourceIncrement = 0;
                break;
            }
            switch ((DM0CNT_H >> 5) & 3) {
            case 0:
                break;
            case 1:
                destIncrement = (uint32_t)-4;
                break;
            case 2:
                destIncrement = 0;
                break;
            }
#ifdef GBA_LOGGING
            if (systemVerbose & VERBOSE_DMA0) {
                int count = (DM0CNT_L ? DM0CNT_L : 0x4000) << 1;
                if (DM0CNT_H & 0x0400)
                    count <<= 1;
                log("DMA0: s=%08x d=%08x c=%04x count=%08x\n", dma0Source, dma0Dest,
                    DM0CNT_H,
                    count);
            }
#endif
            doDMA(0, dma0Source, dma0Dest, sourceIncrement, destIncrement,
                DM0CNT_L ? DM0CNT_L : 0x4000,
                DM0CNT_H & 0x0400, false);

            if (DM0CNT_H & 0x4000) {
                IF |= 0x0100;
                UPDATE_REG(IO_REG_IF, IF);
                cpuNextEvent = cpuTotalTicks;
            }

            if (((DM0CNT_H >> 5) & 3) == 3) {
                dma0Dest = DM0DAD_L | (DM0DAD_H << 16);
            }

            if (!(DM0CNT_H & 0x0200) || (reason == 0)) {
                DM0CNT_H &= 0x7FFF;
                UPDATE_REG(IO_REG_DMA0CTL, DM0CNT_H);
            }
        }
    }

    // DMA 1
    if ((DM1CNT_H & 0x8000) && (dmamask & 2)) {
        if (((DM1CNT_H >> 12) & 3) == reason) {
            uint32_t sourceIncrement = 4;
            uint32_t destIncrement = 4;
            switch ((DM1CNT_H >> 7) & 3) {
            case 0:
                break;
            case 1:
                sourceIncrement = (uint32_t)-4;
                break;
            case 2:
                sourceIncrement = 0;
                break;
            }
            switch ((DM1CNT_H >> 5) & 3) {
            case 0:
                break;
            case 1:
                destIncrement = (uint32_t)-4;
                break;
            case 2:
                destIncrement = 0;
                break;
            }
            if (reason == 3) {
#ifdef GBA_LOGGING
                if (systemVerbose & VERBOSE_DMA1) {
                    log("DMA1: s=%08x d=%08x c=%04x count=%08x\n", dma1Source, dma1Dest,
                        DM1CNT_H,
                        16);
                }
#endif
                doDMA(1, dma1Source, dma1Dest, sourceIncrement, 0, 4,
                    0x0400, true);
            } else {
#ifdef GBA_LOGGING
                if (systemVerbose & VERBOSE_DMA1) {
                    int count = (DM1CNT_L ? DM1CNT_L : 0x4000) << 1;
                    if (DM1CNT_H & 0x0400)
                        count <<= 1;
                    log("DMA1: s=%08x d=%08x c=%04x count=%08x\n", dma1Source, dma1Dest,
                        DM1CNT_H,
                        count);
                }
#endif
                doDMA(1, dma1Source, dma1Dest, sourceIncrement, destIncrement,
                    DM1CNT_L ? DM1CNT_L : 0x4000,
                    DM1CNT_H & 0x0400, false);
            }

            if (DM1CNT_H & 0x4000) {
                IF |= 0x0200;
                UPDATE_REG(IO_REG_IF, IF);
                cpuNextEvent = cpuTotalTicks;
            }

            if (((DM1CNT_H >> 5) & 3) == 3) {
                dma1Dest = DM1DAD_L | (DM1DAD_H << 16);
            }

            if (!(DM1CNT_H & 0x0200) || (reason == 0)) {
                DM1CNT_H &= 0x7FFF;
                UPDATE_REG(IO_REG_DMA1CTL, DM1CNT_H);
            }
        }
    }

    // DMA 2
    if ((DM2CNT_H & 0x8000) && (dmamask & 4)) {
        if (((DM2CNT_H >> 12) & 3) == reason) {
            uint32_t sourceIncrement = 4;
            uint32_t destIncrement = 4;
            switch ((DM2CNT_H >> 7) & 3) {
            case 0:
                break;
            case 1:
                sourceIncrement = (uint32_t)-4;
                break;
            case 2:
                sourceIncrement = 0;
                break;
            }
            switch ((DM2CNT_H >> 5) & 3) {
            case 0:
                break;
            case 1:
                destIncrement = (uint32_t)-4;
                break;
            case 2:
                destIncrement = 0;
                break;
            }
            if (reason == 3) {
#ifdef GBA_LOGGING
                if (systemVerbose & VERBOSE_DMA2) {
                    int count = (4) << 2;
                    log("DMA2: s=%08x d=%08x c=%04x count=%08x\n", dma2Source, dma2Dest,
                        DM2CNT_H,
                        count);
                }
#endif
                doDMA(2, dma2Source, dma2Dest, sourceIncrement, 0, 4,
                    0x0400, true);
            } else {
#ifdef GBA_LOGGING
                if (systemVerbose & VERBOSE_DMA2) {
                    int count = (DM2CNT_L ? DM2CNT_L : 0x4000) << 1;
                    if (DM2CNT_H & 0x0400)
                        count <<= 1;
                    log("DMA2: s=%08x d=%08x c=%04x count=%08x\n", dma2Source, dma2Dest,
                        DM2CNT_H,
                        count);
                }
#endif
                doDMA(2, dma2Source, dma2Dest, sourceIncrement, destIncrement,
                    DM2CNT_L ? DM2CNT_L : 0x4000,
                    DM2CNT_H & 0x0400, false);
            }

            if (DM2CNT_H & 0x4000) {
                IF |= 0x0400;
                UPDATE_REG(IO_REG_IF, IF);
                cpuNextEvent = cpuTotalTicks;
            }

            if (((DM2CNT_H >> 5) & 3) == 3) {
                dma2Dest = DM2DAD_L | (DM2DAD_H << 16);
            }

            if (!(DM2CNT_H & 0x0200) || (reason == 0)) {
                DM2CNT_H &= 0x7FFF;
                UPDATE_REG(IO_REG_DMA2CTL, DM2CNT_H);
            }
        }
    }

    // DMA 3
    if ((DM3CNT_H & 0x8000) && (dmamask & 8)) {
        if (((DM3CNT_H >> 12) & 3) == reason) {
            uint32_t sourceIncrement = 4;
            uint32_t destIncrement = 4;
            switch ((DM3CNT_H >> 7) & 3) {
            case 0:
                break;
            case 1:
                sourceIncrement = (uint32_t)-4;
                break;
            case 2:
                sourceIncrement = 0;
                break;
            }
            switch ((DM3CNT_H >> 5) & 3) {
            case 0:
                break;
            case 1:
                destIncrement = (uint32_t)-4;
                break;
            case 2:
                destIncrement = 0;
                break;
            }
#ifdef GBA_LOGGING
            if (systemVerbose & VERBOSE_DMA3) {
                int count = (DM3CNT_L ? DM3CNT_L : 0x10000) << 1;
                if (DM3CNT_H & 0x0400)
                    count <<= 1;
                log("DMA3: s=%08x d=%08x c=%04x count=%08x\n", dma3Source, dma3Dest,
                    DM3CNT_H,
                    count);
            }
#endif
            doDMA(3, dma3Source, dma3Dest, sourceIncrement, destIncrement,
                DM3CNT_L ? DM3CNT_L : 0x10000,
                DM3CNT_H & 0x0400, false);

            if (DM3CNT_H & 0x4000) {
                IF |= 0x0800;
                UPDATE_REG(IO_REG_IF, IF);
                cpuNextEvent = cpuTotalTicks;
            }

            if (((DM3CNT_H >> 5) & 3) == 3) {
                dma3Dest = DM3DAD_L | (DM3DAD_H << 16);
            }

            if (!(DM3CNT_H & 0x0200) || (reason == 0)) {
                DM3CNT_H &= 0x7FFF;
                UPDATE_REG(IO_REG_DMA3CTL, DM3CNT_H);
            }
        }
    }
}

#else
/* C translation unit stub: compiled in C++ aggregate mode only. */
#endif
