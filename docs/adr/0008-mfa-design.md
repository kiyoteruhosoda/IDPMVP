# ADR-0008: MFA（多要素認証）実装設計

- **Status**: Proposed
- **Date**: 2026-07-08

## Context

OIDC IdP MVP 完了後の次フェーズとして TOTP・Passkey（WebAuthn）による MFA を追加する。
対象タスク: T1（MFA基盤）→ T2（TOTP）→ T3（TOTPログインフロー）→ T4（Passkey）の順に実施する。

---

## T1: MFA基盤 — DBマイグレーション＋ドメイン設計

### マイグレーション

- `0010_user_totp_secrets.up/down.sql`
  `(user_id, encrypted_secret, backup_codes_hash JSON, confirmed_at, created_at)`
  — `confirmed_at IS NULL` なら仮登録中
- `0011_user_webauthn_credentials.up/down.sql`
  `(id, user_id, credential_id, public_key, sign_count, transports, name, created_at, last_used_at)`
- `0012_auth_session_mfa_pending.up/down.sql`
  `auth_sessions` に `password_verified_at DATETIME(6) NULL` を追加（MFA pending 状態管理用）

### ドメイン

- `domain/totp_secret.rs` — `TotpSecret` エンティティ
- `domain/webauthn_credential.rs` — `WebAuthnCredential` エンティティ
- `domain/repositories.rs` に `TotpSecretRepository` / `WebAuthnCredentialRepository` トレイト追加

---

## T2: TOTP登録・管理

MFA は任意（強制なし）。ユーザーが自分でセルフ登録・削除する。

### Application: `application/totp_registration.rs`

- `setup(user_id)` → TOTP secret 生成・仮保存・QR URI 返却
- `confirm(user_id, code)` → コード検証後 `confirmed_at` 設定で確定
- `remove(user_id)` → TOTP 削除

### Infrastructure

- `infrastructure/repositories/totp_secret.rs`（sqlx 実装）

### API（`/account/mfa/totp` 配下）

- `GET  /account/mfa/totp/setup` → TOTP URI + QR コード返却
- `POST /account/mfa/totp/confirm` → 6 桁コードで確定
- `DELETE /account/mfa/totp` → TOTP 削除

### Web

- TOTP 設定画面（QR コード表示・確認コード入力フォーム）
- アカウント設定に MFA セクション追加

---

## T3: ログインフローへの TOTP ステップ追加

`LoginService` でパスワード検証成功後、ユーザーに TOTP が有効なら
`auth_sessions.password_verified_at` を更新して `LoginOutcome::MfaRequired` を返す（SSO 発行は MFA 完了後）。

### Application: `application/mfa_login.rs`

`MfaLoginService::verify_totp(auth_session_id, code, ctx)`
- セッションの `password_verified_at` を確認 → TOTP 検証 → SSO 発行 → consent → code 発行

### API

- `POST /login/mfa/totp` ハンドラ追加

### Web

- TOTP 入力画面（ログインフロー内）

---

## T4: Passkey（WebAuthn）登録・認証

### Application

- `passkey_registration.rs`（登録開始・完了）
- `passkey_authentication.rs`（認証開始・完了）

### Infrastructure

- `webauthn_credential.rs`（sqlx）
- `webauthn.rs`（`webauthn-rs` ラッパー）

### API

- `POST /account/mfa/passkey/register/begin` / `complete`
- `DELETE /account/mfa/passkey/:id`
- `POST /login/passkey/begin` / `complete`

### Web

- Passkey 登録画面（WebAuthn JS API 呼び出し）
- ログイン画面に Passkey ボタン追加
