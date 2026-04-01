# CPU実装差分メモ（mGBA参照）

参照元（2026-04-01 取得）:
- `src/arm/isa-arm.c`
- `src/arm/isa-thumb.c`
- `src/arm/decoder-arm.c`
- `src/arm/decoder-thumb.c`

## ビルド対象・環境・言語（現時点確認）
- 対象端末: iOS（`GBAEmuApp` 構成）
- ビルド環境: Xcode/Apple clang を前提にした Objective-C++ / C++ 構成
- CPUコア実装言語: C++（拡張子 `.mm` を利用）

## 今回詰めた差分（拡張版）

### Thumb
- Thumb ALU register-shift（`LSL/LSR/ASR/ROR`）で `amount=0` 時に値不変・carry保持となる register-shift semantics を補正。
- Thumb high register operations (`ADD/CMP/MOV/BX`) で `Rm=PC` 参照値を `PC+4` に補正。
- Thumb format 2（`ADD/SUB register/immediate`）のデコード優先度を先頭で処理し、format 1 と衝突しないよう修正。
- Thumb format 1（`LSL/LSR/ASR immediate`）を正しいマスクで実装。
- ALU register form の `LSL/LSR/ASR/ROR` で Carry フラグ更新を実装。
- Word load (`LDR`) のアドレス非アライン時回転読み出しを実装（ARM7TDMI準拠）。
- `LDRSH` の odd address を signed byte 扱いに補正。
- `LDMIA/STMIA` の empty register list (`rlist==0`) を PC 転送 + `Rn += 0x40` の挙動に補正。
- `LDMIA` で base register が rlist に含まれる場合の writeback 例外を反映。

### ARM
- ARM register-specified shift で `shift amount=0` のとき carry保持/値不変となるセマンティクスを補正。
- ARM transfer命令で `Rn=PC` かつ writeback/post-index が絡む UNPREDICTABLE ケースを安全側で抑止（PC破壊回避）。
- ARM `BX/SWP/LDR/STR` で `Rn/Rm=PC` ベース参照値を `PC+8` に補正。
- ARM halfword/signed transfer（addr mode 3）で `Rn/Rm/Rd=PC` 系オペランド値と `Rd=PC` ロード後遷移を補正。
- ARM store系で `Rd/Rm=PC` の書き込み値を `PC+12` に補正（`STR/STM/SWP`）。
- ARM `SWP` の `Rd=PC` で分岐扱いとなるよう逐次 `PC+=4` を抑止。
- ARM data processing で `Rd=PC` のとき不要な逐次 `PC+=4` を抑止し、PC書き込み後に即時遷移。
- ARM data processing の register-specified shift で `Rm=PC` のオペランド値を `PC+12` 扱いに補正。
- ARM single data transfer（register offset / register-specified shift）で `Rm=PC` の評価を `PC+12` に補正。
- ARM block transfer writeback を `STM` と `LDM` で分離（`STM` は `Rn` が rlist に含まれても writeback、`LDM` は `Rn` ロード時writeback抑止）。
- `MSR` のフィールドマスク（c/x/s/f）を実装。
- 非特権モード時に `MSR CPSR_*` で制御領域を書き換えない制約を実装。
- `MSR CPSR_c` でモード変更時にバンク切替 (`SwitchCpuMode`) を反映。
- `LDRSH` の odd address を signed byte 扱いに補正。
- `LDM/STM` の empty register list (`rlist==0`) を PC 転送 + `±0x40` writeback 挙動に補正。
- PC 書き込み系命令（Thumb高位レジスタADD/MOV, POP{PC}, ARM/Thumbの空rlist load, ARM LDMでPC読込）で不要な `PC += 2/4` を抑止し、分岐後のPC更新を正規化。

- ARM block transfer の `S` ビット（`^`）かつ `R15` 非含有ケースで user register transfer を追加（`R8-R14` の user bank 転送を反映、FIQ時を含む）。

## まだ残る主な差分（優先度高）
- ARM block transfer の `S` ビット user banked register 転送の更なる厳密化（未検証ケースの洗い込み）。
- ARM single/block data transfer の writeback corner case（`Rn` が転送リストに含まれる場合）の精密化。
- ARM data processing における `R15` operand 時パイプライン値の厳密化。
- 例外遷移時のパイプライン flush / サイクルモデルの更なる一致化。

