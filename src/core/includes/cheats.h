#ifndef CHEATS_H
#define CHEATS_H

#ifdef __cplusplus
#include <cstdint>
#else
#include <stdint.h>
#endif

#define CHEAT_NAME_LENGTH 17

typedef enum
{
  CHEAT_TYPE_GAMESHARK_V1,
  CHEAT_TYPE_GAMESHARK_V3,
  CHEAT_TYPE_INVALID
} cheat_variant_enum;

typedef struct
{
  char cheat_name[CHEAT_NAME_LENGTH];
  uint32_t cheat_active;
  uint32_t cheat_codes[256];
  uint32_t num_cheat_lines;
  cheat_variant_enum cheat_variant;
} cheat_type;

void process_cheats();
void add_cheats(char *cheats_filename);

#ifndef MAX_CHEATS
#define MAX_CHEATS 16
#endif

extern cheat_type cheats[MAX_CHEATS];
extern uint32_t num_cheats;
int cheatsCheckKeys(uint32_t keys, uint32_t ext);

#endif
