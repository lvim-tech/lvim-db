// lvim-db-native/drivers/buffered: a fully-materialised, paged ResultStream.
//
// Many drivers get their whole result in one shot (Postgres simple protocol,
// mysql_async's collect, a Mongo command result). They share this: the rows are
// held here and handed out a page at a time, so the daemon's pager can go
// forwards AND backwards while Neovim only ever holds one page. Drivers that
// stream lazily (a live cursor) implement ResultStream directly instead.

use async_trait::async_trait;

use crate::driver::ResultStream;
use crate::spec::{Column, Value};

/// A result buffered in full, served in pages.
pub struct BufferedStream {
    columns: Vec<Column>,
    rows: Vec<Vec<Value>>,
    pos: usize,
    affected: Option<u64>,
}

impl BufferedStream {
    pub fn new(columns: Vec<Column>, rows: Vec<Vec<Value>>, affected: Option<u64>) -> Self {
        Self {
            columns,
            rows,
            pos: 0,
            affected,
        }
    }
}

#[async_trait]
impl ResultStream for BufferedStream {
    fn columns(&self) -> &[Column] {
        &self.columns
    }

    fn affected(&self) -> Option<u64> {
        if self.rows.is_empty() {
            self.affected
        } else {
            None
        }
    }

    async fn next_page(&mut self, n: usize) -> anyhow::Result<Option<Vec<Vec<Value>>>> {
        if self.pos >= self.rows.len() {
            return Ok(None);
        }
        let end = (self.pos + n).min(self.rows.len());
        let page = self.rows[self.pos..end].to_vec();
        self.pos = end;
        Ok(Some(page))
    }
}
