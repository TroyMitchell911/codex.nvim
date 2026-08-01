# CLAUDE.md - codex.nvim

## 目的

Codex CLI を Neovim から操作し、現在のファイル・選択範囲・explorer の
選択・画像・review target を Codex へ安全に渡す依存なし Lua プラグイン。

## 設計境界

- Neovim 0.12+、macOS/Linux、Codex CLI を対象とする。
- `backend = "terminal"` を安定した既定値とし、完全な Codex TUI を使う。
- `backend = "app_server"` は stdio JSONL の実験的 native UI として分離する。
- `lua/codex/terminal.lua` だけが terminal job/channel を所有する。
- `lua/codex/app_server/client.lua` だけが app-server process と JSONL RPC を所有する。
- 外部 command は shell 文字列ではなく argv 配列で起動する。
- window を閉じても process は維持し、`:CodexStop` だけが明示停止する。
- cwd は session 開始元 buffer から一度だけ解決し、実行中に暗黙変更しない。
- editor context は行数・byte 数の上限を超えたら切り詰めず拒否する。
- explorer 連携は optional adapter とし、runtime dependency を追加しない。
- 複数同時 session、独自 transcript 永続化、Windows 対応は範囲外。

## 検証

```sh
make check
make integration # installed Codex CLI を使う任意の実機確認
```

個別には `make test`、`make fmt-check`、`make lint` を使用する。
