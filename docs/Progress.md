# Progress

進行中・未着手タスクのみを管理する（完了したら本ファイルから削除し、必要なら `CHANGELOG.md` / `history/` へ）。

OIDC IdP MVP（**Rust + MariaDB**）の実装計画。設計仕様は `docs/OIDC_INPUT.md`、
スタック採用理由は `docs/adr/0005-rust-mariadb-stack.md`。MVP 完了条件（§10）は充足済み（詳細は `CHANGELOG.md`）。

## バックログ

| 優先 | # | 概要 | 状態 | 影響度 | 工数 |
|---|---|---|---|---|---|
| 1 | T1 | MFA基盤 — DBマイグレーション＋ドメイン設計 | ⬜未着手 | 大 | 中 |
| 2 | T2 | TOTP登録・管理 | ⬜未着手 | 大 | 中 |
| 3 | T3 | ログインフローへの TOTP ステップ追加 | ⬜未着手 | 大 | 中 |
| 4 | T4 | Passkey（WebAuthn）登録・認証 | ⬜未着手 | 大 | 大 |

設計仕様は `docs/adr/0008-mfa-design.md` を参照。
