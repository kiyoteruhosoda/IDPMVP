# Progress

進行中・未着手タスクのみを管理する（完了したら本ファイルから削除し、必要なら `CHANGELOG.md` / `history/` へ）。

OIDC IdP MVP（**Rust + MariaDB**）の実装計画。設計仕様は `docs/OIDC_INPUT.md`、
スタック採用理由は `docs/adr/0005-rust-mariadb-stack.md`。

| 優先 | # | 概要 | 状態 | 影響度 | 工数 |
|---|---|---|---|---|---|
| — | — | 進行中・未着手タスクはありません | — | — | — |

> MVP フェーズ T0〜T8・D1、およびインフラ整備 T9〜T13・D2 はすべて完了（`docs/CHANGELOG.md` 参照）。
> 設計仕様 §10 の MVP 完了条件 1〜13 は `tests/oidc_flow.rs` の E2E テストで検証済み。
> 将来拡張の候補（Refresh Token / Consent / Client 管理 / Token 管理）は設計仕様 §9 を参照し、
> 着手時に本ファイルへタスクとして起票する。
