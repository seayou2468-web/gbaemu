# BIOS起動後の初期化順序チェック（VBA-M基準）

## 結論

`src/core/gba_core_modules/core_bootstrap.c` の `CPUInit()` / `CPUReset()` は、
`reference implementation/gba/gba.cpp`（VBA-Mベース参照実装）と**関数本文が完全一致**していました。

- `CPUInit`: 完全一致
- `CPUReset`: 完全一致

比較は関数本体を抽出して文字列比較で確認しています。

## BIOS起動時の初期化順序（`CPUReset()`）

`coreOptions.useBios && !coreOptions.skipBios` が真（BIOS起動）時の主要順序は次の通りです。

1. RTC/各メモリ領域・レジスタのクリア
2. 主要IOレジスタ初期値設定（`DISPCNT`, `VCOUNT` など）
3. BIOS起動時PC設定（`reg[15] = 0x00000000`, SVCモード, IRQ無効）
4. CPSR更新、`armNextPC` 設定、内部状態初期化
5. `biosProtected` 設定、タイマ/DMA/描画状態リセット
6. メモリマップ再構成（`map[0]=g_bios` など）
7. `soundReset()`
8. Window関連更新
9. （非BIOS時は `BIOS_RegisterRamReset` を強制、BIOS時はマルチブート時のみ）
10. `flashReset()` / `eepromReset()` / `SetSaveType()`
11. `ARM_PREFETCH` ほか最終状態更新

この流れも参照実装と一致しています。

## 補足（このリポジトリ固有）

`src/core/gba_core_c_api.cpp` には、BIOS起動が長時間終わらない場合に
300フレームで `coreOptions.useBios = false` にして `CPUReset()` し直すウォッチドッグがあります。

これは **C APIレイヤのフォールバック挙動** であり、
`CPUReset()` 自体の初期化順序差分ではありません。
