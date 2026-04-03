#if !defined(__cplusplus)
#include "../gba_core.h"
/* C-only builds use the C++ aggregated core path; module implementation is intentionally disabled here. */
#else
#include "../gba_core.h"
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

/* ===== Imported from reference implementation/arm.c ===== */

void ARMSetPrivilegeMode(struct ARMCore* cpu, enum PrivilegeMode mode) {
	if (mode == cpu->privilegeMode) {
		// Not switching modes after all
		return;
	}

	enum RegisterBank newBank = ARMSelectBank(mode);
	enum RegisterBank oldBank = ARMSelectBank(cpu->privilegeMode);
	if (newBank != oldBank) {
		// Switch banked registers
		if (mode == MODE_FIQ || cpu->privilegeMode == MODE_FIQ) {
			int oldFIQBank = oldBank == BANK_FIQ;
			int newFIQBank = newBank == BANK_FIQ;
			cpu->bankedRegisters[oldFIQBank][2] = cpu->gprs[8];
			cpu->bankedRegisters[oldFIQBank][3] = cpu->gprs[9];
			cpu->bankedRegisters[oldFIQBank][4] = cpu->gprs[10];
			cpu->bankedRegisters[oldFIQBank][5] = cpu->gprs[11];
			cpu->bankedRegisters[oldFIQBank][6] = cpu->gprs[12];
			cpu->gprs[8] = cpu->bankedRegisters[newFIQBank][2];
			cpu->gprs[9] = cpu->bankedRegisters[newFIQBank][3];
			cpu->gprs[10] = cpu->bankedRegisters[newFIQBank][4];
			cpu->gprs[11] = cpu->bankedRegisters[newFIQBank][5];
			cpu->gprs[12] = cpu->bankedRegisters[newFIQBank][6];
		}
		cpu->bankedRegisters[oldBank][0] = cpu->gprs[ARM_SP];
		cpu->bankedRegisters[oldBank][1] = cpu->gprs[ARM_LR];
		cpu->gprs[ARM_SP] = cpu->bankedRegisters[newBank][0];
		cpu->gprs[ARM_LR] = cpu->bankedRegisters[newBank][1];

		cpu->bankedSPSRs[oldBank] = cpu->spsr.packed;
		cpu->spsr.packed = cpu->bankedSPSRs[newBank];
	}
	cpu->privilegeMode = mode;
}

void ARMInit(struct ARMCore* cpu) {
	memset(cpu->cp, 0, sizeof(cpu->cp));
	cpu->master->init(cpu, cpu->master);
	size_t i;
	for (i = 0; i < cpu->numComponents; ++i) {
		if (cpu->components[i] && cpu->components[i]->init) {
			cpu->components[i]->init(cpu, cpu->components[i]);
		}
	}
}

void ARMDeinit(struct ARMCore* cpu) {
	if (cpu->master->deinit) {
		cpu->master->deinit(cpu->master);
	}
	size_t i;
	for (i = 0; i < cpu->numComponents; ++i) {
		if (cpu->components[i] && cpu->components[i]->deinit) {
			cpu->components[i]->deinit(cpu->components[i]);
		}
	}
}

void ARMSetComponents(struct ARMCore* cpu, struct mCPUComponent* master, int extra, struct mCPUComponent** extras) {
	cpu->master = master;
	cpu->numComponents = extra;
	cpu->components = extras;
}

void ARMHotplugAttach(struct ARMCore* cpu, size_t slot) {
	if (slot >= cpu->numComponents) {
		return;
	}
	cpu->components[slot]->init(cpu, cpu->components[slot]);
}

void ARMHotplugDetach(struct ARMCore* cpu, size_t slot) {
	if (slot >= cpu->numComponents) {
		return;
	}
	cpu->components[slot]->deinit(cpu->components[slot]);
}

void ARMReset(struct ARMCore* cpu) {
	int i;
	for (i = 0; i < 16; ++i) {
		cpu->gprs[i] = 0;
	}
	for (i = 0; i < 6; ++i) {
		cpu->bankedRegisters[i][0] = 0;
		cpu->bankedRegisters[i][1] = 0;
		cpu->bankedRegisters[i][2] = 0;
		cpu->bankedRegisters[i][3] = 0;
		cpu->bankedRegisters[i][4] = 0;
		cpu->bankedRegisters[i][5] = 0;
		cpu->bankedRegisters[i][6] = 0;
		cpu->bankedSPSRs[i] = 0;
	}

	cpu->privilegeMode = MODE_SYSTEM;
	cpu->cpsr.packed = MODE_SYSTEM;
	cpu->spsr.packed = 0;

	cpu->shifterOperand = 0;
	cpu->shifterCarryOut = 0;

	cpu->executionMode = MODE_THUMB;
	_ARMSetMode(cpu, MODE_ARM);
	ARMWritePC(cpu);

	cpu->cycles = 0;
	cpu->nextEvent = 0;
	cpu->halted = 0;

	cpu->irqh.reset(cpu);
}

void ARMRaiseIRQ(struct ARMCore* cpu) {
	if (cpu->cpsr.i) {
		return;
	}
	union PSR cpsr = cpu->cpsr;
	int instructionWidth;
	if (cpu->executionMode == MODE_THUMB) {
		instructionWidth = WORD_SIZE_THUMB;
	} else {
		instructionWidth = WORD_SIZE_ARM;
	}
	ARMSetPrivilegeMode(cpu, MODE_IRQ);
	cpu->cpsr.priv = MODE_IRQ;
	cpu->gprs[ARM_LR] = cpu->gprs[ARM_PC] - instructionWidth + WORD_SIZE_ARM;
	cpu->gprs[ARM_PC] = BASE_IRQ;
	_ARMSetMode(cpu, MODE_ARM);
	cpu->cycles += ARMWritePC(cpu);
	cpu->spsr = cpsr;
	cpu->cpsr.i = 1;
	cpu->halted = 0;
}

void ARMRaiseSWI(struct ARMCore* cpu) {
	union PSR cpsr = cpu->cpsr;
	int instructionWidth;
	if (cpu->executionMode == MODE_THUMB) {
		instructionWidth = WORD_SIZE_THUMB;
	} else {
		instructionWidth = WORD_SIZE_ARM;
	}
	ARMSetPrivilegeMode(cpu, MODE_SUPERVISOR);
	cpu->cpsr.priv = MODE_SUPERVISOR;
	cpu->gprs[ARM_LR] = cpu->gprs[ARM_PC] - instructionWidth;
	cpu->gprs[ARM_PC] = BASE_SWI;
	_ARMSetMode(cpu, MODE_ARM);
	cpu->cycles += ARMWritePC(cpu);
	cpu->spsr = cpsr;
	cpu->cpsr.i = 1;
}

void ARMRaiseUndefined(struct ARMCore* cpu) {
	union PSR cpsr = cpu->cpsr;
	int instructionWidth;
	if (cpu->executionMode == MODE_THUMB) {
		instructionWidth = WORD_SIZE_THUMB;
	} else {
		instructionWidth = WORD_SIZE_ARM;
	}
	ARMSetPrivilegeMode(cpu, MODE_UNDEFINED);
	cpu->cpsr.priv = MODE_UNDEFINED;
	cpu->gprs[ARM_LR] = cpu->gprs[ARM_PC] - instructionWidth;
	cpu->gprs[ARM_PC] = BASE_UNDEF;
	_ARMSetMode(cpu, MODE_ARM);
	cpu->cycles += ARMWritePC(cpu);
	cpu->spsr = cpsr;
	cpu->cpsr.i = 1;
}

static const uint16_t conditionLut[16] = {
	0xF0F0, // EQ [-Z--]
	0x0F0F, // NE [-z--]
	0xCCCC, // CS [--C-]
	0x3333, // CC [--c-]
	0xFF00, // MI [N---]
	0x00FF, // PL [n---]
	0xAAAA, // VS [---V]
	0x5555, // VC [---v]
	0x0C0C, // HI [-zC-]
	0xF3F3, // LS [-Z--] || [--c-]
	0xAA55, // GE [N--V] || [n--v]
	0x55AA, // LT [N--v] || [n--V]
	0x0A05, // GT [Nz-V] || [nz-v]
	0xF5FA, // LE [-Z--] || [Nz-v] || [nz-V]
	0xFFFF, // AL [----]
	0x0000 // NV
};

static inline void ARMStep(struct ARMCore* cpu) {
	uint32_t opcode = cpu->prefetch[0];
	cpu->prefetch[0] = cpu->prefetch[1];
	cpu->gprs[ARM_PC] += WORD_SIZE_ARM;
	LOAD_32(cpu->prefetch[1], cpu->gprs[ARM_PC] & cpu->memory.activeMask, cpu->memory.activeRegion);

	unsigned condition = opcode >> 28;
	if (condition != 0xE) {
		unsigned flags = cpu->cpsr.flags >> 4;
		bool conditionMet = conditionLut[condition] & (1 << flags);
		if (!conditionMet) {
			cpu->cycles += ARM_PREFETCH_CYCLES;
			return;
		}
	}
	ARMInstruction instruction = _armTable[((opcode >> 16) & 0xFF0) | ((opcode >> 4) & 0x00F)];
	instruction(cpu, opcode);
}

static inline void ThumbStep(struct ARMCore* cpu) {
	uint32_t opcode = cpu->prefetch[0];
	cpu->prefetch[0] = cpu->prefetch[1];
	cpu->gprs[ARM_PC] += WORD_SIZE_THUMB;
	LOAD_16(cpu->prefetch[1], cpu->gprs[ARM_PC] & cpu->memory.activeMask, cpu->memory.activeRegion);
	ThumbInstruction instruction = _thumbTable[opcode >> 6];
	instruction(cpu, opcode);
}

void ARMRun(struct ARMCore* cpu) {
	while (cpu->cycles >= cpu->nextEvent) {
		cpu->irqh.processEvents(cpu);
	}
	if (cpu->executionMode == MODE_THUMB) {
		ThumbStep(cpu);
	} else {
		ARMStep(cpu);
	}
	while (cpu->cycles >= cpu->nextEvent) {
		cpu->irqh.processEvents(cpu);
	}
}

void ARMRunLoop(struct ARMCore* cpu) {
	if (cpu->executionMode == MODE_THUMB) {
		while (cpu->cycles < cpu->nextEvent) {
			ThumbStep(cpu);
		}
	} else {
		while (cpu->cycles < cpu->nextEvent) {
			ARMStep(cpu);
		}
	}
	cpu->irqh.processEvents(cpu);
}

void ARMRunFake(struct ARMCore* cpu, uint32_t opcode) {
	if (cpu->executionMode == MODE_ARM) {
		cpu->gprs[ARM_PC] -= WORD_SIZE_ARM;
	} else {
		cpu->gprs[ARM_PC] -= WORD_SIZE_THUMB;
	}
	cpu->prefetch[1] = cpu->prefetch[0];
	cpu->prefetch[0] = opcode;
}

/* ===== Imported from reference implementation/decoder.c ===== */

#ifdef ENABLE_DEBUGGERS
#define ADVANCE(AMOUNT) \
	if (AMOUNT >= blen) { \
		buffer[blen - 1] = '\0'; \
		return total; \
	} \
	total += AMOUNT; \
	buffer += AMOUNT; \
	blen -= AMOUNT;

static int _decodeRegister(int reg, char* buffer, int blen);
static int _decodeRegisterList(int list, char* buffer, int blen);
static int _decodePSR(int bits, char* buffer, int blen);
static int _decodePCRelative(uint32_t address, const struct mDebuggerSymbols* symbols, uint32_t pc, bool thumbBranch, char* buffer, int blen);
static int _decodeMemory(struct ARMMemoryAccess memory, struct ARMCore* cpu, const struct mDebuggerSymbols* symbols, int pc, char* buffer, int blen);
static int _decodeShift(union ARMOperand operand, bool reg, char* buffer, int blen);

static const char* _armConditions[] = {
	"eq",
	"ne",
	"cs",
	"cc",
	"mi",
	"pl",
	"vs",
	"vc",
	"hi",
	"ls",
	"ge",
	"lt",
	"gt",
	"le",
	"al",
	"nv"
};

static int _decodeRegister(int reg, char* buffer, int blen) {
	switch (reg) {
	case ARM_SP:
		strlcpy(buffer, "sp", blen);
		return 2;
	case ARM_LR:
		strlcpy(buffer, "lr", blen);
		return 2;
	case ARM_PC:
		strlcpy(buffer, "pc", blen);
		return 2;
	case ARM_CPSR:
		strlcpy(buffer, "cpsr", blen);
		return 4;
	case ARM_SPSR:
		strlcpy(buffer, "spsr", blen);
		return 4;
	default:
		return snprintf(buffer, blen, "r%i", reg);
	}
}

static int _decodeRegisterList(int list, char* buffer, int blen) {
	if (blen <= 0) {
		return 0;
	}
	int total = 0;
	strlcpy(buffer, "{", blen);
	ADVANCE(1);
	int i;
	int start = -1;
	int end = -1;
	int written;
	for (i = 0; i <= ARM_PC; ++i) {
		if (list & 1) {
			if (start < 0) {
				start = i;
				end = i;
			} else if (end + 1 == i) {
				end = i;
			} else {
				if (end > start) {
					written = _decodeRegister(start, buffer, blen);
					ADVANCE(written);
					strlcpy(buffer, "-", blen);
					ADVANCE(1);
				}
				written = _decodeRegister(end, buffer, blen);
				ADVANCE(written);
				strlcpy(buffer, ",", blen);
				ADVANCE(1);
				start = i;
				end = i;
			}
		}
		list >>= 1;
	}
	if (start >= 0) {
		if (end > start) {
			written = _decodeRegister(start, buffer, blen);
			ADVANCE(written);
			strlcpy(buffer, "-", blen);
			ADVANCE(1);
		}
		written = _decodeRegister(end, buffer, blen);
		ADVANCE(written);
	}
	strlcpy(buffer, "}", blen);
	ADVANCE(1);
	return total;
}

static int _decodePSR(int psrBits, char* buffer, int blen) {
	if (!psrBits) {
		return 0;
	}
	int total = 0;
	strlcpy(buffer, "_", blen);
	ADVANCE(1);
	if (psrBits & ARM_PSR_C) {
		strlcpy(buffer, "c", blen);
		ADVANCE(1);
	}
	if (psrBits & ARM_PSR_X) {
		strlcpy(buffer, "x", blen);
		ADVANCE(1);
	}
	if (psrBits & ARM_PSR_S) {
		strlcpy(buffer, "s", blen);
		ADVANCE(1);
	}
	if (psrBits & ARM_PSR_F) {
		strlcpy(buffer, "f", blen);
		ADVANCE(1);
	}
	return total;
}

static int _decodePCRelative(uint32_t address, const struct mDebuggerSymbols* symbols, uint32_t pc, bool thumbBranch, char* buffer, int blen) {
	address += pc;
	const char* label = NULL;
	if (symbols) {
		label = mDebuggerSymbolReverseLookup(symbols, address, -1);
		if (!label && thumbBranch) {
			label = mDebuggerSymbolReverseLookup(symbols, address | 1, -1);
		}
	}
	if (label) {
		return strlcpy(buffer, label, blen);
	} else {
		return snprintf(buffer, blen, "0x%08X", address);
	}
}

static int _decodeMemory(struct ARMMemoryAccess memory, struct ARMCore* cpu, const struct mDebuggerSymbols* symbols, int pc, char* buffer, int blen) {
	if (blen <= 1) {
		return 0;
	}
	int total = 0;
	bool elideClose = false;
	char comment[64];
	int written;
	comment[0] = '\0';
	if (memory.format & ARM_MEMORY_REGISTER_BASE) {
		if (memory.baseReg == ARM_PC && memory.format & ARM_MEMORY_IMMEDIATE_OFFSET) {
			uint32_t addrBase = memory.format & ARM_MEMORY_OFFSET_SUBTRACT ? -memory.offset.immediate : memory.offset.immediate;
			if (!cpu || memory.format & ARM_MEMORY_STORE) {
				strlcpy(buffer, "[", blen);
				ADVANCE(1);
				written = _decodePCRelative(addrBase, symbols, pc & 0xFFFFFFFC, false, buffer, blen);
				ADVANCE(written);
			} else {
				uint32_t value;
				_decodePCRelative(addrBase, symbols, pc & 0xFFFFFFFC, false, comment, sizeof(comment));
				addrBase += pc & 0xFFFFFFFC; // Thumb does not have PC-relative LDRH/LDRB
				switch (memory.width & 7) {
				case 1:
					value = cpu->memory.load8(cpu, addrBase, NULL);
					break;
				case 2:
					value = cpu->memory.load16(cpu, addrBase, NULL);
					break;
				case 4:
					value = cpu->memory.load32(cpu, addrBase, NULL);
					break;
				default:
					// Should never be reached
					abort();
				}
				const char* label = NULL;
				if (symbols) {
					label = mDebuggerSymbolReverseLookup(symbols, value, -1);
				}
				if (label) {
					written = snprintf(buffer, blen, "=%s", label);
				} else {
					written = snprintf(buffer, blen, "=0x%08X", value);
				}
				ADVANCE(written);
				elideClose = true;
			}
		} else {
			strlcpy(buffer, "[", blen);
			ADVANCE(1);
			written = _decodeRegister(memory.baseReg, buffer, blen);
			ADVANCE(written);
			if (memory.format & (ARM_MEMORY_REGISTER_OFFSET | ARM_MEMORY_IMMEDIATE_OFFSET) && !(memory.format & ARM_MEMORY_POST_INCREMENT)) {
				strlcpy(buffer, ", ", blen);
				ADVANCE(2);
			}
		}
	} else {
		strlcpy(buffer, "[", blen);
		ADVANCE(1);
	}
	if (memory.format & ARM_MEMORY_POST_INCREMENT) {
		strlcpy(buffer, "], ", blen);
		ADVANCE(3);
		elideClose = true;
	}
	if (memory.format & ARM_MEMORY_IMMEDIATE_OFFSET && memory.baseReg != ARM_PC) {
		if (memory.format & ARM_MEMORY_OFFSET_SUBTRACT) {
			written = snprintf(buffer, blen, "#-%i", memory.offset.immediate);
			ADVANCE(written);
		} else {
			written = snprintf(buffer, blen, "#%i", memory.offset.immediate);
			ADVANCE(written);
		}
	} else if (memory.format & ARM_MEMORY_REGISTER_OFFSET) {
		if (memory.format & ARM_MEMORY_OFFSET_SUBTRACT) {
			strlcpy(buffer, "-", blen);
			ADVANCE(1);
		}
		written = _decodeRegister(memory.offset.reg, buffer, blen);
		ADVANCE(written);
	}
	if (memory.format & ARM_MEMORY_SHIFTED_OFFSET) {
		written = _decodeShift(memory.offset, false, buffer, blen);
		ADVANCE(written);
	}

	if (!elideClose) {
		strlcpy(buffer, "]", blen);
		ADVANCE(1);
	}
	if ((memory.format & (ARM_MEMORY_PRE_INCREMENT | ARM_MEMORY_WRITEBACK)) == (ARM_MEMORY_PRE_INCREMENT | ARM_MEMORY_WRITEBACK)) {
		strlcpy(buffer, "!", blen);
		ADVANCE(1);
	}
	if (comment[0]) {
		written = snprintf(buffer, blen, "  @ %s", comment);
		ADVANCE(written);
	}
	return total;
}

static int _decodeShift(union ARMOperand op, bool reg, char* buffer, int blen) {
	if (blen <= 1) {
		return 0;
	}
	int total = 0;
	strlcpy(buffer, ", ", blen);
	ADVANCE(2);
	int written;
	switch (op.shifterOp) {
	case ARM_SHIFT_LSL:
		strlcpy(buffer, "lsl ", blen);
		ADVANCE(4);
		break;
	case ARM_SHIFT_LSR:
		strlcpy(buffer, "lsr ", blen);
		ADVANCE(4);
		break;
	case ARM_SHIFT_ASR:
		strlcpy(buffer, "asr ", blen);
		ADVANCE(4);
		break;
	case ARM_SHIFT_ROR:
		strlcpy(buffer, "ror ", blen);
		ADVANCE(4);
		break;
	case ARM_SHIFT_RRX:
		strlcpy(buffer, "rrx", blen);
		ADVANCE(3);
		return total;
	}
	if (!reg) {
		written = snprintf(buffer, blen, "#%i", op.shifterImm);
	} else {
		written = _decodeRegister(op.shifterReg, buffer, blen);
	}
	ADVANCE(written);
	return total;
}

static const char* _armMnemonicStrings[] = {
	"ill",
	"adc",
	"add",
	"and",
	"asr",
	"b",
	"bic",
	"bkpt",
	"bl",
	"bx",
	"cmn",
	"cmp",
	"eor",
	"ldm",
	"ldr",
	"lsl",
	"lsr",
	"mla",
	"mov",
	"mrs",
	"msr",
	"mul",
	"mvn",
	"neg",
	"orr",
	"ror",
	"rsb",
	"rsc",
	"sbc",
	"smlal",
	"smull",
	"stm",
	"str",
	"sub",
	"swi",
	"swp",
	"teq",
	"tst",
	"umlal",
	"umull",

	"ill"
};

static const char* _armDirectionStrings[] = {
	"da",
	"ia",
	"db",
	"ib"
};

static const char* _armAccessTypeStrings[] = {
	"",
	"b",
	"h",
	"",
	"",
	"",
	"",
	"",

	"",
	"sb",
	"sh",
	"",
	"",
	"",
	"",
	"",

	"",
	"bt",
	"",
	"",
	"t",
	"",
	"",
	""
};

int ARMDisassemble(const struct ARMInstructionInfo* info, struct ARMCore* cpu, const struct mDebuggerSymbols* symbols, uint32_t pc, char* buffer, int blen) {
	const char* mnemonic = _armMnemonicStrings[info->mnemonic];
	int written;
	int total = 0;
	bool skip3 = false;
	const char* cond = "";
	if (info->condition != ARM_CONDITION_AL && info->condition < ARM_CONDITION_NV) {
		cond = _armConditions[info->condition];
	}
	const char* flags = "";
	switch (info->mnemonic) {
	case ARM_MN_LDM:
	case ARM_MN_STM:
		flags = _armDirectionStrings[MEMORY_FORMAT_TO_DIRECTION(info->memory.format)];
		break;
	case ARM_MN_LDR:
	case ARM_MN_STR:
	case ARM_MN_SWP:
		flags = _armAccessTypeStrings[info->memory.width];
		break;
	case ARM_MN_ADD:
		if ((info->operandFormat & (ARM_OPERAND_3 | ARM_OPERAND_4)) == ARM_OPERAND_IMMEDIATE_3 && info->op3.immediate == 0 && info->execMode == MODE_THUMB) {
			skip3 = true;
			mnemonic = "mov";
		}
		// Fall through
	case ARM_MN_ADC:
	case ARM_MN_AND:
	case ARM_MN_ASR:
	case ARM_MN_BIC:
	case ARM_MN_EOR:
	case ARM_MN_LSL:
	case ARM_MN_LSR:
	case ARM_MN_MLA:
	case ARM_MN_MUL:
	case ARM_MN_MOV:
	case ARM_MN_MVN:
	case ARM_MN_ORR:
	case ARM_MN_ROR:
	case ARM_MN_RSB:
	case ARM_MN_RSC:
	case ARM_MN_SBC:
	case ARM_MN_SMLAL:
	case ARM_MN_SMULL:
	case ARM_MN_SUB:
	case ARM_MN_UMLAL:
	case ARM_MN_UMULL:
		if (info->affectsCPSR && info->execMode == MODE_ARM) {
			flags = "s";
		}
		break;
	default:
		break;
	}
	written = snprintf(buffer, blen, "%s%s%s ", mnemonic, cond, flags);
	ADVANCE(written);

	switch (info->mnemonic) {
	case ARM_MN_LDM:
	case ARM_MN_STM:
		written = _decodeRegister(info->memory.baseReg, buffer, blen);
		ADVANCE(written);
		if (info->memory.format & ARM_MEMORY_WRITEBACK) {
			strlcpy(buffer, "!", blen);
			ADVANCE(1);
		}
		strlcpy(buffer, ", ", blen);
		ADVANCE(2);
		written = _decodeRegisterList(info->op1.immediate, buffer, blen);
		ADVANCE(written);
		if (info->memory.format & ARM_MEMORY_SPSR_SWAP) {
			strlcpy(buffer, "^", blen);
			ADVANCE(1);
		}
		break;
	case ARM_MN_B:
	case ARM_MN_BL:
		if (info->operandFormat & ARM_OPERAND_IMMEDIATE_1) {
			written = _decodePCRelative(info->op1.immediate, symbols, pc, true, buffer, blen);
			ADVANCE(written);
		}
		break;
	default:
		if (info->operandFormat & ARM_OPERAND_IMMEDIATE_1) {
			written = snprintf(buffer, blen, "#%i", info->op1.immediate);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_MEMORY_1) {
			written = _decodeMemory(info->memory, cpu, symbols, pc, buffer, blen);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_REGISTER_1) {
			written = _decodeRegister(info->op1.reg, buffer, blen);
			ADVANCE(written);
			if (info->op1.reg > ARM_PC) {
				written = _decodePSR(info->op1.psrBits, buffer, blen);
				ADVANCE(written);
			}
		}
		if (info->operandFormat & ARM_OPERAND_SHIFT_REGISTER_1) {
			written = _decodeShift(info->op1, true, buffer, blen);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_SHIFT_IMMEDIATE_1) {
			written = _decodeShift(info->op1, false, buffer, blen);
			ADVANCE(written);
		}
		if (info->operandFormat & ARM_OPERAND_2) {
			strlcpy(buffer, ", ", blen);
			ADVANCE(2);
		}
		if (info->operandFormat & ARM_OPERAND_IMMEDIATE_2) {
			written = snprintf(buffer, blen, "#%i", info->op2.immediate);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_MEMORY_2) {
			written = _decodeMemory(info->memory, cpu, symbols, pc, buffer, blen);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_REGISTER_2) {
			written = _decodeRegister(info->op2.reg, buffer, blen);
			ADVANCE(written);
		}
		if (info->operandFormat & ARM_OPERAND_SHIFT_REGISTER_2) {
			written = _decodeShift(info->op2, true, buffer, blen);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_SHIFT_IMMEDIATE_2) {
			written = _decodeShift(info->op2, false, buffer, blen);
			ADVANCE(written);
		}
		if (!skip3) {
			if (info->operandFormat & ARM_OPERAND_3) {
				strlcpy(buffer, ", ", blen);
				ADVANCE(2);
			}
			if (info->operandFormat & ARM_OPERAND_IMMEDIATE_3) {
				written = snprintf(buffer, blen, "#%i", info->op3.immediate);
				ADVANCE(written);
			} else if (info->operandFormat & ARM_OPERAND_MEMORY_3) {
				written = _decodeMemory(info->memory, cpu, symbols, pc, buffer, blen);
				ADVANCE(written);
			} else if (info->operandFormat & ARM_OPERAND_REGISTER_3) {
				written = _decodeRegister(info->op3.reg, buffer, blen);
				ADVANCE(written);
			}
			if (info->operandFormat & ARM_OPERAND_SHIFT_REGISTER_3) {
				written = _decodeShift(info->op3, true, buffer, blen);
				ADVANCE(written);
			} else if (info->operandFormat & ARM_OPERAND_SHIFT_IMMEDIATE_3) {
				written = _decodeShift(info->op3, false, buffer, blen);
				ADVANCE(written);
			}
		}
		if (info->operandFormat & ARM_OPERAND_4) {
			strlcpy(buffer, ", ", blen);
			ADVANCE(2);
		}
		if (info->operandFormat & ARM_OPERAND_IMMEDIATE_4) {
			written = snprintf(buffer, blen, "#%i", info->op4.immediate);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_MEMORY_4) {
			written = _decodeMemory(info->memory, cpu, symbols, pc, buffer, blen);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_REGISTER_4) {
			written = _decodeRegister(info->op4.reg, buffer, blen);
			ADVANCE(written);
		}
		if (info->operandFormat & ARM_OPERAND_SHIFT_REGISTER_4) {
			written = _decodeShift(info->op4, true, buffer, blen);
			ADVANCE(written);
		} else if (info->operandFormat & ARM_OPERAND_SHIFT_IMMEDIATE_4) {
			written = _decodeShift(info->op4, false, buffer, blen);
			ADVANCE(written);
		}
		break;
	}
	buffer[blen - 1] = '\0';
	return total;
}
#endif

uint32_t ARMResolveMemoryAccess(struct ARMInstructionInfo* info, struct ARMRegisterFile* regs, uint32_t pc) {
	uint32_t address = 0;
	int32_t offset = 0;
	if (info->memory.format & ARM_MEMORY_REGISTER_BASE) {
		if (info->memory.baseReg == ARM_PC && info->memory.format & ARM_MEMORY_IMMEDIATE_OFFSET) {
			address = pc;
		} else {
			address = regs->gprs[info->memory.baseReg];
		}
	}
	if (info->memory.format & ARM_MEMORY_POST_INCREMENT) {
		return address;
	}
	if (info->memory.format & ARM_MEMORY_IMMEDIATE_OFFSET) {
		offset = info->memory.offset.immediate;
	} else if (info->memory.format & ARM_MEMORY_REGISTER_OFFSET) {
		offset = info->memory.offset.reg == ARM_PC ? pc : (uint32_t) regs->gprs[info->memory.offset.reg];
	}
	if (info->memory.format & ARM_MEMORY_SHIFTED_OFFSET) {
		uint8_t shiftSize = info->memory.offset.shifterImm;
		switch (info->memory.offset.shifterOp) {
			case ARM_SHIFT_LSL:
				offset <<= shiftSize;
				break;
			case ARM_SHIFT_LSR:
				offset = ((uint32_t) offset) >> shiftSize;
				break;
			case ARM_SHIFT_ASR:
				offset >>= shiftSize;
				break;
			case ARM_SHIFT_ROR:
				offset = ROR(offset, shiftSize);
				break;
			case ARM_SHIFT_RRX:
				offset = (regs->cpsr.c << 31) | ((uint32_t) offset >> 1);
				break;
			default:
				break;
		};
	}
	return address + (info->memory.format & ARM_MEMORY_OFFSET_SUBTRACT ? -offset : offset);
}

/* ===== Imported from reference implementation/decoder-arm.c ===== */

#define ADDR_MODE_1_SHIFT(OP) \
	info->op3.reg = opcode & 0x0000000F; \
	info->op3.shifterOp = ARM_SHIFT_ ## OP; \
	info->operandFormat |= ARM_OPERAND_REGISTER_3; \
	if (opcode & 0x00000010) { \
		info->op3.shifterReg = (opcode >> 8) & 0xF; \
		++info->iCycles; \
		info->operandFormat |= ARM_OPERAND_SHIFT_REGISTER_3; \
	} else { \
		info->op3.shifterImm = (opcode >> 7) & 0x1F; \
		if (!info->op3.shifterImm && (ARM_SHIFT_ ## OP == ARM_SHIFT_LSR || ARM_SHIFT_ ## OP == ARM_SHIFT_ASR)) { \
			info->op3.shifterImm = 32; \
		} \
		info->operandFormat |= ARM_OPERAND_SHIFT_IMMEDIATE_3; \
	}

#define ADDR_MODE_1_LSL \
	ADDR_MODE_1_SHIFT(LSL) \
	if ((info->operandFormat & ARM_OPERAND_SHIFT_IMMEDIATE_3) && !info->op3.shifterImm) { \
		info->operandFormat &= ~ARM_OPERAND_SHIFT_IMMEDIATE_3; \
		info->op3.shifterOp = ARM_SHIFT_NONE; \
	}

#define ADDR_MODE_1_LSR ADDR_MODE_1_SHIFT(LSR)
#define ADDR_MODE_1_ASR ADDR_MODE_1_SHIFT(ASR)
#define ADDR_MODE_1_ROR \
	ADDR_MODE_1_SHIFT(ROR) \
	if ((info->operandFormat & ARM_OPERAND_SHIFT_IMMEDIATE_3) && !info->op3.shifterImm) { \
		info->op3.shifterOp = ARM_SHIFT_RRX; \
	}

#define ADDR_MODE_1_IMM \
	int rotate = (opcode & 0x00000F00) >> 7; \
	int immediate = opcode & 0x000000FF; \
	info->op3.immediate = ROR(immediate, rotate); \
	info->operandFormat |= ARM_OPERAND_IMMEDIATE_3;

#define ADDR_MODE_2_SHIFT(OP) \
	info->memory.format |= ARM_MEMORY_REGISTER_OFFSET | ARM_MEMORY_SHIFTED_OFFSET; \
	info->memory.offset.shifterOp = ARM_SHIFT_ ## OP; \
	info->memory.offset.shifterImm = (opcode >> 7) & 0x1F; \
	info->memory.offset.reg = opcode & 0x0000000F;

#define ADDR_MODE_2_LSL \
	ADDR_MODE_2_SHIFT(LSL) \
	if (!info->memory.offset.shifterImm) { \
		info->memory.format &= ~ARM_MEMORY_SHIFTED_OFFSET; \
		info->memory.offset.shifterOp = ARM_SHIFT_NONE; \
	}

#define ADDR_MODE_2_LSR ADDR_MODE_2_SHIFT(LSR) \
	if (!info->memory.offset.shifterImm) { \
		info->memory.offset.shifterImm = 32; \
	}

#define ADDR_MODE_2_ASR ADDR_MODE_2_SHIFT(ASR) \
	if (!info->memory.offset.shifterImm) { \
		info->memory.offset.shifterImm = 32; \
	}

#define ADDR_MODE_2_ROR \
	ADDR_MODE_2_SHIFT(ROR) \
	if (!info->memory.offset.shifterImm) { \
		info->memory.offset.shifterOp = ARM_SHIFT_RRX; \
	}

#define ADDR_MODE_2_IMM \
	info->memory.format |= ARM_MEMORY_IMMEDIATE_OFFSET; \
	info->memory.offset.immediate = opcode & 0x00000FFF;

#define ADDR_MODE_3_REG \
	info->memory.format |= ARM_MEMORY_REGISTER_OFFSET; \
	info->memory.offset.reg = opcode & 0x0000000F;

#define ADDR_MODE_3_IMM \
	info->memory.format |= ARM_MEMORY_IMMEDIATE_OFFSET; \
	info->memory.offset.immediate = (opcode & 0x0000000F) | ((opcode & 0x00000F00) >> 4);

#define DEFINE_DECODER_ARM(NAME, MNEMONIC, BODY) \
	static void _ARMDecode ## NAME (uint32_t opcode, struct ARMInstructionInfo* info) { \
		UNUSED(opcode); \
		info->mnemonic = ARM_MN_ ## MNEMONIC; \
		BODY; \
	}

#define DEFINE_ALU_DECODER_EX_ARM(NAME, MNEMONIC, S, SHIFTER, OTHER_AFFECTED, SKIPPED) \
	DEFINE_DECODER_ARM(NAME, MNEMONIC, \
		info->op1.reg = (opcode >> 12) & 0xF; \
		info->op2.reg = (opcode >> 16) & 0xF; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			OTHER_AFFECTED | \
			ARM_OPERAND_REGISTER_2; \
		info->affectsCPSR = S; \
		SHIFTER; \
		if (SKIPPED == 1) { \
			info->op1 = info->op2; \
			info->op2 = info->op3; \
			info->operandFormat >>= 8; \
		} else if (SKIPPED == 2) { \
			info->op2 = info->op3; \
			info->operandFormat |= info->operandFormat >> 8; \
			info->operandFormat &= ~ARM_OPERAND_3; \
		} \
		if (info->op1.reg == ARM_PC && (OTHER_AFFECTED & ARM_OPERAND_AFFECTED_1)) { \
			info->branchType = ARM_BRANCH_INDIRECT; \
		})

#define DEFINE_ALU_DECODER_ARM(NAME, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## _LSL, NAME, 0, ADDR_MODE_1_LSL, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## S_LSL, NAME, 1, ADDR_MODE_1_LSL, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## _LSR, NAME, 0, ADDR_MODE_1_LSR, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## S_LSR, NAME, 1, ADDR_MODE_1_LSR, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## _ASR, NAME, 0, ADDR_MODE_1_ASR, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## S_ASR, NAME, 1, ADDR_MODE_1_ASR, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## _ROR, NAME, 0, ADDR_MODE_1_ROR, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## S_ROR, NAME, 1, ADDR_MODE_1_ROR, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## I, NAME, 0, ADDR_MODE_1_IMM, ARM_OPERAND_AFFECTED_1, SKIPPED) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## SI, NAME, 1, ADDR_MODE_1_IMM, ARM_OPERAND_AFFECTED_1, SKIPPED)

#define DEFINE_ALU_DECODER_S_ONLY_ARM(NAME) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## _LSL, NAME, 1, ADDR_MODE_1_LSL, ARM_OPERAND_NONE, 1) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## _LSR, NAME, 1, ADDR_MODE_1_LSR, ARM_OPERAND_NONE, 1) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## _ASR, NAME, 1, ADDR_MODE_1_ASR, ARM_OPERAND_NONE, 1) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## _ROR, NAME, 1, ADDR_MODE_1_ROR, ARM_OPERAND_NONE, 1) \
	DEFINE_ALU_DECODER_EX_ARM(NAME ## I, NAME, 1, ADDR_MODE_1_IMM, ARM_OPERAND_NONE, 1)

#define DEFINE_MULTIPLY_DECODER_EX_ARM(NAME, MNEMONIC, S, OTHER_AFFECTED) \
	DEFINE_DECODER_ARM(NAME, MNEMONIC, \
		info->op1.reg = (opcode >> 16) & 0xF; \
		info->op2.reg = opcode & 0xF; \
		info->op3.reg = (opcode >> 8) & 0xF; \
		info->op4.reg = (opcode >> 12) & 0xF; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_1 | \
			ARM_OPERAND_REGISTER_2 | \
			ARM_OPERAND_REGISTER_3 | \
			OTHER_AFFECTED; \
		info->affectsCPSR = S; \
		if (info->op1.reg == ARM_PC) { \
			info->branchType = ARM_BRANCH_INDIRECT; \
		})

#define DEFINE_LONG_MULTIPLY_DECODER_EX_ARM(NAME, MNEMONIC, S) \
	DEFINE_DECODER_ARM(NAME, MNEMONIC, \
		info->op1.reg = (opcode >> 12) & 0xF; \
		info->op2.reg = (opcode >> 16) & 0xF; \
		info->op3.reg = opcode & 0xF; \
		info->op4.reg = (opcode >> 8) & 0xF; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_1 | \
			ARM_OPERAND_REGISTER_2 | \
			ARM_OPERAND_AFFECTED_2 | \
			ARM_OPERAND_REGISTER_3 | \
			ARM_OPERAND_REGISTER_4; \
		info->affectsCPSR = S; \
		if (info->op1.reg == ARM_PC) { \
			info->branchType = ARM_BRANCH_INDIRECT; \
		})

#define DEFINE_MULTIPLY_DECODER_ARM(NAME, OTHER_AFFECTED) \
	DEFINE_MULTIPLY_DECODER_EX_ARM(NAME, NAME, 0, OTHER_AFFECTED) \
	DEFINE_MULTIPLY_DECODER_EX_ARM(NAME ## S, NAME, 1, OTHER_AFFECTED)

#define DEFINE_LONG_MULTIPLY_DECODER_ARM(NAME) \
	DEFINE_LONG_MULTIPLY_DECODER_EX_ARM(NAME, NAME, 0) \
	DEFINE_LONG_MULTIPLY_DECODER_EX_ARM(NAME ## S, NAME, 1)

#define DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME, MNEMONIC, ADDRESSING_MODE, ADDRESSING_DECODING, CYCLES, TYPE, OTHER_AFFECTED) \
	DEFINE_DECODER_ARM(NAME, MNEMONIC, \
		info->op1.reg = (opcode >> 12) & 0xF; \
		info->memory.baseReg = (opcode >> 16) & 0xF; \
		info->memory.width = TYPE; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			OTHER_AFFECTED | \
			ARM_OPERAND_MEMORY_2; \
		info->memory.format = ARM_MEMORY_REGISTER_BASE | ADDRESSING_MODE; \
		ADDRESSING_DECODING; \
		if (info->op1.reg == ARM_PC && (OTHER_AFFECTED & ARM_OPERAND_AFFECTED_1)) { \
			info->branchType = ARM_BRANCH_INDIRECT; \
		} \
		if ((info->memory.format & (ARM_MEMORY_WRITEBACK | ARM_MEMORY_REGISTER_OFFSET)) == (ARM_MEMORY_WRITEBACK | ARM_MEMORY_REGISTER_OFFSET) && \
		    info->memory.offset.reg == ARM_PC) { \
			info->branchType = ARM_BRANCH_INDIRECT; \
		} \
		CYCLES;)

#define DEFINE_LOAD_STORE_DECODER_SET_ARM(NAME, MNEMONIC, ADDRESSING_MODE, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME, MNEMONIC, \
		ARM_MEMORY_POST_INCREMENT | \
		ARM_MEMORY_WRITEBACK | \
		ARM_MEMORY_OFFSET_SUBTRACT | \
		ARM_MEMORY_ ## FORMAT, \
		ADDRESSING_MODE, FORMAT ## _CYCLES, ARM_ACCESS_ ## TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME ## U, MNEMONIC, \
		ARM_MEMORY_POST_INCREMENT | \
		ARM_MEMORY_WRITEBACK | \
		ARM_MEMORY_ ## FORMAT, \
		ADDRESSING_MODE, FORMAT ## _CYCLES, ARM_ACCESS_ ## TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME ## P, MNEMONIC, \
		ARM_MEMORY_OFFSET_SUBTRACT | \
		ARM_MEMORY_ ## FORMAT, \
		ADDRESSING_MODE, FORMAT ## _CYCLES, ARM_ACCESS_ ## TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME ## PW, MNEMONIC, \
		ARM_MEMORY_PRE_INCREMENT | \
		ARM_MEMORY_WRITEBACK | \
		ARM_MEMORY_OFFSET_SUBTRACT | \
		ARM_MEMORY_ ## FORMAT, \
		ADDRESSING_MODE, FORMAT ## _CYCLES, ARM_ACCESS_ ## TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME ## PU, MNEMONIC, \
		ARM_MEMORY_ ## FORMAT, \
		ADDRESSING_MODE, FORMAT ## _CYCLES, ARM_ACCESS_ ## TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME ## PUW, MNEMONIC, \
		ARM_MEMORY_PRE_INCREMENT | \
		ARM_MEMORY_WRITEBACK | \
		ARM_MEMORY_ ## FORMAT, \
		ADDRESSING_MODE, FORMAT ## _CYCLES, ARM_ACCESS_ ## TYPE, OTHER_AFFECTED) \

#define DEFINE_LOAD_STORE_MODE_2_DECODER_ARM(NAME, MNEMONIC, FORMAT, TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_SET_ARM(NAME ## _LSL_, MNEMONIC, ADDR_MODE_2_LSL, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_SET_ARM(NAME ## _LSR_, MNEMONIC, ADDR_MODE_2_LSR, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_SET_ARM(NAME ## _ASR_, MNEMONIC, ADDR_MODE_2_ASR, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_SET_ARM(NAME ## _ROR_, MNEMONIC, ADDR_MODE_2_ROR, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_SET_ARM(NAME ## I, MNEMONIC, ADDR_MODE_2_IMM, TYPE, FORMAT, OTHER_AFFECTED)

#define DEFINE_LOAD_STORE_MODE_3_DECODER_ARM(NAME, MNEMONIC, FORMAT, TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_SET_ARM(NAME, MNEMONIC, ADDR_MODE_3_REG, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_SET_ARM(NAME ## I, MNEMONIC, ADDR_MODE_3_IMM, TYPE, FORMAT, OTHER_AFFECTED)

#define DEFINE_LOAD_STORE_T_DECODER_SET_ARM(NAME, MNEMONIC, ADDRESSING_MODE, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME, MNEMONIC, \
		ARM_MEMORY_POST_INCREMENT | \
		ARM_MEMORY_WRITEBACK | \
		ARM_MEMORY_OFFSET_SUBTRACT | \
		ARM_MEMORY_ ## FORMAT, \
		ADDRESSING_MODE, FORMAT ## _CYCLES, ARM_ACCESS_ ## TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_DECODER_EX_ARM(NAME ## U, MNEMONIC, \
		ARM_MEMORY_POST_INCREMENT | \
		ARM_MEMORY_WRITEBACK | \
		ARM_MEMORY_ ## FORMAT, \
		ADDRESSING_MODE, FORMAT ## _CYCLES, ARM_ACCESS_ ## TYPE, OTHER_AFFECTED)

#define DEFINE_LOAD_STORE_T_DECODER_ARM(NAME, MNEMONIC, FORMAT, TYPE, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_T_DECODER_SET_ARM(NAME ## _LSL_, MNEMONIC, ADDR_MODE_2_LSL, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_T_DECODER_SET_ARM(NAME ## _LSR_, MNEMONIC, ADDR_MODE_2_LSR, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_T_DECODER_SET_ARM(NAME ## _ASR_, MNEMONIC, ADDR_MODE_2_ASR, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_T_DECODER_SET_ARM(NAME ## _ROR_, MNEMONIC, ADDR_MODE_2_ROR, TYPE, FORMAT, OTHER_AFFECTED) \
	DEFINE_LOAD_STORE_T_DECODER_SET_ARM(NAME ## I, MNEMONIC, ADDR_MODE_2_IMM, TYPE, FORMAT, OTHER_AFFECTED)

#define DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME, MNEMONIC, DIRECTION, FORMAT) \
	DEFINE_DECODER_ARM(NAME, MNEMONIC, \
		info->memory.baseReg = (opcode >> 16) & 0xF; \
		info->op1.immediate = opcode & 0x0000FFFF; \
		if (info->op1.immediate & (1 << ARM_PC)) { \
			info->branchType = ARM_BRANCH_INDIRECT; \
		} \
		info->operandFormat = ARM_OPERAND_MEMORY_1; \
		info->memory.format = ARM_MEMORY_REGISTER_BASE | \
			FORMAT | \
			ARM_MEMORY_ ## DIRECTION;)


#define DEFINE_LOAD_STORE_MULTIPLE_DECODER_ARM(NAME, FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## DA,   NAME, DECREMENT_AFTER, ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## DAW,  NAME, DECREMENT_AFTER, ARM_MEMORY_WRITEBACK | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## DB,   NAME, DECREMENT_BEFORE, ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## DBW,  NAME, DECREMENT_BEFORE, ARM_MEMORY_WRITEBACK | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## IA,   NAME, INCREMENT_AFTER, ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## IAW,  NAME, INCREMENT_AFTER, ARM_MEMORY_WRITEBACK | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## IB,   NAME, INCREMENT_BEFORE, ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## IBW,  NAME, INCREMENT_BEFORE, ARM_MEMORY_WRITEBACK | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## SDA,  NAME, DECREMENT_AFTER, ARM_MEMORY_SPSR_SWAP | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## SDAW, NAME, DECREMENT_AFTER, ARM_MEMORY_WRITEBACK | ARM_MEMORY_SPSR_SWAP | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## SDB,  NAME, DECREMENT_BEFORE, ARM_MEMORY_SPSR_SWAP | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## SDBW, NAME, DECREMENT_BEFORE, ARM_MEMORY_WRITEBACK | ARM_MEMORY_SPSR_SWAP | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## SIA,  NAME, INCREMENT_AFTER, ARM_MEMORY_SPSR_SWAP | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## SIAW, NAME, INCREMENT_AFTER, ARM_MEMORY_WRITEBACK | ARM_MEMORY_SPSR_SWAP | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## SIB,  NAME, INCREMENT_BEFORE, ARM_MEMORY_SPSR_SWAP | ARM_MEMORY_ ## FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_DECODER_EX_ARM(NAME ## SIBW, NAME, INCREMENT_BEFORE, ARM_MEMORY_WRITEBACK | ARM_MEMORY_SPSR_SWAP | ARM_MEMORY_ ## FORMAT)

#define DEFINE_SWP_DECODER_ARM(NAME, TYPE) \
	DEFINE_DECODER_ARM(NAME, SWP, \
		info->memory.baseReg = (opcode >> 16) & 0xF; \
		info->op1.reg = (opcode >> 12) & 0xF; \
		info->op2.reg = opcode & 0xF; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_1 | \
			ARM_OPERAND_REGISTER_2 | \
			ARM_OPERAND_MEMORY_3 | ARM_OPERAND_AFFECTED_3; \
		info->memory.format = ARM_MEMORY_REGISTER_BASE | ARM_MEMORY_SWAP; \
		info->memory.width = TYPE;)

DEFINE_ALU_DECODER_ARM(ADD, 0)
DEFINE_ALU_DECODER_ARM(ADC, 0)
DEFINE_ALU_DECODER_ARM(AND, 0)
DEFINE_ALU_DECODER_ARM(BIC, 0)
DEFINE_ALU_DECODER_S_ONLY_ARM(CMN)
DEFINE_ALU_DECODER_S_ONLY_ARM(CMP)
DEFINE_ALU_DECODER_ARM(EOR, 0)
DEFINE_ALU_DECODER_ARM(MOV, 2)
DEFINE_ALU_DECODER_ARM(MVN, 2)
DEFINE_ALU_DECODER_ARM(ORR, 0)
DEFINE_ALU_DECODER_ARM(RSB, 0)
DEFINE_ALU_DECODER_ARM(RSC, 0)
DEFINE_ALU_DECODER_ARM(SBC, 0)
DEFINE_ALU_DECODER_ARM(SUB, 0)
DEFINE_ALU_DECODER_S_ONLY_ARM(TEQ)
DEFINE_ALU_DECODER_S_ONLY_ARM(TST)

// TOOD: Estimate cycles
DEFINE_MULTIPLY_DECODER_ARM(MLA, ARM_OPERAND_REGISTER_4)
DEFINE_MULTIPLY_DECODER_ARM(MUL, ARM_OPERAND_NONE)

DEFINE_LONG_MULTIPLY_DECODER_ARM(SMLAL)
DEFINE_LONG_MULTIPLY_DECODER_ARM(SMULL)
DEFINE_LONG_MULTIPLY_DECODER_ARM(UMLAL)
DEFINE_LONG_MULTIPLY_DECODER_ARM(UMULL)

// Begin load/store definitions

DEFINE_LOAD_STORE_MODE_2_DECODER_ARM(LDR, LDR, LOAD, WORD, ARM_OPERAND_AFFECTED_1)
DEFINE_LOAD_STORE_MODE_2_DECODER_ARM(LDRB, LDR, LOAD, BYTE, ARM_OPERAND_AFFECTED_1)
DEFINE_LOAD_STORE_MODE_3_DECODER_ARM(LDRH, LDR, LOAD, HALFWORD, ARM_OPERAND_AFFECTED_1)
DEFINE_LOAD_STORE_MODE_3_DECODER_ARM(LDRSB, LDR, LOAD, SIGNED_BYTE, ARM_OPERAND_AFFECTED_1)
DEFINE_LOAD_STORE_MODE_3_DECODER_ARM(LDRSH, LDR, LOAD, SIGNED_HALFWORD, ARM_OPERAND_AFFECTED_1)
DEFINE_LOAD_STORE_MODE_2_DECODER_ARM(STR, STR, STORE, WORD, ARM_OPERAND_AFFECTED_2)
DEFINE_LOAD_STORE_MODE_2_DECODER_ARM(STRB, STR, STORE, BYTE, ARM_OPERAND_AFFECTED_2)
DEFINE_LOAD_STORE_MODE_3_DECODER_ARM(STRH, STR, STORE, HALFWORD, ARM_OPERAND_AFFECTED_2)

DEFINE_LOAD_STORE_T_DECODER_ARM(LDRBT, LDR, LOAD, TRANSLATED_BYTE, ARM_OPERAND_AFFECTED_1)
DEFINE_LOAD_STORE_T_DECODER_ARM(LDRT, LDR, LOAD, TRANSLATED_WORD, ARM_OPERAND_AFFECTED_1)
DEFINE_LOAD_STORE_T_DECODER_ARM(STRBT, STR, STORE, TRANSLATED_BYTE, ARM_OPERAND_AFFECTED_2)
DEFINE_LOAD_STORE_T_DECODER_ARM(STRT, STR, STORE, TRANSLATED_WORD, ARM_OPERAND_AFFECTED_2)

DEFINE_LOAD_STORE_MULTIPLE_DECODER_ARM(LDM, LOAD)
DEFINE_LOAD_STORE_MULTIPLE_DECODER_ARM(STM, STORE)

DEFINE_SWP_DECODER_ARM(SWP, ARM_ACCESS_WORD)
DEFINE_SWP_DECODER_ARM(SWPB, ARM_ACCESS_BYTE)

// End load/store definitions

// Begin branch definitions

DEFINE_DECODER_ARM(B, B,
	int32_t offset = opcode << 8;
	info->op1.immediate = offset >> 6;
	info->operandFormat = ARM_OPERAND_IMMEDIATE_1;
	info->branchType = ARM_BRANCH;)

DEFINE_DECODER_ARM(BL, BL,
	int32_t offset = opcode << 8;
	info->op1.immediate = offset >> 6;
	info->operandFormat = ARM_OPERAND_IMMEDIATE_1;
	info->branchType = ARM_BRANCH_LINKED;)

DEFINE_DECODER_ARM(BX, BX,
	info->op1.reg = opcode & 0x0000000F;
	info->operandFormat = ARM_OPERAND_REGISTER_1;
	info->branchType = ARM_BRANCH_INDIRECT;)

// End branch definitions

// Begin coprocessor definitions

DEFINE_DECODER_ARM(CDP, ILL, info->operandFormat = ARM_OPERAND_NONE;)
DEFINE_DECODER_ARM(LDC, ILL, info->operandFormat = ARM_OPERAND_NONE;)
DEFINE_DECODER_ARM(STC, ILL, info->operandFormat = ARM_OPERAND_NONE;)
DEFINE_DECODER_ARM(MCR, ILL, info->operandFormat = ARM_OPERAND_NONE;)
DEFINE_DECODER_ARM(MRC, ILL, info->operandFormat = ARM_OPERAND_NONE;)

// Begin miscellaneous definitions

DEFINE_DECODER_ARM(BKPT, BKPT,
	info->operandFormat = ARM_OPERAND_NONE;
	info->traps = 1;) // Not strictly in ARMv4T, but here for convenience
DEFINE_DECODER_ARM(ILL, ILL,
	info->operandFormat = ARM_OPERAND_NONE;
	info->traps = 1;) // Illegal opcode

DEFINE_DECODER_ARM(MSR, MSR,
	info->affectsCPSR = 1;
	info->op1.reg = ARM_CPSR;
	info->op1.psrBits = (opcode >> 16) & ARM_PSR_MASK;
	info->op2.reg = opcode & 0x0000000F;
	info->operandFormat = ARM_OPERAND_REGISTER_1 |
		ARM_OPERAND_AFFECTED_1 |
		ARM_OPERAND_REGISTER_2;)

DEFINE_DECODER_ARM(MSRR, MSR,
	info->op1.reg = ARM_SPSR;
	info->op1.psrBits = (opcode >> 16) & ARM_PSR_MASK;
	info->op2.reg = opcode & 0x0000000F;
	info->operandFormat = ARM_OPERAND_REGISTER_1 |
		ARM_OPERAND_AFFECTED_1 |
		ARM_OPERAND_REGISTER_2;)

DEFINE_DECODER_ARM(MRS, MRS,
	info->affectsCPSR = 1;
	info->op1.reg = (opcode >> 12) & 0xF;
	info->op2.reg = ARM_CPSR;
	info->op2.psrBits = 0;
	info->operandFormat = ARM_OPERAND_REGISTER_1 |
		ARM_OPERAND_AFFECTED_1 |
		ARM_OPERAND_REGISTER_2;)

DEFINE_DECODER_ARM(MRSR, MRS,
	info->op1.reg = (opcode >> 12) & 0xF;
	info->op2.reg = ARM_SPSR;
	info->op2.psrBits = 0;
	info->operandFormat = ARM_OPERAND_REGISTER_1 |
		ARM_OPERAND_AFFECTED_1 |
		ARM_OPERAND_REGISTER_2;)

DEFINE_DECODER_ARM(MSRI, MSR,
	int rotate = (opcode & 0x00000F00) >> 7;
	int32_t operand = ROR(opcode & 0x000000FF, rotate);
	info->affectsCPSR = 1;
	info->op1.reg = ARM_CPSR;
	info->op1.psrBits = (opcode >> 16) & ARM_PSR_MASK;
	info->op2.immediate = operand;
	info->operandFormat = ARM_OPERAND_REGISTER_1 |
		ARM_OPERAND_AFFECTED_1 |
		ARM_OPERAND_IMMEDIATE_2;)

DEFINE_DECODER_ARM(MSRRI, MSR,
	int rotate = (opcode & 0x00000F00) >> 7;
	int32_t operand = ROR(opcode & 0x000000FF, rotate);
	info->op1.reg = ARM_SPSR;
	info->op1.psrBits = (opcode >> 16) & ARM_PSR_MASK;
	info->op2.immediate = operand;
	info->operandFormat = ARM_OPERAND_REGISTER_1 |
		ARM_OPERAND_AFFECTED_1 |
		ARM_OPERAND_IMMEDIATE_2;)

DEFINE_DECODER_ARM(SWI, SWI,
	info->op1.immediate = opcode & 0xFFFFFF;
	info->operandFormat = ARM_OPERAND_IMMEDIATE_1;
	info->traps = 1;)

typedef void (*ARMDecoder)(uint32_t opcode, struct ARMInstructionInfo* info);

static const ARMDecoder _armDecoderTable[0x1000] = {
	DECLARE_ARM_EMITTER_BLOCK(_ARMDecode)
};

void ARMDecodeARM(uint32_t opcode, struct ARMInstructionInfo* info) {
	memset(info, 0, sizeof(*info));
	info->execMode = MODE_ARM;
	info->opcode = opcode;
	info->branchType = ARM_BRANCH_NONE;
	info->condition = opcode >> 28;
	info->sInstructionCycles = 1;
	ARMDecoder decoder = _armDecoderTable[((opcode >> 16) & 0xFF0) | ((opcode >> 4) & 0x00F)];
	decoder(opcode, info);
}

/* ===== Imported from reference implementation/decoder-thumb.c ===== */

#define DEFINE_THUMB_DECODER(NAME, MNEMONIC, BODY) \
	static void _ThumbDecode ## NAME (uint16_t opcode, struct ARMInstructionInfo* info) { \
		UNUSED(opcode); \
		info->mnemonic = ARM_MN_ ## MNEMONIC; \
		BODY; \
	}

#define DEFINE_IMMEDIATE_5_DECODER_DATA_THUMB(NAME, MNEMONIC) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op3.immediate = (opcode >> 6) & 0x001F; \
		info->op1.reg = opcode & 0x0007; \
		info->op2.reg = (opcode >> 3) & 0x0007; \
		info->affectsCPSR = 1; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_1 | \
			ARM_OPERAND_REGISTER_2 | \
			ARM_OPERAND_IMMEDIATE_3;)

#define DEFINE_IMMEDIATE_5_DECODER_MEM_THUMB(NAME, MNEMONIC, FORMAT, WIDTH, AFFECTED) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = opcode & 0x0007; \
		info->memory.baseReg = (opcode >> 3) & 0x0007; \
		info->memory.offset.immediate = ((opcode >> 6) & 0x001F) * WIDTH; \
		info->memory.width = (enum ARMMemoryAccessType) WIDTH; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_ ## AFFECTED | \
			ARM_OPERAND_MEMORY_2; \
		info->memory.format = ARM_MEMORY_REGISTER_BASE | \
			ARM_MEMORY_IMMEDIATE_OFFSET | \
			ARM_MEMORY_ ## FORMAT; \
		FORMAT ## _CYCLES)

DEFINE_IMMEDIATE_5_DECODER_DATA_THUMB(LSL1, LSL)
DEFINE_IMMEDIATE_5_DECODER_DATA_THUMB(LSR1, LSR)
DEFINE_IMMEDIATE_5_DECODER_DATA_THUMB(ASR1, ASR)
DEFINE_IMMEDIATE_5_DECODER_MEM_THUMB(LDR1, LDR, LOAD, 4, 1)
DEFINE_IMMEDIATE_5_DECODER_MEM_THUMB(LDRB1, LDR, LOAD, 1, 1)
DEFINE_IMMEDIATE_5_DECODER_MEM_THUMB(LDRH1, LDR, LOAD, 2, 1)
DEFINE_IMMEDIATE_5_DECODER_MEM_THUMB(STR1, STR, STORE, 4, 2)
DEFINE_IMMEDIATE_5_DECODER_MEM_THUMB(STRB1, STR, STORE, 1, 2)
DEFINE_IMMEDIATE_5_DECODER_MEM_THUMB(STRH1, STR, STORE, 2, 2)

#define DEFINE_DATA_FORM_1_DECODER_THUMB(NAME, MNEMONIC) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = opcode & 0x0007; \
		info->op2.reg = (opcode >> 3) & 0x0007; \
		info->op3.reg = (opcode >> 6) & 0x0007; \
		info->affectsCPSR = 1; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_1 | \
			ARM_OPERAND_REGISTER_2 | \
			ARM_OPERAND_REGISTER_3;)

DEFINE_DATA_FORM_1_DECODER_THUMB(ADD3, ADD)
DEFINE_DATA_FORM_1_DECODER_THUMB(SUB3, SUB)

#define DEFINE_DATA_FORM_2_DECODER_THUMB(NAME, MNEMONIC) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = opcode & 0x0007; \
		info->op2.reg = (opcode >> 3) & 0x0007; \
		info->op3.immediate = (opcode >> 6) & 0x0007; \
		info->affectsCPSR = 1; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_1 | \
			ARM_OPERAND_REGISTER_2 | \
			ARM_OPERAND_IMMEDIATE_3;)

DEFINE_DATA_FORM_2_DECODER_THUMB(ADD1, ADD)
DEFINE_DATA_FORM_2_DECODER_THUMB(SUB1, SUB)

#define DEFINE_DATA_FORM_3_DECODER_THUMB(NAME, MNEMONIC, AFFECTED) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = (opcode >> 8) & 0x0007; \
		info->op2.immediate = opcode & 0x00FF; \
		info->affectsCPSR = 1; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			AFFECTED | \
			ARM_OPERAND_IMMEDIATE_2;)

DEFINE_DATA_FORM_3_DECODER_THUMB(ADD2, ADD, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_3_DECODER_THUMB(CMP1, CMP, ARM_OPERAND_NONE)
DEFINE_DATA_FORM_3_DECODER_THUMB(MOV1, MOV, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_3_DECODER_THUMB(SUB2, SUB, ARM_OPERAND_AFFECTED_1)

#define DEFINE_DATA_FORM_5_DECODER_THUMB(NAME, MNEMONIC, AFFECTED) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = opcode & 0x0007; \
		info->op2.reg = (opcode >> 3) & 0x0007; \
		info->affectsCPSR = 1; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			AFFECTED | \
			ARM_OPERAND_REGISTER_2;)

DEFINE_DATA_FORM_5_DECODER_THUMB(AND, AND, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(EOR, EOR, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(LSL2, LSL, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(LSR2, LSR, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(ASR2, ASR, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(ADC, ADC, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(SBC, SBC, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(ROR, ROR, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(TST, TST, ARM_OPERAND_NONE)
DEFINE_DATA_FORM_5_DECODER_THUMB(NEG, NEG, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(CMP2, CMP, ARM_OPERAND_NONE)
DEFINE_DATA_FORM_5_DECODER_THUMB(CMN, CMN, ARM_OPERAND_NONE)
DEFINE_DATA_FORM_5_DECODER_THUMB(ORR, ORR, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(MUL, MUL, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(BIC, BIC, ARM_OPERAND_AFFECTED_1)
DEFINE_DATA_FORM_5_DECODER_THUMB(MVN, MVN, ARM_OPERAND_AFFECTED_1)

#define DEFINE_DECODER_WITH_HIGH_EX_THUMB(NAME, H1, H2, MNEMONIC, AFFECTED, CPSR) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = (opcode & 0x0007) | H1; \
		info->op2.reg = ((opcode >> 3) & 0x0007) | H2; \
		if (info->op1.reg == ARM_PC) { \
			info->branchType = ARM_BRANCH_INDIRECT; \
		} \
		info->affectsCPSR = CPSR; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			AFFECTED | \
			ARM_OPERAND_REGISTER_2;)


#define DEFINE_DECODER_WITH_HIGH_THUMB(NAME, MNEMONIC, AFFECTED, CPSR) \
	DEFINE_DECODER_WITH_HIGH_EX_THUMB(NAME ## 00, 0, 0, MNEMONIC, AFFECTED, CPSR) \
	DEFINE_DECODER_WITH_HIGH_EX_THUMB(NAME ## 01, 0, 8, MNEMONIC, AFFECTED, CPSR) \
	DEFINE_DECODER_WITH_HIGH_EX_THUMB(NAME ## 10, 8, 0, MNEMONIC, AFFECTED, CPSR) \
	DEFINE_DECODER_WITH_HIGH_EX_THUMB(NAME ## 11, 8, 8, MNEMONIC, AFFECTED, CPSR)

DEFINE_DECODER_WITH_HIGH_THUMB(ADD4, ADD, ARM_OPERAND_AFFECTED_1, 0)
DEFINE_DECODER_WITH_HIGH_THUMB(CMP3, CMP, ARM_OPERAND_NONE, 1)
DEFINE_DECODER_WITH_HIGH_THUMB(MOV3, MOV, ARM_OPERAND_AFFECTED_1, 0)

#define DEFINE_IMMEDIATE_WITH_REGISTER_DATA_THUMB(NAME, MNEMONIC, REG) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = (opcode >> 8) & 0x0007; \
		info->op2.reg = REG; \
		info->op3.immediate = (opcode & 0x00FF) << 2; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_1 | \
			ARM_OPERAND_REGISTER_2 | \
			ARM_OPERAND_IMMEDIATE_3;)

#define DEFINE_IMMEDIATE_WITH_REGISTER_MEM_THUMB(NAME, MNEMONIC, REG, FORMAT, AFFECTED) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = (opcode >> 8) & 0x0007; \
		info->memory.baseReg = REG; \
		info->memory.offset.immediate = (opcode & 0x00FF) << 2; \
		info->memory.width = ARM_ACCESS_WORD; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_ ## AFFECTED | \
			ARM_OPERAND_MEMORY_2; \
		info->memory.format = ARM_MEMORY_REGISTER_BASE | \
			ARM_MEMORY_IMMEDIATE_OFFSET | \
			ARM_MEMORY_ ## FORMAT; \
		FORMAT ## _CYCLES;)

DEFINE_IMMEDIATE_WITH_REGISTER_MEM_THUMB(LDR3, LDR, ARM_PC, LOAD, 1)
DEFINE_IMMEDIATE_WITH_REGISTER_MEM_THUMB(LDR4, LDR, ARM_SP, LOAD, 1)
DEFINE_IMMEDIATE_WITH_REGISTER_MEM_THUMB(STR3, STR, ARM_SP, STORE, 2)

DEFINE_IMMEDIATE_WITH_REGISTER_DATA_THUMB(ADD5, ADD, ARM_PC)
DEFINE_IMMEDIATE_WITH_REGISTER_DATA_THUMB(ADD6, ADD, ARM_SP)

#define DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(NAME, MNEMONIC, FORMAT, TYPE, AFFECTED) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->memory.offset.reg = (opcode >> 6) & 0x0007; \
		info->op1.reg = opcode & 0x0007; \
		info->memory.baseReg = (opcode >> 3) & 0x0007; \
		info->memory.width = ARM_ACCESS_ ## TYPE; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_ ## AFFECTED | \
			ARM_OPERAND_MEMORY_2; \
		info->memory.format = ARM_MEMORY_REGISTER_BASE | \
			ARM_MEMORY_REGISTER_OFFSET | \
			ARM_MEMORY_ ## FORMAT; \
		FORMAT ## _CYCLES;)

DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(LDR2, LDR, LOAD, WORD, 1)
DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(LDRB2, LDR, LOAD, BYTE, 1)
DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(LDRH2, LDR, LOAD, HALFWORD, 1)
DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(LDRSB, LDR, LOAD, SIGNED_BYTE, 1)
DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(LDRSH, LDR, LOAD, SIGNED_HALFWORD, 1)
DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(STR2, STR, STORE, WORD, 2)
DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(STRB2, STR, STORE, BYTE, 2)
DEFINE_LOAD_STORE_WITH_REGISTER_THUMB(STRH2, STR, STORE, HALFWORD, 2)

// TODO: Estimate memory cycles
#define DEFINE_LOAD_STORE_MULTIPLE_EX_THUMB(NAME, RN, MNEMONIC, DIRECTION, FORMAT, ADDITIONAL_REG) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->memory.baseReg = RN; \
		info->op1.immediate = (opcode & 0xFF) | ADDITIONAL_REG; \
		if (info->op1.immediate & (1 << ARM_PC)) { \
			info->branchType = ARM_BRANCH_INDIRECT; \
		} \
		info->operandFormat = ARM_OPERAND_MEMORY_1 | ARM_OPERAND_AFFECTED_1; \
		info->memory.format = ARM_MEMORY_REGISTER_BASE | \
			ARM_MEMORY_WRITEBACK | \
			ARM_MEMORY_ ## FORMAT | \
			DIRECTION;)

#define DEFINE_LOAD_STORE_MULTIPLE_THUMB(NAME, FORMAT) \
	DEFINE_LOAD_STORE_MULTIPLE_EX_THUMB(NAME ## IA, (opcode >> 8) & 0x0007, NAME, ARM_MEMORY_INCREMENT_AFTER, FORMAT, 0)

DEFINE_LOAD_STORE_MULTIPLE_THUMB(LDM, LOAD)
DEFINE_LOAD_STORE_MULTIPLE_THUMB(STM, STORE)

#define DEFINE_CONDITIONAL_BRANCH_THUMB(COND) \
	DEFINE_THUMB_DECODER(B ## COND, B, \
		int8_t immediate = opcode; \
		info->op1.immediate = immediate << 1; \
		info->branchType = ARM_BRANCH; \
		info->condition = ARM_CONDITION_ ## COND; \
		info->operandFormat = ARM_OPERAND_IMMEDIATE_1;)

DEFINE_CONDITIONAL_BRANCH_THUMB(EQ)
DEFINE_CONDITIONAL_BRANCH_THUMB(NE)
DEFINE_CONDITIONAL_BRANCH_THUMB(CS)
DEFINE_CONDITIONAL_BRANCH_THUMB(CC)
DEFINE_CONDITIONAL_BRANCH_THUMB(MI)
DEFINE_CONDITIONAL_BRANCH_THUMB(PL)
DEFINE_CONDITIONAL_BRANCH_THUMB(VS)
DEFINE_CONDITIONAL_BRANCH_THUMB(VC)
DEFINE_CONDITIONAL_BRANCH_THUMB(LS)
DEFINE_CONDITIONAL_BRANCH_THUMB(HI)
DEFINE_CONDITIONAL_BRANCH_THUMB(GE)
DEFINE_CONDITIONAL_BRANCH_THUMB(LT)
DEFINE_CONDITIONAL_BRANCH_THUMB(GT)
DEFINE_CONDITIONAL_BRANCH_THUMB(LE)

#define DEFINE_SP_MODIFY_THUMB(NAME, MNEMONIC) \
	DEFINE_THUMB_DECODER(NAME, MNEMONIC, \
		info->op1.reg = ARM_SP; \
		info->op2.immediate = (opcode & 0x7F) << 2; \
		info->operandFormat = ARM_OPERAND_REGISTER_1 | \
			ARM_OPERAND_AFFECTED_1 | \
			ARM_OPERAND_IMMEDIATE_2;)

DEFINE_SP_MODIFY_THUMB(ADD7, ADD)
DEFINE_SP_MODIFY_THUMB(SUB4, SUB)

DEFINE_LOAD_STORE_MULTIPLE_EX_THUMB(POP, ARM_SP, LDM, ARM_MEMORY_INCREMENT_AFTER, LOAD, 0)
DEFINE_LOAD_STORE_MULTIPLE_EX_THUMB(POPR, ARM_SP, LDM, ARM_MEMORY_INCREMENT_AFTER, LOAD, 1 << ARM_PC)
DEFINE_LOAD_STORE_MULTIPLE_EX_THUMB(PUSH, ARM_SP, STM, ARM_MEMORY_DECREMENT_BEFORE, STORE, 0)
DEFINE_LOAD_STORE_MULTIPLE_EX_THUMB(PUSHR, ARM_SP, STM, ARM_MEMORY_DECREMENT_BEFORE, STORE, 1 << ARM_LR)

DEFINE_THUMB_DECODER(ILL, ILL,
	info->operandFormat = ARM_OPERAND_NONE;
	info->traps = 1;)

DEFINE_THUMB_DECODER(BKPT, BKPT,
	info->operandFormat = ARM_OPERAND_NONE;
	info->traps = 1;)

DEFINE_THUMB_DECODER(B, B,
	int16_t immediate = (opcode & 0x07FF) << 5;
	info->op1.immediate = (((int32_t) immediate) >> 4);
	info->operandFormat = ARM_OPERAND_IMMEDIATE_1;
	info->branchType = ARM_BRANCH;)

DEFINE_THUMB_DECODER(BL1, BL,
	int16_t immediate = (opcode & 0x07FF) << 5;
	info->op1.reg = ARM_LR;
	info->op2.reg = ARM_PC;
	info->op3.immediate = (((int32_t) immediate) << 7);
	info->operandFormat = ARM_OPERAND_REGISTER_1 | ARM_OPERAND_AFFECTED_1 |
		ARM_OPERAND_REGISTER_2 | ARM_OPERAND_AFFECTED_2 |
		ARM_OPERAND_IMMEDIATE_3;)

DEFINE_THUMB_DECODER(BL2, BL,
	info->op1.reg = ARM_PC;
	info->op2.reg = ARM_LR;
	info->op3.immediate = (opcode & 0x07FF) << 1;
	info->operandFormat = ARM_OPERAND_REGISTER_1 | ARM_OPERAND_AFFECTED_1 |
		ARM_OPERAND_REGISTER_2 | ARM_OPERAND_IMMEDIATE_3;
	info->branchType = ARM_BRANCH_LINKED;)

DEFINE_THUMB_DECODER(BX, BX,
	info->op1.reg = (opcode >> 3) & 0xF;
	info->operandFormat = ARM_OPERAND_REGISTER_1;
	info->branchType = ARM_BRANCH_INDIRECT;)

DEFINE_THUMB_DECODER(SWI, SWI,
	info->op1.immediate = opcode & 0xFF;
	info->operandFormat = ARM_OPERAND_IMMEDIATE_1;
	info->traps = 1;)

typedef void (*ThumbDecoder)(uint16_t opcode, struct ARMInstructionInfo* info);

static const ThumbDecoder _thumbDecoderTable[0x400] = {
	DECLARE_THUMB_EMITTER_BLOCK(_ThumbDecode)
};

void ARMDecodeThumb(uint16_t opcode, struct ARMInstructionInfo* info) {
	memset(info, 0, sizeof(*info));
	info->execMode = MODE_THUMB;
	info->opcode = opcode;
	info->branchType = ARM_BRANCH_NONE;
	info->condition = ARM_CONDITION_AL;
	info->sInstructionCycles = 1;
	ThumbDecoder decoder = _thumbDecoderTable[opcode >> 6];
	decoder(opcode, info);
}

bool ARMDecodeThumbCombine(struct ARMInstructionInfo* info1, struct ARMInstructionInfo* info2, struct ARMInstructionInfo* out) {
	if (info1->execMode != MODE_THUMB || info1->mnemonic != ARM_MN_BL) {
		return false;
	}
	if (info2->execMode != MODE_THUMB || info2->mnemonic != ARM_MN_BL) {
		return false;
	}
	if (info1->op1.reg != ARM_LR || info1->op2.reg != ARM_PC) {
		return false;
	}
	if (info2->op1.reg != ARM_PC || info2->op2.reg != ARM_LR) {
		return false;
	}
	out->op1.immediate = info1->op3.immediate | info2->op3.immediate;
	out->operandFormat = ARM_OPERAND_IMMEDIATE_1;
	out->execMode = MODE_THUMB;
	out->mnemonic = ARM_MN_BL;
	out->branchType = ARM_BRANCH_LINKED;
	out->traps = 0;
	out->affectsCPSR = 0;
	out->condition = ARM_CONDITION_AL;
	out->sDataCycles = 0;
	out->nDataCycles = 0;
	out->sInstructionCycles = 2;
	out->nInstructionCycles = 0;
	out->iCycles = 0;
	out->cCycles = 0;
	return true;
}

#endif
