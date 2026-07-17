// lvim-db-native/drivers: the compiled-in database drivers, each behind a cargo
// feature. Adding a DB type adds one module here (+ a Cargo feature + a
// registry.rs line) and touches nothing else. `buffered` is a shared paged
// ResultStream most drivers reuse.

// The shared buffered stream is used by nearly every driver; enable it whenever
// any driver that reuses it is compiled in.
pub mod buffered;

/// Fold a catalog query's `(index_name, unique, primary, column)` rows — ONE ROW PER INDEX COLUMN, already
/// ordered by index then by the index's own column position — into one `Index` per name.
///
/// Shared because every relational catalog answers this question in the same shape (pg_index, SHOW INDEX,
/// sys.index_columns, RDB$INDEX_SEGMENTS all yield a row per column), and each driver re-folding it by hand
/// is the same loop written N times, each with its own chance of losing the column ORDER — which is the one
/// thing an index's columns must preserve.
///
/// A NULL/absent column name is skipped, not pushed as "": that is how a catalog reports an EXPRESSION index
/// (postgres) or a hidden key, and an empty string would render as a nameless column that does not exist.
pub fn group_indexes(rows: Vec<Vec<crate::spec::Value>>) -> Vec<crate::spec::Index> {
    use crate::spec::{Index, Value};
    let text = |v: Option<&Value>| match v {
        Some(Value::Text(s)) => Some(s.clone()),
        _ => None,
    };
    // Truthiness across catalogs: postgres gives a real bool, mysql/mssql give 0/1, some give "YES"/"t".
    let flag = |v: Option<&Value>| match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::Int(i)) => *i != 0,
        Some(Value::Text(s)) => {
            let s = s.to_ascii_lowercase();
            s == "1" || s == "t" || s == "true" || s == "yes"
        }
        _ => false,
    };
    let mut out: Vec<Index> = Vec::new();
    for r in rows {
        let name = match text(r.first()) {
            Some(n) => n,
            None => continue,
        };
        let col = text(r.get(3));
        match out.iter_mut().find(|i| i.name == name) {
            Some(existing) => {
                if let Some(c) = col {
                    existing.columns.push(c);
                }
            }
            None => out.push(Index {
                name,
                columns: col.into_iter().collect(),
                unique: flag(r.get(1)),
                primary: flag(r.get(2)),
            }),
        }
    }
    out
}

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
