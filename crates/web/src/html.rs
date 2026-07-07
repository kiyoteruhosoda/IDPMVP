//! サーバレンダリング画面へ値を埋め込む際の HTML エスケープ（格納型 XSS 対策）。
//! テキストとして埋め込む利用者・管理者入力は必ず本関数を通す。

/// HTML のテキスト／属性値へ安全に埋め込めるようエスケープする。
pub fn escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#x27;"),
            _ => out.push(ch),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_html_metacharacters() {
        assert_eq!(
            escape("<script>&\"'"),
            "&lt;script&gt;&amp;&quot;&#x27;"
        );
    }
}
