# メモリ実装差分メモ（mGBA参照）

参照元（2026-04-01 取得）:
- `reference implementation/memory.c`（mGBA系挙動）

## 今回詰めた差分

- VRAMアドレスデコードをGBAのミラー仕様に寄せた。
  - `0x06000000-0x06017FFF`: 線形96KB
  - `0x06018000-0x0601FFFF`: `0x06010000-0x06017FFF` ミラー
- `Write8` の仕様差分をmGBA寄りに補正した。
  - Palette RAM byte write: 同一byteを半wordに複製して16-bit書き込み
  - VRAM byte write: 同一byteを半wordに複製して16-bit書き込み
  - OAM byte write: 無効（書き込みしない）
- `Read32/Write32` を 16-bit×2 経由から分離し、バス待機加算を 32-bit 1アクセスとして集計する形へ補正。
- IOの`Write8`を `WriteIO16` 経由に統一し、WAITCNT/IF/Timer/DMA 等の副作用経路を1箇所へ集約。
- IOの主要レジスタ書き込み制約を追加（`VCOUNT/KEYINPUT` read-only, `DISPSTAT` status bit保持, `IE/WAITCNT/IME` マスク）。
- 追加のPPU/ブレンド/タイマ制約を反映（`DISPCNT` bit3固定, `WININ/WINOUT`, `BLDCNT/BLDALPHA/BLDY`, `TMxCNT_H` マスク）。
- BG2/BG3 参照座標レジスタ高位half (`BG2X/Y`, `BG3X/Y` の +2側) を 12-bit 断片としてマスクし、無効上位bitを抑止。
- 追加で `BG0/1CNT`, `MOSAIC`, `KEYCNT`, `DMAxCNT_H` の有効bitマスクを反映し、無効bit書込みを抑制。
- `WriteIO8` を独立化し、`IF` byte単位W1C / `IME` 上位byte無視 / `IE`・`WAITCNT` 上位byteマスク / `DISPSTAT` 下位status保持 を個別処理。
- さらに `SOUNDBIAS`, `NR52(SOUNDCNT_X)`, `RCNT` のマスク/読取専用bit保持を追加。
- FIFO A/B (`0x0A0..0x0A7`) へのIO書込みで音声FIFOへバイト投入し、`SOUNDCNT_H` のFIFO reset bitでキューをクリアする挙動を反映。
- bitmap mode(3/4/5) 時の VRAM `0x06018000-0x0601BFFF` を無効窓として扱い、readはopen-bus相当/ writeは破棄する mGBA寄り挙動を反映。
- BIOS外実行時の BIOS read で `bios_fetch_latch_` を返す経路を追加し、命令フェッチ起点ラッチに近い挙動へ補正。
- `bios_fetch_latch_` 更新を `RunCpuSlice` の実フェッチ点に寄せ、データread経路での過剰更新を抑制。
- `Read32` の open-bus 更新値を「回転後値」ではなく「バス生値(raw)」でラッチするよう補正し、非アライン読出し時のラッチ汚染を抑止。
- DMA SAD/DAD レジスタ書込み時にチャンネル別アドレス有効bitマスク（27/28bit）を適用し、無効上位bitを正規化。

## まだ残る主な差分（優先度高）

- BIOS read ラッチ更新タイミング（prefetch段の更新規則）を実機/参照実装に合わせてさらに厳密化する。
- APU/SIO/PPU周辺IOレジスタの書き込みマスクを mGBA テーブル準拠で最終網羅する（残りは一部マイナーbit差分）。
