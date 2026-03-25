# iOS (Objective-C / UIKit / No Storyboard)

`ios/GBAEmuApp` に、Storyboardを使わずUIKit直書きで構成した最小構成のiOSアプリ雛形を追加しています。

## 構成
- `AppDelegate` / `SceneDelegate` / `ViewController` を Objective-C で実装
- `GBAEngine`（Objective-C）から C API 経由で `src/core` の GBA コアに接続
- `Info.plist` は Scene ベース構成

## 組み込みの想定
- `test1.gba` を app bundle に含めると、`同梱ROMをロード` ボタンから読み込み可能
- 実行ボタンで `runFrame()` を呼び出し

## 注意
このリポジトリには `.xcodeproj` は含めていないため、Xcodeで新規iOS Appターゲット（Storyboardなし）を作成し、
`ios/GBAEmuApp` 配下のファイルを追加して利用してください。


## チェック
- `ios/scripts/check_objc_mixing.sh` で `.m/.h` に C++ 記法（`std::`, `namespace`, `gba::` など）が混入していないか検査できます。
- C++ 実装は `src/core/gba_core_c_api.cpp` 側に閉じ込め、iOS 側は `.m` だけで利用できます。
