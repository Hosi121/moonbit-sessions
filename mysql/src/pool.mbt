///|
priv struct Workers {
  available : @async.Queue[Connection]
  connections : Array[Connection]
  mut closed : Bool
}

///|
pub struct Pool {
  priv sql : @sql.Database[Value, Row, Command, TransactionOptions]
}

///|
/// Physical connections are established on foreign workers. charset, time_zone
/// and CLIENT_FOUND_ROWS are explicit MySQL policies, reapplied after recycling.
pub async fn Pool::new(
  host~ : String,
  user~ : String,
  password~ : String,
  database~ : String,
  port? : Int = 3306,
  size? : Int = 10,
  ssl_ca? : String = "",
  plugin_dir? : String = "",
  timeout_seconds? : Int = 5,
  max_rows? : Int = 10000,
  max_bytes? : Int = 16777216,
  max_waiters? : Int = 128,
  checkout_timeout_ms? : Int = 5000,
  charset? : String = "utf8mb4",
  time_zone? : String = "+00:00",
  found_rows? : Bool = true,
) -> Pool {
  guard size > 0 &&
    size <= 128 &&
    port > 0 &&
    port <= 65535 &&
    timeout_seconds > 0 &&
    timeout_seconds <= 3600 &&
    max_rows > 0 &&
    max_rows <= 1000000 &&
    max_bytes > 0 else {
    raise InvalidConfig("Invalid pool limits")
  }
  guard !host.is_empty() &&
    !database.is_empty() &&
    [host, user, password, database, ssl_ca, plugin_dir].all(s => {
      !s.contains("\u0000")
    }) &&
    (charset == "utf8mb4" || charset == "utf8mb3" || charset == "utf8") &&
    time_zone.length() > 0 &&
    time_zone.length() <= 64 &&
    time_zone
    .iter()
    .all(c => {
      c
      is ('a'..='z' | 'A'..='Z' | '0'..='9' | '_' | '/' | ':' | '+' | '-' | '.')
    }) else {
    raise InvalidConfig("Invalid connection settings")
  }
  let workers : Workers = {
    available: @async.Queue(kind=Unbounded),
    connections: [],
    closed: false,
  }
  errdefer workers.close()
  for _ in 0..<size {
    let db = c_db_new(
      @utf8.encode(host),
      @utf8.encode(user),
      @utf8.encode(password),
      @utf8.encode(database),
      port,
      @utf8.encode(ssl_ca),
      @utf8.encode(plugin_dir),
      timeout_seconds,
      max_rows,
      max_bytes,
      @utf8.encode(charset),
      @utf8.encode(time_zone),
      found_rows,
    )
    guard c_db_fd(db) >= 0 else { raise WorkerUnavailable }
    let fd = {
      // RawFd owns the read end even when its constructor raises.
      errdefer c_db_close(db)
      @raw_fd.RawFd(c_db_fd(db))
    }
    let conn : Connection = {
      db,
      fd,
      leased: false,
      closed: false,
      broken: false,
    }
    workers.connections.push(conn)
    ignore(workers.available.try_put(conn) catch { _ => false })
  }
  let sql = @sql.Database::new(
    {
      acquire: async fn() {
        let conn = workers.available.get()
        conn.leased = true
        conn
      },
      close: fn() { workers.close() },
      release: async fn(conn, discard) {
        defer {
          conn.leased = false
          if conn.broken {
            workers.close()
          }
          if workers.closed {
            conn.close()
          } else {
            ignore(workers.available.try_put(conn) catch { _ => false })
          }
        }
        if !workers.closed {
          conn.recycle(discard)
        }
      },
      run: async fn(conn, sql, params) { conn.run(sql, params) },
      begin: async fn(conn, options : TransactionOptions) {
        if options.isolation is Some(isolation) {
          let name = match isolation {
            ReadUncommitted => "READ UNCOMMITTED"
            ReadCommitted => "READ COMMITTED"
            RepeatableRead => "REPEATABLE READ"
            Serializable => "SERIALIZABLE"
          }
          conn.control("SET TRANSACTION ISOLATION LEVEL " + name)
        }
        let sql = match options.read_only {
          Some(true) => "START TRANSACTION READ ONLY"
          Some(false) => "START TRANSACTION READ WRITE"
          None => "START TRANSACTION"
        }
        conn.control(sql)
      },
      commit: async fn(conn) { conn.control("COMMIT") },
      rollback: async fn(conn) {
        // A failed statement closes the physical connection in the C worker.
        // Rollback must not establish a replacement session within this lease.
        if c_db_connected(conn.db) {
          conn.control("ROLLBACK")
        }
      },
    },
    max_leases=size,
    max_waiters~,
    checkout_timeout_ms~,
  )
  { sql, }
}

///|
fn Workers::close(self : Workers) -> Unit {
  if !self.closed {
    self.closed = true
    self.available.close(error=@sql.Closed, clear=true)
    for conn in self.connections {
      if !conn.leased {
        conn.close()
      }
    }
  }
}

///|
pub fn Pool::database(
  self : Pool,
) -> @sql.Database[Value, Row, Command, TransactionOptions] {
  self.sql
}

///|
pub fn Pool::close(self : Pool) -> Unit {
  self.sql.close()
}

///|
/// Compatibility helper. New consumers can use database().query/execute/run.
pub async fn Pool::query(
  self : Pool,
  sql : String,
  params? : Array[Value] = [],
) -> QueryResult {
  legacy_result(self.sql.run(sql, params~))
}

///|
pub async fn Pool::transaction(
  self : Pool,
  statements : Array[Statement],
) -> QueryResult {
  guard !statements.is_empty() else { raise InvalidParameter }
  self.sql.with_transaction(TransactionOptions::new(), async fn(tx) {
    let mut result = tx.run(statements[0].sql, params=statements[0].params)
    for i in 1..<statements.length() {
      result = tx.run(statements[i].sql, params=statements[i].params)
    }
    legacy_result(result)
  })
}

///|
fn legacy_result(result : @sql.Response[Row, Command]) -> QueryResult {
  {
    rows: result.rows,
    has_rows: result.metadata.has_rows,
    affected_rows: result.metadata.affected_rows,
    insert_id: result.metadata.insert_id,
  }
}
