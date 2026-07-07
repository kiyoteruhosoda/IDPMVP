#[tokio::main]
async fn main() -> anyhow::Result<()> {
    idp_api::run().await
}
