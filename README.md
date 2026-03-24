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

`ViewController.mm` には iOS18+ と iOS26+ のフレームレート設定分岐をソース内で実装しています。

## 参考
- https://problemkaputt.de/gbatek.htm
- https://www.copetti.org/writings/consoles/game-boy-advance/

## 注意
- このリポジトリには ROM は同梱していません。利用する ROM/BIOS は、ユーザー自身が合法的に所有・利用許諾を満たすものを使用してください。
