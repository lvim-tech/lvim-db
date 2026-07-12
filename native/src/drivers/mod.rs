// lvim-db-native/drivers: the compiled-in database drivers, each behind a cargo
// feature. Adding a DB type adds one module here (+ a Cargo feature + a
// registry.rs line) and touches nothing else. `buffered` is a shared paged
// ResultStream most drivers reuse.

// The shared buffered stream is used by nearly every driver; enable it whenever
// any driver that reuses it is compiled in.
pub mod buffered;

#[cfg(feature = "postgres")]
pub mod postgres;

#[cfg(any(feature = "mariadb", feature = "mysql"))]
pub mod mysql;

#[cfg(feature = "mongodb")]
pub mod mongodb;

#[cfg(feature = "sqlite")]
pub mod sqlite;

#[cfg(feature = "duckdb")]
pub mod duckdb;

#[cfg(feature = "redis")]
pub mod redis;

#[cfg(feature = "clickhouse")]
pub mod clickhouse;

#[cfg(feature = "sqlserver")]
pub mod mssql;

#[cfg(any(feature = "cassandra", feature = "scylla"))]
pub mod cql;

#[cfg(feature = "firebird")]
pub mod firebird;

#[cfg(feature = "snowflake")]
pub mod snowflake;
