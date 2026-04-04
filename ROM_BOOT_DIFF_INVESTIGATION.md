# ROMが再生されない問題の差分調査（VBA-M / Delta比較）

## 対象
- `src/core/gba_core_c_api.cpp`
- GitHub上の VBA-M (`src/wx/sys.cpp`)
- GitHub上の GBADeltaCore (`GBADeltaCore/Bridge/GBAEmulatorBridge.mm`)

## 見比べたポイント
1. フレームバッファ取得
2. BIOSブートwatchdog
3. `NullSoundDriver`
4. `systemReadJoypads/systemReadJoypad`
5. ROMロード経路（`utilIsGBAImage` + `utilLoad`）

## 結果

### 1) フレームバッファ取得
- 本実装は `g_pix` の 241x162 バッファから、表示領域 240x160 を切り出し。
- Delta側も `pix` から同様に 1行/1列オフセットして 240x160 をコピーしており、
  方針は一致。

### 2) watchdog
- 本実装のみ、BIOSファイル使用時に `reg[15]` が ROM 領域へ到達しなければ
  一定フレーム後に BIOS無効で `CPUReset()` するフォールバックがある。
- VBA-M/Deltaには同等のwatchdogは基本なく、Deltaはそもそも BIOSを使わず起動。

### 3) サウンド
- `NullSoundDriver` は無音化で、ROM遷移可否には直接関与しない。

### 4) Joypad
- `systemReadJoypads()` が `true` を返す挙動は VBA-M/Delta と同様。
- `systemReadJoypad()` はフロントエンド入力マスク返却で、構造的には同等。

### 5) ROMロード経路（重要）
- `utilLoad()` は `accept(path)` が `false` だと読み込みを行わない。
- したがって `utilIsGBAImage()` の判定ズレは **ROMデータ未ロード** に直結。
- 本調査で `utilIsGBAImage()` は VBA-M準拠の判定に揃えた
  （`.agb/.gba/.bin/.elf/.mb`、大文字小文字無視、`.mb` で multiboot）。

## 原因特定
「BIOSは出るがROMへ進まない」症状の主要因として最も再現性が高いのは、
**ROM受理判定の不一致により実ROMがロードされない/モードが合わないこと**。

加えて、DeltaはBIOSを使わない運用で回避しているため、
外部BIOS起動に依存した場合は ROMヘッダ不整合やBIOS相性問題が顕在化しやすい。

## 今回の修正
- `utilLoad()` で先読みに変更し、`accept(path)` が `false` でも
  **GBA ROM読み込み時（`accept == utilIsGBAImage`）かつ `n >= 0xC0`** なら
  読み込み結果を有効化するフォールバックを追加。
- これにより、拡張子判定とacceptゲートの組み合わせでROMが未ロードになる経路を遮断。
