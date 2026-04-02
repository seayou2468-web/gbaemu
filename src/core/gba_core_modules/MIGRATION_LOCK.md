# Core Migration Lock (絶対削除禁止)

このディレクトリ内の以下ファイルは、`reference implementation/` から移植した固定資産です。

## 絶対条件
- 下記ファイルは **削除禁止**。
- 下記ファイルは **空ファイル化禁止**。
- `Imported from reference implementation` コメント総数は **29** を維持すること。
- `hlebios.s` は **存在必須**。

## 対象ファイル
- core_bootstrap.c
- core_reset_state.c
- core_save_debug.c
- core_backup_runtime.c
- cpu_helpers.c
- cpu_swi.c
- cpu_arm_execute.c
- cpu_thumb_run.c
- memory_bus.c
- ppu_common.c
- ppu_bitmap_obj.c
- ppu_tile_modes.c
- timing_dma.c
- apu_interrupts.c
- render_debug.c
- hlebios.s

## 検証
`utils/verify_migration_lock.sh` を実行してください。
