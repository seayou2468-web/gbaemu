# CPU差分・網羅チェック（mGBA参照, 2026-04-01）

> 注意: これは `isa-arm.c / isa-thumb.c / decoder-arm.c / decoder-thumb.c` を基準にした**実装観点の網羅表**です。
> ビルド/実行テスト未実施のため、動作一致の最終保証ではありません。

## 0. 前提（対象端末/環境/言語）
- 対象: iOS向け GBA コア
- ビルド想定: Xcode + Apple Clang
- 実装言語: Objective-C++(.mm) / C++

## 1. ARM命令群（ARMv4T）

### 1.1 Data Processing
- [x] AND/EOR/SUB/RSB/ADD/ADC/SBC/RSC
- [x] TST/TEQ/CMP/CMN
- [x] ORR/MOV/BIC/MVN
- [x] immediate operand2 rotate
- [x] register shift immediate
- [x] register-specified shift
- [x] `Rd=PC` で逐次加算抑止
- [ ] `S` + `Rd=PC` の全モード/例外復帰パイプライン完全一致（要検証）
- [ ] `Rs=PC` / `Rm=PC` の全ケース厳密一致（一部補正済み、要網羅検証）

### 1.2 Multiply
- [x] MUL/MLA
- [x] UMULL/UMLAL/SMULL/SMLAL
- [ ] 乗算サイクル厳密モデル（値依存）

### 1.3 PSR Transfer
- [x] MRS (CPSR/SPSR)
- [x] MSR (reg/imm)
- [x] c/x/s/f mask
- [x] 非特権時制限
- [x] mode bit変更時の bank 切替
- [ ] ARM7TDMI固有の未定義動作の完全一致（要テスト）

### 1.4 Branch / Exception
- [x] B/BL
- [x] BX
- [x] SWI
- [x] UNDEF trap
- [ ] prefetch/cycle の厳密一致

### 1.5 Single Data Transfer (LDR/STR)
- [x] immediate/register offset
- [x] pre/post indexing
- [x] writeback
- [x] byte/word access
- [x] unaligned word rotate load
- [x] `Rd=PC` store値 `PC+12`
- [x] `Rn/Rm=PC` の主要補正
- [x] `Rn=PC` writeback UNPREDICTABLE を安全抑止
- [ ] 全UNPREDICTABLE組み合わせのハード一致（要命令列テスト）

### 1.6 Halfword/Signed Transfer (Addr mode 3)
- [x] LDRH/LDRSB/LDRSH/STRH
- [x] odd-address LDRSH => signed byte
- [x] `Rn/Rm/Rd=PC` の主要補正
- [x] `Rn=PC` writeback UNPREDICTABLE 抑止
- [ ] writeback corner の全一致（要網羅テスト）

### 1.7 Block Transfer (LDM/STM)
- [x] pre/post up/down
- [x] writeback 基本
- [x] empty rlist quirk (`±0x40`)
- [x] STM/LDM の writeback差異
- [x] `S` bit user transfer（R15非含有）
- [x] FIQ文脈を含む R8-R14 user bank 参照
- [x] PCロード時の逐次加算抑止
- [x] `Rn=PC` writeback UNPREDICTABLE 抑止
- [ ] 全bank切替・同時例外介入ケースの厳密一致

### 1.8 Swap
- [x] SWP/SWPB
- [x] `Rm=PC` store値補正
- [x] `Rn=PC` base補正
- [x] `Rd=PC` 遷移補正
- [ ] ロックバス/サイクル挙動の厳密一致

## 2. Thumb命令群（Thumb-1）

### 2.1 Shift/Add/Sub/ALU
- [x] format1 LSL/LSR/ASR immediate
- [x] format2 ADD/SUB（decode優先順修正）
- [x] ALU register form
- [x] shift系 carry update
- [ ] 一部flag境界値ケースの網羅テスト

### 2.2 High register ops / BX
- [x] ADD/CMP/MOV high
- [x] `Rm=PC => PC+4`
- [x] BX state switch
- [x] `Rd=PC` 逐次加算抑止

### 2.3 Load/Store
- [x] register offset
- [x] immediate offset
- [x] SP-relative
- [x] literal LDR
- [x] unaligned word rotate load
- [x] odd LDRSH => signed byte
- [ ] bus waitstate/cycle精度

### 2.4 Stack / Multiple transfer
- [x] PUSH/POP
- [x] POP{PC} 分岐扱い
- [x] STMIA/LDMIA
- [x] empty rlist quirk (+0x40)
- [x] LDMIA base in list writeback例外
- [ ] empty rlist のメモリ副作用詳細（要実機比較）

### 2.5 Branch family
- [x] B (cond/uncond)
- [x] BL pair
- [x] SWI
- [x] BKPT => UNDEF相当
- [ ] cycle/prefetch厳密一致

## 3. 現時点の「残差分（実装未確定）」
1. 値依存乗算サイクル
2. prefetch/pipeline flush のサイクル精密一致
3. UNPREDICTABLEケースの“実機寄せ”最終決定
4. 例外介入タイミングとbank反映の境界ケース
5. 一部flag境界値（演算 + PC絡み）

## 4. 100%列挙要求に対する明示
- 実行テスト無しでは「100%一致」を断言できない。
- ただし命令カテゴリ単位では上記が**現時点の全列挙**。
- 残りは主に「実装欠落」より「厳密挙動一致（cycle/pipeline/unpredictable）」。
