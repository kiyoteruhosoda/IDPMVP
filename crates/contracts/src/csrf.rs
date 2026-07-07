//! ログイン画面の CSRF 同期トークン（web が生成し api が検証する契約）。
//!
//! `auth_session_id`（HttpOnly Cookie にのみ存在する推測不能な乱数）の一方向ハッシュをログインフォームへ
//! 埋め込み、POST 時に api の LoginService が同じ値を再計算して照合する（同期トークン方式。サーバ側の
//! 追加保存は不要）。web（フォーム描画）と api（検証）で導出を一致させるため本 crate に置く。

use sha2::{Digest, Sha256};

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

/// `auth_session_id` に紐づくログイン画面用 CSRF トークンを導出する。
pub fn login_csrf_token(auth_session_id: &str) -> String {
    sha256_hex(&format!("csrf:{auth_session_id}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn login_csrf_is_deterministic_and_session_bound() {
        let a = login_csrf_token("session-a");
        assert_eq!(a, login_csrf_token("session-a"));
        assert_ne!(a, login_csrf_token("session-b"));
        // SHA-256 hex（64 文字）でフォームに埋め込める安全な文字のみ。
        assert_eq!(a.len(), 64);
        assert!(a.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    #[test]
    fn login_csrf_matches_known_vector() {
        // web と api で導出が食い違わないための固定ベクタ（`csrf:abc` の SHA-256）。
        assert_eq!(
            login_csrf_token("abc"),
            "8c1f95ae991baa4ca3097ba5a6052ccb4fdea88faf0599df4fafaa3c3252801a"
        );
    }
}
