# gbaemu

C/C++ + Objective-C/Objective-C++ だけで構成した、GBA エミュレータ実装です。

## 構成
- `src/core/`: 共通エミュレータコア (C++)
- `src/platform/linux/`: Linux 上でテスト ROM を実行する CLI テストランナー
- `src/platform/ios/`: iOS 向け UIKit フロントエンド (ObjC / ObjC++)
- `utils/testroms/`: テストに使う `.gba` ROM
- `utils/info.txt`: 参考サイト

## Linux での通常テスト
```bash
make linux_test
```

このコマンドは:
1. C++ コアをビルド
2. `utils/testroms` の ROM を列挙
3. 各 ROM を読み込み、ヘッダ検証(固定値/ロゴ/補数チェック) + 5 フレーム実行を行いログ出力

## CPU 実装の現状 (ARM/Thumb)
- ARM:
  - 条件分岐/BX/BL
  - データ処理命令の対応拡張 (AND/EOR/SUB/RSB/ADD/ADC/SBC/TST/TEQ/CMP/CMN/ORR/MOV/BIC/MVN)
  - 即値シフタ + レジスタシフタ (LSL/LSR/ASR/ROR/RRX)
  - MUL/MLA
  - LDR/STR (即値/レジスタオフセット、byte/word)
  - LDM/STM の 4 アドレッシングモード (IA/IB/DA/DB) + 空レジスタリスト動作
  - MRS/MSR の CPSR/SPSR 読み書き（フィールドマスク対応）
  - 例外遷移時のモードバンク (R8-R12_fiq / SP / LR) と SPSR 保存
  - データ処理で `Rd=PC` 時の分岐反映 + `S` ビット時の SPSR→CPSR 復帰
  - ARM オペランドの `R15` 読み出しでパイプライン補正 (`PC+8`) を反映
  - LDM^ (`S` + `PC` 読み込み) で SPSR→CPSR 復帰
  - 未定義 ARM/Thumb 命令の UND 例外遷移
  - 命令種別ベースの CPU サイクル見積もりループ
- Thumb:
  - シフト即値、ADD/SUB (レジスタ/即値3)、MOV/CMP/ADD/SUB 即値
  - ALU 命令の一部、Hi register ops、BX
  - PC/SP 相対ロード、即値/レジスタオフセットの Load/Store、PUSH/POP、LDM/STM
  - 条件分岐 / 無条件分岐 / Long BL

## CPU 以外の実装状況
- メモリマップ拡張:
  - BIOS (`0x00000000`) のロード/参照
  - BIOS lockout（BIOS外実行時は BIOS latch 値を返す）を反映
  - IO (`0x04000000`)
  - Palette RAM (`0x05000000`)
  - VRAM (`0x06000000`)
  - OAM (`0x07000000`)
  - Palette/VRAM/OAM の byte write は halfword ミラー動作を反映
  - SRAM/Flash ウィンドウ (`0x0E000000`) を SRAM モデルで実装
  - EEPROM バックアップ（シリアル bitstream 読み書き）の基礎実装
  - GamePak ROM 読み出しのミラー/ラップアラウンドを反映
  - SaveState/LoadState バイナリスナップショット API
- PPU:
  - VCOUNT / DISPSTAT の更新
  - VBlank/HBlank/VCOUNT 一致フラグ更新 + DISPSTAT IRQ 条件評価
  - Mode0 BG0 (4bpp text BG) の最小描画
  - BG Mode3 の VRAM 直描画をフレームバッファへ反映
  - Mode4 (8bpp bitmap + page flip) の描画
  - OAM スプライト（非 affine の最小実装）合成
- Timer:
  - 4ch タイマの基本カウント/プリスケーラ/IRQ フラグ更新
- DMA:
  - DMA enable 時の 16/32bit 転送（inc/dec/fixed）
  - DMA 開始タイミング (Immediate/VBlank/HBlank/特殊ch3) と Repeat/IRQ ビット対応
- APU:
  - SOUNDCNT系レジスタを参照した軽量ミキサーレベル更新スタブ
- 割り込み:
  - IE/IF/IME + CPSR I-bit を使った IRQ 受付
  - SWI/IRQ 例外ベクタ遷移の最小実装
  - KEYINPUT/KEYCNT の keypad IRQ 条件評価

## Linux でのゲームプレイテスト
```bash
make gameplay_test
```

`--gameplay-test` モードで入力シーケンス (右+A / 下+B / 左) を流し、
- プレイヤー座標が変化しているか
- スコアが増加しているか
- フレームハッシュが変化しているか
を検証します。

## Linux での ROM 実行 (ヘッドレス)
```bash
make run_rom_demo
```

または任意 ROM を直接実行:
```bash
./build/linux_gba_test --run-rom <path/to/game.gba> --frames 600 --script "120:RIGHT+A,120:DOWN,60:NONE"
```

- `--frames`: 総実行フレーム数
- `--script`: 入力スクリプト (`<frame_count>:<KEY+KEY>`) をカンマ連結
- 対応キー: `A,B,SELECT,START,RIGHT,LEFT,UP,DOWN,R,L,NONE`

このモードは Linux 上で「ROM を実行し、入力を与えて挙動を確認する」ための検証用途です。

## iOS への付け替え (iOS18/26)
`src/platform/ios/` を Xcode プロジェクトに追加し、
- `ViewController.mm` でコア呼び出し
- バンドルに `test.gba` を含める
で iOS 上で同じコアを駆動できます。

現在の iOS フロントエンドは ObjC/ObjC++ のみで、以下を実装しています。
- GBA フレームバッファ (240x160) を `UIImageView` に毎フレーム転送
- マルチタッチ対応の仮想パッド (D-Pad / A / B / L / R / START / SELECT)
- BIOS ソース選択 (組み込みBIOS / ファイル選択BIOS)
- `CADisplayLink` ベースの 60Hz 駆動 + 遅延時の catch-up ステップ
- ヘッダ検証状態・キー入力・座標・スコア・ハッシュを HUD 表示
- Pause/Resume UI

`ViewController.mm` には iOS18+ と iOS26+ のフレームレート設定分岐をソース内で実装しています。

## 参考
- https://problemkaputt.de/gbatek.htm
- https://www.copetti.org/writings/consoles/game-boy-advance/

## 注意
- このリポジトリには ROM は同梱していません。利用する ROM/BIOS は、ユーザー自身が合法的に所有・利用許諾を満たすものを使用してください。
