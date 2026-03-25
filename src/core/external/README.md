# External core sources

`third_party/mgba` 由来のソースは `src/core/external/mgba` に保持しています。

また、既存コア実装は分割参照ではなく、`src/core/gba_core.mm` に**直接マージ**して1ファイル化しました。
