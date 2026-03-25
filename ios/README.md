# iOS (Objective-C / UIKit / No Storyboard)

`src/GBAEmuApp` に、Storyboardを使わずUIKit直書きで構成した最小構成のiOSアプリ雛形を配置しています。

## 構成
- `AppDelegate` / `SceneDelegate` / `ViewController` を Objective-C で実装
- `GBAEngine`（Objective-C/Objective-C++）から C API 経由で `src/core` の GBA コアに接続
- コア実装は `src/core/gba_core.mm` を入口として、`src/core/gba_core_modules/*.mm` に分割された構成
- `Info.plist` は Scene ベース構成

## 組み込みの想定
- `test1.gba` を app bundle に含めると、`同梱ROMをロード` ボタンから読み込み可能
- 実行ボタンで `runFrame()` を呼び出し

## 注意
このリポジトリには `.xcodeproj` は含めていないため、Xcodeで新規iOS Appターゲット（Storyboardなし）を作成し、
`src/GBAEmuApp` 配下のファイルを追加して利用してください。


## チェック
- `ios/scripts/check_objc_mixing.sh` で `.m/.h` に C++ 記法（`std::`, `namespace`, `gba::` など）が混入していないか検査できます。
- C++ 実装は `src/core/gba_core_c_api.cpp` / `src/core/gba_core.mm` 側にあり、iOS 側は基本的に C API 経由で利用します。
- Core が `std::countl_zero` / `std::popcount` を使うため、Xcode 側の C++ 標準は C++20 (`gnu++20`) を指定してください（`src/GBAEmuApp/iOS26.xcconfig` 設定済み）。
