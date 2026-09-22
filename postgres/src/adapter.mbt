///|
/// Keep PostgreSQL column metadata and FromSql decoding. Lookup by name refuses
/// duplicates instead of inheriting the upstream first-match behavior.
pub struct Row {
  columns : Array[@client.Column]
  priv raw : @client.Row
}

///|
pub fn[T : @client.FromSql] Row::get(self : Row, name : String) -> T raise {
  self.raw.get(@sql.column_index(self.columns.map(c => c.name), name))
}

///|
pub fn[T : @client.FromSql] Row::get_at(self : Row, index : Int) -> T raise {
  self.raw.get(index)
}

///|
priv struct Connection {
  client : @pgpool.Client
  mut transaction : @pgpool.Transaction?
}

///|
/// Uses one upstream pool; there is no second connection pool. Its TaskGroup
/// must outlive the database and all borrowed sessions. Clean recycling is
/// required so session settings and temporary objects do not leak to borrowers.
pub fn database(
  config : @pgpool.Config,
  group : @async.TaskGroup[Unit],
  max_waiters? : Int = 128,
  checkout_timeout_ms? : Int = 5000,
  max_rows? : Int = 10000,
  max_bytes? : Int = 16777216,
) -> @sql.Database[
  &@client.ToSql,
  Row,
  @client.QuerySummary,
  @pgpool.TransactionOptions,
] raise {
  guard config.pool.recycling_method == @pgpool.RecyclingMethod::clean() else {
    raise @sql.InvalidConfig("PostgreSQL adapter requires Clean recycling")
  }
  guard max_rows > 0 && max_bytes > 0 else {
    raise @sql.InvalidConfig("Invalid PostgreSQL result limits")
  }
  let pool = @pgpool.Pool::new(
    config,
    group,
    options=@pgpool.PoolOptions::new(pre_recycle=async fn(client) {
      client.batch_execute("ROLLBACK")
    }),
  )
  errdefer pool.close()
  @sql.Database::new(
    {
      acquire: async fn() { { client: pool.get(), transaction: None, } },
      close: fn() { pool.close() },
      release: fn(conn, discard) raise {
        if discard {
          conn.client.detach_raw().close()
        } else {
          conn.client.release()
        }
      },
      run: async fn(conn, sql, params) {
        // The upstream stream scope drains protocol state even on decode/limit
        // failures. Cancellation cannot leave rows for the next borrower.
        let collect = async fn(stream : @pgpool.RowStream) {
          let rows : Array[Row] = []
          let mut bytes = 0L
          while stream.next() is Some(row) {
            for value in row.values {
              if value is Some(value) {
                bytes += value.length().to_int64()
              }
            }
            guard rows.length() < max_rows && bytes <= max_bytes.to_int64() else {
              raise ResultTooLarge
            }
            rows.push({ columns: row.columns, raw: row, })
          }
          @sql.Response::{ rows, metadata: stream.finish(), }
        }
        @async.protect_from_cancel(async fn() {
          match conn.transaction {
            Some(tx) => tx.with_stream(sql, params~, collect)
            None => conn.client.with_stream(sql, params~, collect)
          }
        })
      },
      begin: async fn(conn, options) {
        conn.transaction = Some(conn.client.transaction(options~))
      },
      commit: async fn(conn) {
        let tx = conn.transaction.unwrap()
        conn.transaction = None
        tx.commit()
      },
      rollback: async fn(conn) {
        let tx = conn.transaction.unwrap()
        conn.transaction = None
        tx.rollback()
      },
    },
    max_leases=config.pool.max_size,
    max_waiters~,
    checkout_timeout_ms~,
  )
}

///|
pub(all) suberror ResultTooLarge

///|
/// Own the background protocol tasks as well as the database lifetime.
pub async fn[T] with_database(
  config : @pgpool.Config,
  f : async (
    @sql.Database[
      &@client.ToSql,
      Row,
      @client.QuerySummary,
      @pgpool.TransactionOptions,
    ],
  ) -> T,
  max_waiters? : Int = 128,
  checkout_timeout_ms? : Int = 5000,
  max_rows? : Int = 10000,
  max_bytes? : Int = 16777216,
) -> T {
  let result : Ref[T?] = { val: None, }
  @async.with_task_group(async fn(group) {
    let db = database(
      config,
      group,
      max_waiters~,
      checkout_timeout_ms~,
      max_rows~,
      max_bytes~,
    )
    defer @async.protect_from_cancel(async fn() { db.close_and_wait() })
    result.val = Some(f(db))
  })
  result.val.unwrap()
}
