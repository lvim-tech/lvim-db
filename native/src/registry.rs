// lvim-db-native/registry: the driver registry.
//
// Every compiled-in driver registers here, gated by its cargo feature. `hello()`
// serves the list of `DriverMeta` to the Lua side; `get(kind)` resolves a driver
// for a connect. ADDING A DB TYPE is: a new `drivers/<kind>.rs`, one `dep:` +
// feature line in Cargo.toml, and one `add()` line below — no other change.

use std::collections::BTreeMap;
use std::sync::Arc;

use crate::driver::Driver;
use crate::spec::DriverMeta;

/// The set of drivers this daemon was built with.
pub struct Registry {
    drivers: BTreeMap<&'static str, Arc<dyn Driver>>,
}

impl Registry {
    /// Build the registry from every feature-enabled driver.
    pub fn new() -> Self {
        let mut reg = Registry {
            drivers: BTreeMap::new(),
        };

        #[cfg(feature = "postgres")]
        {
            reg.add(Arc::new(crate::drivers::postgres::PostgresDriver::postgres()));
            #[cfg(feature = "cockroachdb")]
            reg.add(Arc::new(crate::drivers::postgres::PostgresDriver::cockroachdb()));
        }

        #[cfg(feature = "mariadb")]
        reg.add(Arc::new(crate::drivers::mysql::MysqlDriver::mariadb()));
        #[cfg(feature = "mysql")]
        reg.add(Arc::new(crate::drivers::mysql::MysqlDriver::mysql()));

        #[cfg(feature = "mongodb")]
        reg.add(Arc::new(crate::drivers::mongodb::MongoDriver::new()));

        #[cfg(feature = "sqlite")]
        reg.add(Arc::new(crate::drivers::sqlite::SqliteDriver::new()));

        #[cfg(feature = "duckdb")]
        reg.add(Arc::new(crate::drivers::duckdb::DuckdbDriver::new()));

        #[cfg(feature = "redis")]
        reg.add(Arc::new(crate::drivers::redis::RedisDriver::new()));

        #[cfg(feature = "clickhouse")]
        reg.add(Arc::new(crate::drivers::clickhouse::ClickhouseDriver::new()));

        #[cfg(feature = "sqlserver")]
        reg.add(Arc::new(crate::drivers::mssql::MssqlDriver::new()));

        #[cfg(feature = "cassandra")]
        reg.add(Arc::new(crate::drivers::cql::CqlDriver::cassandra()));
        #[cfg(feature = "scylla")]
        reg.add(Arc::new(crate::drivers::cql::CqlDriver::scylla()));

        #[cfg(feature = "firebird")]
        reg.add(Arc::new(crate::drivers::firebird::FirebirdDriver::new()));

        #[cfg(feature = "snowflake")]
        reg.add(Arc::new(crate::drivers::snowflake::SnowflakeDriver::new()));

        reg
    }

    fn add(&mut self, driver: Arc<dyn Driver>) {
        self.drivers.insert(driver.meta().kind, driver);
    }

    /// The metadata of every registered driver (for `rpc.hello`).
    pub fn metas(&self) -> Vec<&'static DriverMeta> {
        self.drivers.values().map(|d| d.meta()).collect()
    }

    /// Resolve a driver by its `kind`, or an error if this build lacks it.
    pub fn get(&self, kind: &str) -> anyhow::Result<Arc<dyn Driver>> {
        self.drivers
            .get(kind)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("unknown or not-compiled driver kind '{kind}'"))
    }
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn postgres_is_registered_and_resolvable() {
        let reg = Registry::new();
        assert!(!reg.metas().is_empty());
        assert!(reg.metas().iter().any(|m| m.kind == "postgres"));
        assert!(reg.get("postgres").is_ok());
        assert!(reg.get("does-not-exist").is_err());
    }
}
