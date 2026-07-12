//! `TenantProvisioningRepository` の sqlx 実装（REF2）。
//!
//! テナント行・初期管理者ユーザー・HOME メンバーシップ・`idp.tenant.admin` 付与の 4 INSERT を
//! **単一トランザクション**で実行する。途中で失敗した場合は全体がロールバックされ、
//! 「管理者のいないテナント（孤立テナント）」が残らないことを DB レベルで保証する。
//! 各 INSERT は個別リポジトリと同じ SQL（`insert_tenant` 等の共用ヘルパ）を使う。

use crate::domain::error::{DomainError, Result};
use crate::domain::repositories::TenantProvisioningRepository;
use crate::domain::tenant::Tenant;
use crate::domain::tenant_membership::TenantMembership;
use crate::domain::user::User;
use crate::infrastructure::db::Db;
use crate::infrastructure::repositories::tenant::insert_tenant;
use crate::infrastructure::repositories::tenant_membership::insert_membership;
use crate::infrastructure::repositories::user::insert_user;
use crate::infrastructure::repositories::user_permission::insert_grant;
use async_trait::async_trait;
use chrono::{DateTime, Utc};

pub struct SqlxTenantProvisioningRepository {
    pool: Db,
}

impl SqlxTenantProvisioningRepository {
    pub fn new(pool: Db) -> Self {
        Self { pool }
    }
}

fn repo_err<E: std::fmt::Display>(e: E) -> DomainError {
    DomainError::Repository(e.to_string())
}

#[async_trait]
impl TenantProvisioningRepository for SqlxTenantProvisioningRepository {
    async fn provision(
        &self,
        tenant: &Tenant,
        admin: &User,
        admin_membership: &TenantMembership,
        admin_permission_code: &str,
        granted_at: DateTime<Utc>,
    ) -> Result<()> {
        let mut tx = self.pool.begin().await.map_err(repo_err)?;
        insert_tenant(&mut *tx, tenant).await?;
        insert_user(&mut *tx, admin).await?;
        insert_membership(&mut *tx, admin_membership).await?;
        insert_grant(
            &mut *tx,
            tenant.id,
            admin.id,
            admin_permission_code,
            granted_at,
        )
        .await?;
        tx.commit().await.map_err(repo_err)?;
        Ok(())
    }
}
