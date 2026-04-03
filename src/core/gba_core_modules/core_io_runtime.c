#if defined(__cplusplus)
#include "../../../reference implementation/gba/gba.h"

void gfxUpdateBG2X() {
    gfxBG2X = (BG2X_L) | ((BG2X_H & 0x07FF) << 16);
    if (BG2X_H & 0x0800) gfxBG2X |= 0xF8000000;
}

void gfxUpdateBG2Y() {
    gfxBG2Y = (BG2Y_L) | ((BG2Y_H & 0x07FF) << 16);
    if (BG2Y_H & 0x0800) gfxBG2Y |= 0xF8000000;
}

void gfxUpdateBG3X() {
    gfxBG3X = (BG3X_L) | ((BG3X_H & 0x07FF) << 16);
    if (BG3X_H & 0x0800) gfxBG3X |= 0xF8000000;
}

void gfxUpdateBG3Y() {
    gfxBG3Y = (BG3Y_L) | ((BG3Y_H & 0x07FF) << 16);
    if (BG3Y_H & 0x0800) gfxBG3Y |= 0xF8000000;
}

void gfxNewFrame() {
    gfxUpdateBG2X();
    gfxUpdateBG2Y();
    gfxUpdateBG3X();
    gfxUpdateBG3Y();
}

void CPUUpdateWindow0()
{
    int x00 = WIN0H >> 8;
    int x01 = WIN0H & 255;

    if (x00 <= x01) {
        for (int i = 0; i < 240; i++) {
            gfxInWin0[i] = (i >= x00 && i < x01);
        }
    } else {
        for (int i = 0; i < 240; i++) {
            gfxInWin0[i] = (i >= x00 || i < x01);
        }
    }
}

void CPUUpdateWindow1()
{
    int x00 = WIN1H >> 8;
    int x01 = WIN1H & 255;

    if (x00 <= x01) {
        for (int i = 0; i < 240; i++) {
            gfxInWin1[i] = (i >= x00 && i < x01);
        }
    } else {
        for (int i = 0; i < 240; i++) {
            gfxInWin1[i] = (i >= x00 || i < x01);
        }
    }
}

extern uint32_t g_line0[240];
extern uint32_t g_line1[240];
extern uint32_t g_line2[240];
extern uint32_t g_line3[240];

#define CLEAR_ARRAY(a)                  \
    {                                   \
        uint32_t* array = (a);               \
        for (int i = 0; i < 240; i++) { \
            *array++ = 0x80000000;      \
        }                               \
    }

void CPUUpdateRenderBuffers(bool force)
{
    if (!(coreOptions.layerEnable & 0x0100) || force) {
        CLEAR_ARRAY(g_line0);
    }
    if (!(coreOptions.layerEnable & 0x0200) || force) {
        CLEAR_ARRAY(g_line1);
    }
    if (!(coreOptions.layerEnable & 0x0400) || force) {
        CLEAR_ARRAY(g_line2);
    }
    if (!(coreOptions.layerEnable & 0x0800) || force) {
        CLEAR_ARRAY(g_line3);
    }
}

void CPUUpdateRegister(uint32_t address, uint16_t value)
{
    switch (address) {
    case IO_REG_DISPCNT: { // we need to place the following code in { } because we declare & initialize variables in a case statement
        if ((value & 7) > 5) {
            // display modes above 0-5 are prohibited
            DISPCNT = (value & 7);
        }
        bool change = (0 != ((DISPCNT ^ value) & 0x80));
        bool changeBG = (0 != ((DISPCNT ^ value) & 0x0F00));
        uint16_t changeBGon = ((~DISPCNT) & value) & 0x0F00; // these layers are being activated

        DISPCNT = (value & 0xFFF7); // bit 3 can only be accessed by the BIOS to enable GBC mode
        UPDATE_REG(IO_REG_DISPCNT, DISPCNT);

        if (changeBGon) {
            layerEnableDelay = 4;
            coreOptions.layerEnable = coreOptions.layerSettings & value & (~changeBGon);
        } else {
            coreOptions.layerEnable = coreOptions.layerSettings & value;
            // CPUUpdateTicks();
        }

        windowOn = (coreOptions.layerEnable & 0x6000) ? true : false;
        if (change && !((value & 0x80))) {
            if (!(DISPSTAT & 1)) {
                //lcdTicks = 1008;
                //      VCOUNT = 0;
                //      UPDATE_REG(IO_REG_VCOUNT, VCOUNT);
                DISPSTAT &= 0xFFFC;
                UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
                CPUCompareVCOUNT();
            }
            //        (*renderLine)();
        }
        CPUUpdateRender();
        // we only care about changes in BG0-BG3
        if (changeBG) {
            CPUUpdateRenderBuffers(false);
        }
        break;
    }
    case IO_REG_DISPSTAT:
        DISPSTAT = (value & 0xFF38) | (DISPSTAT & 7);
        UPDATE_REG(IO_REG_DISPSTAT, DISPSTAT);
        break;
    case IO_REG_VCOUNT:
        // not writable
        break;
    case IO_REG_BG0CNT:
        BG0CNT = (value & 0xDFFF);
        UPDATE_REG(IO_REG_BG0CNT, BG0CNT);
        break;
    case IO_REG_BG1CNT:
        BG1CNT = (value & 0xDFFF);
        UPDATE_REG(IO_REG_BG1CNT, BG1CNT);
        break;
    case IO_REG_BG2CNT:
        BG2CNT = (value & 0xFFFF);
        UPDATE_REG(IO_REG_BG2CNT, BG2CNT);
        break;
    case IO_REG_BG3CNT:
        BG3CNT = (value & 0xFFFF);
        UPDATE_REG(IO_REG_BG3CNT, BG3CNT);
        break;
    case IO_REG_BG0HOFS:
        BG0HOFS = value & 511;
        UPDATE_REG(IO_REG_BG0HOFS, BG0HOFS);
        break;
    case IO_REG_BG0VOFS:
        BG0VOFS = value & 511;
        UPDATE_REG(IO_REG_BG0VOFS, BG0VOFS);
        break;
    case IO_REG_BG1HOFS:
        BG1HOFS = value & 511;
        UPDATE_REG(IO_REG_BG1HOFS, BG1HOFS);
        break;
    case IO_REG_BG1VOFS:
        BG1VOFS = value & 511;
        UPDATE_REG(IO_REG_BG1VOFS, BG1VOFS);
        break;
    case IO_REG_BG2HOFS:
        BG2HOFS = value & 511;
        UPDATE_REG(IO_REG_BG2HOFS, BG2HOFS);
        break;
    case IO_REG_BG2VOFS:
        BG2VOFS = value & 511;
        UPDATE_REG(IO_REG_BG2VOFS, BG2VOFS);
        break;
    case IO_REG_BG3HOFS:
        BG3HOFS = value & 511;
        UPDATE_REG(IO_REG_BG3HOFS, BG3HOFS);
        break;
    case IO_REG_BG3VOFS:
        BG3VOFS = value & 511;
        UPDATE_REG(IO_REG_BG3VOFS, BG3VOFS);
        break;

    case IO_REG_BG2PA:
        BG2PA = value;
        UPDATE_REG(IO_REG_BG2PA, BG2PA);
        break;
    case IO_REG_BG2PB:
        BG2PB = value;
        UPDATE_REG(IO_REG_BG2PB, BG2PB);
        break;
    case 0x24:
        BG2PC = value;
        UPDATE_REG(IO_REG_BG2PC, BG2PC);
        break;
    case IO_REG_BG2PD:
        BG2PD = value;
        UPDATE_REG(IO_REG_BG2PD, BG2PD);
        break;
    case IO_REG_BG2X_L:
        BG2X_L = value;
        UPDATE_REG(IO_REG_BG2X_L, BG2X_L);
        gfxUpdateBG2X();
        break;
    case IO_REG_BG2X_H:
        BG2X_H = (value & 0xFFF);
        UPDATE_REG(IO_REG_BG2X_H, BG2X_H);
        gfxUpdateBG2X();
        break;
    case IO_REG_BG2Y_L:
        BG2Y_L = value;
        UPDATE_REG(IO_REG_BG2Y_L, BG2Y_L);
        gfxUpdateBG2Y();
        break;
    case IO_REG_BG2Y_H:
        BG2Y_H = value & 0xFFF;
        UPDATE_REG(IO_REG_BG2Y_H, BG2Y_H);
        gfxUpdateBG2Y();
        break;
    case IO_REG_BG3PA:
        BG3PA = value;
        UPDATE_REG(IO_REG_BG3PA, BG3PA);
        break;
    case IO_REG_BG3PB:
        BG3PB = value;
        UPDATE_REG(IO_REG_BG3PB, BG3PB);
        break;
    case IO_REG_BG3PC:
        BG3PC = value;
        UPDATE_REG(IO_REG_BG3PC, BG3PC);
        break;
    case IO_REG_BG3PD:
        BG3PD = value;
        UPDATE_REG(IO_REG_BG3PD, BG3PD);
        break;
    case IO_REG_BG3X_L:
        BG3X_L = value;
        UPDATE_REG(IO_REG_BG3X_L, BG3X_L);
        gfxUpdateBG3X();
        break;
    case IO_REG_BG3X_H:
        BG3X_H = value & 0xFFF;
        UPDATE_REG(IO_REG_BG3X_H, BG3X_H);
        gfxUpdateBG3X();
        break;
    case IO_REG_BG3Y_L:
        BG3Y_L = value;
        UPDATE_REG(IO_REG_BG3Y_L, BG3Y_L);
        gfxUpdateBG3Y();
        break;
    case IO_REG_BG3Y_H:
        BG3Y_H = value & 0xFFF;
        UPDATE_REG(IO_REG_BG3Y_H, BG3Y_H);
        gfxUpdateBG3Y();
        break;

    case IO_REG_WIN0H:
        WIN0H = value;
        UPDATE_REG(IO_REG_WIN0H, WIN0H);
        CPUUpdateWindow0();
        break;
    case IO_REG_WIN1H:
        WIN1H = value;
        UPDATE_REG(IO_REG_WIN1H, WIN1H);
        CPUUpdateWindow1();
        break;
    case IO_REG_WIN0V:
        WIN0V = value;
        UPDATE_REG(IO_REG_WIN0V, WIN0V);
        break;
    case IO_REG_WIN1V:
        WIN1V = value;
        UPDATE_REG(IO_REG_WIN1V, WIN1V);
        break;
    case IO_REG_WININ:
        WININ = value & 0x3F3F;
        UPDATE_REG(IO_REG_WININ, WININ);
        break;
    case IO_REG_WINOUT:
        WINOUT = value & 0x3F3F;
        UPDATE_REG(IO_REG_WINOUT, WINOUT);
        break;
    case IO_REG_MOSAIC:
        MOSAIC = value;
        UPDATE_REG(IO_REG_MOSAIC, MOSAIC);
        break;
    case IO_REG_BLDCNT:
        BLDMOD = value & 0x3FFF;
        UPDATE_REG(IO_REG_BLDCNT, BLDMOD);
        fxOn = ((BLDMOD >> 6) & 3) != 0;
        CPUUpdateRender();
        break;
    case IO_REG_BLDALPHA:
        COLEV = value & 0x1F1F;
        UPDATE_REG(IO_REG_BLDALPHA, COLEV);
        break;
    case IO_REG_BLDY:
        COLY = value & 0x1F;
        UPDATE_REG(IO_REG_BLDY, COLY);
        break;

    case IO_REG_SOUND1CNT_L:
    case IO_REG_SOUND1CNT_H:
    case IO_REG_SOUND1CNT_X:
    case IO_REG_SOUND2CNT_L:
    case IO_REG_SOUND2CNT_H:
    case IO_REG_SOUND3CNT_L:
    case IO_REG_SOUND3CNT_H:
    case IO_REG_SOUND3CNT_X:
    case IO_REG_SOUND4CNT_L:
    case IO_REG_SOUND4CNT_H:
    case IO_REG_SOUNDCNT_L:
    case IO_REG_SOUNDCNT_X:
        if (address == IO_REG_SOUND1CNT_L) {
            value &= 0x007F;
        } else if (address == IO_REG_SOUND1CNT_H) {
            value &= 0xFFC0;
        } else if (address == IO_REG_SOUND1CNT_X) {
            value &= 0xFFC0;
        } else if (address == IO_REG_SOUNDCNT_L) {
            value &= 0xFF77;
        } else if (address == IO_REG_SOUNDCNT_X) {
            value &= 0x0080;
        }
        soundEvent8(address & 0xFF, (uint8_t)(value & 0xFF));
        soundEvent8((address & 0xFF) + 1, (uint8_t)(value >> 8));
        break;
    case IO_REG_SOUNDCNT_H:
    case IO_REG_SOUNDBIAS:
    case IO_REG_FIFO_A_L:
    case IO_REG_FIFO_A_H:
    case IO_REG_FIFO_B_L:
    case IO_REG_FIFO_B_H:
    case IO_REG_WAVE_RAM0_L:
    case IO_REG_WAVE_RAM0_H:
    case IO_REG_WAVE_RAM1_L:
    case IO_REG_WAVE_RAM1_H:
    case IO_REG_WAVE_RAM2_L:
    case IO_REG_WAVE_RAM2_H:
    case IO_REG_WAVE_RAM3_L:
    case IO_REG_WAVE_RAM3_H:
        soundEvent16(address & 0xFF, value);
        break;

    case IO_REG_DMA0SAD_L:
        DM0SAD_L = value;
        UPDATE_REG(IO_REG_DMA0SAD_L, DM0SAD_L);
        break;
    case IO_REG_DMA0SAD_H:
        DM0SAD_H = value & 0x07FF;
        UPDATE_REG(IO_REG_DMA0SAD_H, DM0SAD_H);
        break;
    case IO_REG_DMA0DAD_L:
        DM0DAD_L = value;
        UPDATE_REG(IO_REG_DMA0DAD_L, DM0DAD_L);
        break;
    case IO_REG_DMA0DAD_H:
        DM0DAD_H = value & 0x07FF;
        UPDATE_REG(IO_REG_DMA0DAD_H, DM0DAD_H);
        break;
    case IO_REG_DMA0CNT:
        DM0CNT_L = value & 0x3FFF;
        UPDATE_REG(IO_REG_DMA0CNT, 0);
        break;
    case IO_REG_DMA0CTL: {
        bool start = ((DM0CNT_H ^ value) & 0x8000) ? true : false;
        value &= 0xF7E0;

        DM0CNT_H = value;
        UPDATE_REG(IO_REG_DMA0CTL, DM0CNT_H);

        if (start && (value & 0x8000)) {
            dma0Source = DM0SAD_L | (DM0SAD_H << 16);
            dma0Dest = DM0DAD_L | (DM0DAD_H << 16);
            CPUCheckDMA(0, 1);
        }
    } break;

    case IO_REG_DMA1SAD_L:
        DM1SAD_L = value;
        UPDATE_REG(IO_REG_DMA1SAD_L, DM1SAD_L);
        break;
    case IO_REG_DMA1SAD_H:
        DM1SAD_H = value & 0x0FFF;
        UPDATE_REG(IO_REG_DMA1SAD_H, DM1SAD_H);
        break;
    case IO_REG_DMA1DAD_L:
        DM1DAD_L = value;
        UPDATE_REG(IO_REG_DMA1DAD_L, DM1DAD_L);
        break;
    case IO_REG_DMA1DAD_H:
        DM1DAD_H = value & 0x07FF;
        UPDATE_REG(IO_REG_DMA1DAD_H, DM1DAD_H);
        break;
    case IO_REG_DMA1CNT:
        DM1CNT_L = value & 0x3FFF;
        UPDATE_REG(IO_REG_DMA1CNT, 0);
        break;
    case IO_REG_DMA1CTL: {
        bool start = ((DM1CNT_H ^ value) & 0x8000) ? true : false;
        value &= 0xF7E0;

        DM1CNT_H = value;
        UPDATE_REG(IO_REG_DMA1CTL, DM1CNT_H);

        if (start && (value & 0x8000)) {
            dma1Source = DM1SAD_L | (DM1SAD_H << 16);
            dma1Dest = DM1DAD_L | (DM1DAD_H << 16);
            CPUCheckDMA(0, 2);
        }
    } break;

    case IO_REG_DMA2SAD_L:
        DM2SAD_L = value;
        UPDATE_REG(IO_REG_DMA2SAD_L, DM2SAD_L);
        break;
    case IO_REG_DMA2SAD_H:
        DM2SAD_H = value & 0x0FFF;
        UPDATE_REG(IO_REG_DMA2SAD_H, DM2SAD_H);
        break;
    case IO_REG_DMA2DAD_L:
        DM2DAD_L = value;
        UPDATE_REG(IO_REG_DMA2DAD_L, DM2DAD_L);
        break;
    case IO_REG_DMA2DAD_H:
        DM2DAD_H = value & 0x07FF;
        UPDATE_REG(IO_REG_DMA2DAD_H, DM2DAD_H);
        break;
    case IO_REG_DMA2CNT:
        DM2CNT_L = value & 0x3FFF;
        UPDATE_REG(IO_REG_DMA2CNT, 0);
        break;
    case IO_REG_DMA2CTL: {
        bool start = ((DM2CNT_H ^ value) & 0x8000) ? true : false;

        value &= 0xF7E0;

        DM2CNT_H = value;
        UPDATE_REG(IO_REG_DMA2CTL, DM2CNT_H);

        if (start && (value & 0x8000)) {
            dma2Source = DM2SAD_L | (DM2SAD_H << 16);
            dma2Dest = DM2DAD_L | (DM2DAD_H << 16);

            CPUCheckDMA(0, 4);
        }
    } break;

    case IO_REG_DMA3SAD_L:
        DM3SAD_L = value;
        UPDATE_REG(IO_REG_DMA3SAD_L, DM3SAD_L);
        break;
    case IO_REG_DMA3SAD_H:
        DM3SAD_H = value & 0x0FFF;
        UPDATE_REG(IO_REG_DMA3SAD_H, DM3SAD_H);
        break;
    case IO_REG_DMA3DAD_L:
        DM3DAD_L = value;
        UPDATE_REG(IO_REG_DMA3DAD_L, DM3DAD_L);
        break;
    case IO_REG_DMA3DAD_H:
        DM3DAD_H = value & 0x0FFF;
        UPDATE_REG(IO_REG_DMA3DAD_H, DM3DAD_H);
        break;
    case IO_REG_DMA3CNT:
        DM3CNT_L = value;
        UPDATE_REG(IO_REG_DMA3CNT, 0);
        break;
    case IO_REG_DMA3CTL: {
        bool start = ((DM3CNT_H ^ value) & 0x8000) ? true : false;

        value &= 0xFFE0;

        DM3CNT_H = value;
        UPDATE_REG(IO_REG_DMA3CTL, DM3CNT_H);

        if (start && (value & 0x8000)) {
            dma3Source = DM3SAD_L | (DM3SAD_H << 16);
            dma3Dest = DM3DAD_L | (DM3DAD_H << 16);
            CPUCheckDMA(0, 8);
        }
    } break;

    case IO_REG_TM0CNT_L:
        timer0Reload = value;
        interp_rate();
        break;
    case IO_REG_TM0CNT_H:
        timer0Value = value;
        timerOnOffDelay |= 1;
        cpuNextEvent = cpuTotalTicks;
        break;
    case IO_REG_TM1CNT_L:
        timer1Reload = value;
        interp_rate();
        break;
    case IO_REG_TM1CNT_H:
        timer1Value = value;
        timerOnOffDelay |= 2;
        cpuNextEvent = cpuTotalTicks;
        break;
    case IO_REG_TM2CNT_L:
        timer2Reload = value;
        break;
    case IO_REG_TM2CNT_H:
        timer2Value = value;
        timerOnOffDelay |= 4;
        cpuNextEvent = cpuTotalTicks;
        break;
    case IO_REG_TM3CNT_L:
        timer3Reload = value;
        break;
    case IO_REG_TM3CNT_H:
        timer3Value = value;
        timerOnOffDelay |= 8;
        cpuNextEvent = cpuTotalTicks;
        break;

    case COMM_SIOCNT:
#ifndef NO_LINK
        StartLink(value);
#else
        if (!g_ioMem)
            return;

        if (value & 0x80) {
            value &= 0xff7f;
            if (value & 1 && (value & 0x4000)) {
                UPDATE_REG(COMM_SIOCNT, 0xFF);
                IF |= 0x80;
                UPDATE_REG(IO_REG_IF, IF);
                value &= 0x7f7f;
            }
        }
        UPDATE_REG(COMM_SIOCNT, value);
#endif
        break;

#ifndef NO_LINK
    case COMM_SIODATA8:
        UPDATE_REG(COMM_SIODATA8, value);
        break;
#endif

    case IO_REG_KEYINPUT:
        P1 |= (value & 0x3FF);
        UPDATE_REG(IO_REG_KEYINPUT, P1);
        break;

    case IO_REG_KEYCNT:
        UPDATE_REG(IO_REG_KEYCNT, value & 0xC3FF);
        break;


    case COMM_RCNT:
#ifndef NO_LINK
        StartGPLink(value);
#else
        if (!g_ioMem)
            return;

        UPDATE_REG(COMM_RCNT, value);
#endif
        break;

#ifndef NO_LINK
    case COMM_JOYCNT: {
        uint16_t cur = READ16LE(&g_ioMem[COMM_JOYCNT]);

        if (value & JOYCNT_RESET)
            cur &= ~JOYCNT_RESET;
        if (value & JOYCNT_RECV_COMPLETE)
            cur &= ~JOYCNT_RECV_COMPLETE;
        if (value & JOYCNT_SEND_COMPLETE)
            cur &= ~JOYCNT_SEND_COMPLETE;
        if (value & JOYCNT_INT_ENABLE)
            cur |= JOYCNT_INT_ENABLE;

        UPDATE_REG(COMM_JOYCNT, cur);
    } break;

    case COMM_JOY_RECV_L:
        UPDATE_REG(COMM_JOY_RECV_L, value);
        break;
    case COMM_JOY_RECV_H:
        UPDATE_REG(COMM_JOY_RECV_H, value);
        break;

    case COMM_JOY_TRANS_L:
        UPDATE_REG(COMM_JOY_TRANS_L, value);
        UPDATE_REG(COMM_JOYSTAT, READ16LE(&g_ioMem[COMM_JOYSTAT]) | JOYSTAT_SEND);
        break;
    case COMM_JOY_TRANS_H:
        UPDATE_REG(COMM_JOY_TRANS_H, value);
        UPDATE_REG(COMM_JOYSTAT, READ16LE(&g_ioMem[COMM_JOYSTAT]) | JOYSTAT_SEND);
        break;

    case COMM_JOYSTAT:
        UPDATE_REG(COMM_JOYSTAT, (READ16LE(&g_ioMem[COMM_JOYSTAT]) & 0x0a) | (value & ~0x0a));
        break;
#endif

    case IO_REG_IE:
        IE = value & 0x3FFF;
        UPDATE_REG(IO_REG_IE, IE);
        if ((IME & 1) && (IF & IE) && armIrqEnable)
            cpuNextEvent = cpuTotalTicks;
        break;
    case IO_REG_IF:
        IF ^= (value & IF);
        UPDATE_REG(IO_REG_IF, IF);
        break;
    case IO_REG_WAITCNT: {
        memoryWait[0x0e] = memoryWaitSeq[0x0e] = gamepakRamWaitState[value & 3];

        if (!coreOptions.speedHack) {
            memoryWait[0x08] = memoryWait[0x09] = gamepakWaitState[(value >> 2) & 3];
            memoryWaitSeq[0x08] = memoryWaitSeq[0x09] = gamepakWaitState0[(value >> 4) & 1];

            memoryWait[0x0a] = memoryWait[0x0b] = gamepakWaitState[(value >> 5) & 3];
            memoryWaitSeq[0x0a] = memoryWaitSeq[0x0b] = gamepakWaitState1[(value >> 7) & 1];

            memoryWait[0x0c] = memoryWait[0x0d] = gamepakWaitState[(value >> 8) & 3];
            memoryWaitSeq[0x0c] = memoryWaitSeq[0x0d] = gamepakWaitState2[(value >> 10) & 1];
        } else {
            memoryWait[0x08] = memoryWait[0x09] = 3;
            memoryWaitSeq[0x08] = memoryWaitSeq[0x09] = 1;

            memoryWait[0x0a] = memoryWait[0x0b] = 3;
            memoryWaitSeq[0x0a] = memoryWaitSeq[0x0b] = 1;

            memoryWait[0x0c] = memoryWait[0x0d] = 3;
            memoryWaitSeq[0x0c] = memoryWaitSeq[0x0d] = 1;
        }

        for (int i = 8; i < 15; i++) {
            memoryWait32[i] = memoryWait[i] + memoryWaitSeq[i] + 1;
            memoryWaitSeq32[i] = memoryWaitSeq[i] * 2 + 1;
        }

        if ((value & 0x4000) == 0x4000) {
            busPrefetchEnable = true;
            busPrefetch = false;
            busPrefetchCount = 0;
        } else {
            busPrefetchEnable = false;
            busPrefetch = false;
            busPrefetchCount = 0;
        }
        UPDATE_REG(IO_REG_WAITCNT, value & 0x7FFF);

    } break;
    case IO_REG_IME:
        IME = value & 1;
        UPDATE_REG(IO_REG_IME, IME);
        if ((IME & 1) && (IF & IE) && armIrqEnable)
            cpuNextEvent = cpuTotalTicks;
        break;

    case IO_REG_POSTFLG:
        if (value != 0)
            value &= 0xFFFE;
        UPDATE_REG(IO_REG_POSTFLG, value);
        break;
    default:
        UPDATE_REG(address & 0x3FE, value);
        break;
    }
}

void applyTimer()
{
    if (timerOnOffDelay & 1) {
        timer0ClockReload = TIMER_TICKS[timer0Value & 3];
        if (!timer0On && (timer0Value & 0x80)) {
            // reload the counter
            TM0D = DowncastU16(timer0Reload);
            timer0Ticks = (0x10000 - TM0D) << timer0ClockReload;
            UPDATE_REG(IO_REG_TM0CNT_L, TM0D);
        }
        timer0On = timer0Value & 0x80 ? true : false;
        TM0CNT = timer0Value & 0xC7;
        interp_rate();
        UPDATE_REG(IO_REG_TM0CNT_H, TM0CNT);
        //    CPUUpdateTicks();
    }
    if (timerOnOffDelay & 2) {
        timer1ClockReload = TIMER_TICKS[timer1Value & 3];
        if (!timer1On && (timer1Value & 0x80)) {
            // reload the counter
            TM1D = DowncastU16(timer1Reload);
            timer1Ticks = (0x10000 - TM1D) << timer1ClockReload;
            UPDATE_REG(IO_REG_TM1CNT_L, TM1D);
        }
        timer1On = timer1Value & 0x80 ? true : false;
        TM1CNT = timer1Value & 0xC7;
        interp_rate();
        UPDATE_REG(IO_REG_TM1CNT_H, TM1CNT);
    }
    if (timerOnOffDelay & 4) {
        timer2ClockReload = TIMER_TICKS[timer2Value & 3];
        if (!timer2On && (timer2Value & 0x80)) {
            // reload the counter
            TM2D = DowncastU16(timer2Reload);
            timer2Ticks = (0x10000 - TM2D) << timer2ClockReload;
            UPDATE_REG(IO_REG_TM2CNT_L, TM2D);
        }
        timer2On = timer2Value & 0x80 ? true : false;
        TM2CNT = timer2Value & 0xC7;
        UPDATE_REG(IO_REG_TM2CNT_H, TM2CNT);
    }
    if (timerOnOffDelay & 8) {
        timer3ClockReload = TIMER_TICKS[timer3Value & 3];
        if (!timer3On && (timer3Value & 0x80)) {
            // reload the counter
            TM3D = DowncastU16(timer3Reload);
            timer3Ticks = (0x10000 - TM3D) << timer3ClockReload;
            UPDATE_REG(IO_REG_TM3CNT_L, TM3D);
        }
        timer3On = timer3Value & 0x80 ? true : false;
        TM3CNT = timer3Value & 0xC7;
        UPDATE_REG(IO_REG_TM3CNT_H, TM3CNT);
    }
    cpuNextEvent = CPUUpdateTicks();
    timerOnOffDelay = 0;
}

uint8_t cpuBitsSet[256];
uint8_t cpuLowestBitSet[256];

#else
/* C translation unit stub: compiled in C++ aggregate mode only. */
#endif
