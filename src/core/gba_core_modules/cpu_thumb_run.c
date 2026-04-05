#include "../common.h"

u8 rom_translation_cache[ROM_TRANSLATION_CACHE_SIZE];
u8 *rom_translation_ptr = rom_translation_cache;

u8 ram_translation_cache[RAM_TRANSLATION_CACHE_SIZE];
u8 *ram_translation_ptr = ram_translation_cache;
u32 iwram_code_min = 0xFFFFFFFF;
u32 iwram_code_max = 0xFFFFFFFF;
u32 ewram_code_min = 0xFFFFFFFF;
u32 ewram_code_max = 0xFFFFFFFF;

u8 bios_translation_cache[BIOS_TRANSLATION_CACHE_SIZE];
u8 *bios_translation_ptr = bios_translation_cache;

u32 *rom_branch_hash[ROM_BRANCH_HASH_SIZE];

u32 idle_loop_target_pc = 0xFFFFFFFF;
u32 force_pc_update_target = 0xFFFFFFFF;
u32 translation_gate_target_pc[MAX_TRANSLATION_GATES];
u32 translation_gate_targets = 0;
u32 iwram_stack_optimize = 1;
u32 allow_smc_ram_u8 = 1;
u32 allow_smc_ram_u16 = 1;
u32 allow_smc_ram_u32 = 1;

void execute_arm(u32 cycles);

u32 execute_arm_translate(u32 cycles)
{
  execute_arm(cycles);
  return cycles;
}

void init_translater()
{
}

void flush_translation_cache_ram()
{
  iwram_code_min = 0xFFFFFFFF;
  iwram_code_max = 0xFFFFFFFF;
  ewram_code_min = 0xFFFFFFFF;
  ewram_code_max = 0xFFFFFFFF;
  ram_translation_ptr = ram_translation_cache;
}

void flush_translation_cache_rom()
{
  memset(rom_branch_hash, 0, sizeof(rom_branch_hash));
  rom_translation_ptr = rom_translation_cache;
}

void flush_translation_cache_bios()
{
  bios_translation_ptr = bios_translation_cache;
}

#define cache_dump_prefix ""

void dump_translation_cache()
{
  file_open(ram_cache, cache_dump_prefix "ram_cache.bin", write);
  file_write(ram_cache, ram_translation_cache,
   ram_translation_ptr - ram_translation_cache);
  file_close(ram_cache);

  file_open(rom_cache, cache_dump_prefix "rom_cache.bin", write);
  file_write(rom_cache, rom_translation_cache,
   rom_translation_ptr - rom_translation_cache);
  file_close(rom_cache);

  file_open(bios_cache, cache_dump_prefix "bios_cache.bin", write);
  file_write(bios_cache, bios_translation_cache,
   bios_translation_ptr - bios_translation_cache);
  file_close(bios_cache);
}
