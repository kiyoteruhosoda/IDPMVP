# ADR-0011: root テナント UUID を固定値にする

- Status: Accepted
- Date: 2026-07-24
- Related: ADR-0009（マルチテナント基盤。§1 の root 動的採番を本 ADR で改める）

## Context

root テナントの UUID は seed マイグレーション（`0002_seed_master_data`）が投入時に UUIDv7 で**動的採番**して
いた（ADR-0009 §1）。同一 DB では不変だが、**DB を作り直す（データ再初期化）と新しい UUID が採番される**。

システム管理者のログイン URL は `/{root_tenant_id}/...` の形式で root UUID を含むため、再初期化のたびに URL が
変わり、運用（ブックマーク・クライアント設定・手順書）に負担が生じていた。

当初は「値を git 管理せず、`.env` / DB から起動時に固定・変更できるようにする」案（起動時に root の id を
設定値へ付け替える reconcile）も検討したが、既存 DB の主キー変更には `tenants(id)` を参照する全 FK
（直接・複合）への `ON UPDATE CASCADE` 付与、FK 非依存の `audit_log` の明示的な付け替え、scope 不変条件の
CHECK→トリガ移行などが必要で、**仕様が過度に複雑**になった。

要件を整理すると、実際に必要なのは「root UUID が再初期化で変わらないこと」だけで、
「環境ごとに別値」「稼働中 DB での無停止変更」は本プロジェクト（単一〜小規模配置）では不要である。

## Decision

**root テナントの UUID を固定値 `00000000-0000-7000-8000-000000000001` とし、seed でこのリテラルを投入する。**

- 値は全環境共通で、ソース（`0002`）に直書きして git 管理する。
- UUIDv7 形（version ニブル `7`・variant ニブル `8`）の well-known な番兵値とする（既存のスキーマ整合テスト
  `assert_uuid_v7` を満たす）。
- root は従来どおり `parent_tenant_id IS NULL` の唯一行として構造的に識別する（`is_root` 番兵列 + UNIQUE）。
  テーブル分割や識別方法の変更は行わない。

### 固定値を秘密にしない理由

root UUID は URL `/{root}/...` に現れる識別子にすぎず、秘密値ではない。アクセス制御は scope（`idp.system.admin`
は root scope のみ）+ メンバーシップ + 認証で担保しており、UUID の推測困難性には依存しない。issuer・署名鍵・
セッションは環境/DB ごとに独立するため、複数配置で同一 root UUID を用いてもトークン流用等は発生しない。

## Consequences

- DB を再初期化しても root UUID は変わらず、管理者ログイン URL が安定する。
- 追加の FK 変更・トリガ・起動時 reconcile・設定キーは不要。実装は seed のリテラル 1 箇所に集約される。
- 全環境で同一の root UUID になる（実害なし）。稼働中 DB の root UUID を無停止で変更することはできない
  （必要になれば別 ADR で再検討する）。
- 既に別の（動的採番された）root UUID で初期化済みの DB には遡って適用されない。固定値を反映するには DB の
  再作成が必要（`0002` のチェックサムが変わるため、既存 DB はそのままでは起動できない。手順は
  `docs/OPERATIONS.md`「DB を作り直したいとき」）。ADR-0009 §11 と同様の一度限りの seed 改訂として扱う。
