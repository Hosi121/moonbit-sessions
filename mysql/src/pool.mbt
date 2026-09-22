///|
pub(all) suberror DatabaseError {
  Closed
  InvalidConfig(String)
  InvalidParameter
  ServerError(Int)
  CompletionLost
  WorkerUnavailable
  ResultTooLarge
}

///|
/// Integers, decimals and binary data never round-trip through Double/JSON.
pub(all) enum Value {
  Null
  Text(String)
  Integer(Int64)
  Unsigned(UInt64)
  Float(Double)
  Decimal(String)
  Blob(Bytes)
} derive(Eq, Debug)

///|
pub(all) struct Statement {
  sql : String
  params : Array[Value]
}

///|
pub fn statement(sql : String, params? : Array[Value] = []) -> Statement {
  { sql, params, }
}

///|
pub struct Row {
  values : Map[String, Value]
}

///|
pub fn Row::get(self : Row, name : String) -> Value? {
  self.values.get(name)
}

///|
pub struct QueryResult {
  rows : Array[Row]
  has_rows : Bool
  affected_rows : UInt64
  insert_id : UInt64
}

///|
priv struct Connection {
  db : Database
  fd : @raw_fd.RawFd
  mut busy : Bool
  mut closed : Bool
}

///|
/// Use on one async event loop. Every instance owns its workers and queue.
pub struct Pool {
  priv available : @async.Queue[Connection]
  priv connections : Array[Connection]
  priv mut closed : Bool
}

///|
/// Connections are established lazily on foreign workers, never on this loop.
/// Empty ssl_ca leaves Connector/C's default TLS policy in effect.
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
    }) else {
    raise InvalidConfig("Invalid connection settings")
  }
  let available = @async.Queue(kind=Unbounded)
  let connections : Array[Connection] = []
  let mut ready = false
  defer (if !ready {
    for connection in connections {
      connection.close()
    }
  })
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
    )
    guard c_db_fd(db) >= 0 else { raise WorkerUnavailable }
    let fd = {
      errdefer c_db_close(db)
      @raw_fd.RawFd(c_db_fd(db))
    }
    let connection = { db, fd, busy: false, closed: false, }
    ignore(available.try_put(connection) catch { _ => false })
    connections.push(connection)
  }
  ready = true
  { available, connections, closed: false, }
}

///|
fn Connection::close(self : Connection) -> Unit {
  if !self.closed {
    self.closed = true
    self.fd.close()
    c_db_close(self.db)
  }
}

///|
/// Reject queued/new requests immediately. In-flight work drains before its
/// worker is freed; close is idempotent and never joins a running SQL job.
pub fn Pool::close(self : Pool) -> Unit {
  if !self.closed {
    self.closed = true
    self.available.close(error=Closed, clear=true)
    for connection in self.connections {
      if !connection.busy {
        connection.close()
      }
    }
  }
}

///|
pub async fn Pool::query(
  self : Pool,
  sql : String,
  params? : Array[Value] = [],
) -> QueryResult {
  self.run([statement(sql, params~)], false)
}

///|
/// Execute the batch on one connection, commit or roll back, and return the
/// final statement's result. No automatic retry of possibly committed writes.
/// DDL and session/transaction control SQL follow MySQL's own semantics.
pub async fn Pool::transaction(
  self : Pool,
  statements : Array[Statement],
) -> QueryResult {
  self.run(statements, true)
}

///|
async fn Pool::run(
  self : Pool,
  statements : Array[Statement],
  transaction : Bool,
) -> QueryResult {
  guard !self.closed else { raise Closed }
  guard !statements.is_empty() else { raise InvalidParameter }
  // Validate before taking a worker. Strings may contain NUL; SQL may not.
  for statement in statements {
    guard !statement.sql.is_empty() && !statement.sql.contains("\u0000") else {
      raise InvalidParameter
    }
    for param in statement.params {
      if param is Float(n) && (n.is_nan() || n.is_inf()) {
        raise InvalidParameter
      }
    }
  }
  let conn = self.available.get()
  guard !self.closed else { raise Closed }
  conn.busy = true
  @async.protect_from_cancel(async fn() {
    let mut completed = false
    defer {
      conn.busy = false
      if !completed {
        self.close()
      }
      if self.closed {
        conn.close()
      } else {
        ignore(self.available.try_put(conn) catch { _ => false })
      }
    }
    let db = conn.db
    c_db_reset(db, statements.length(), transaction)
    for i, statement in statements {
      c_db_statement(
        db,
        i,
        @utf8.encode(statement.sql),
        statement.params.length(),
      )
      for j, param in statement.params {
        match param {
          Null => c_db_param(db, i, j, 0, b"", 0)
          Float(n) => c_db_param(db, i, j, 1, b"", n)
          Text(s) | Decimal(s) => c_db_param(db, i, j, 2, @utf8.encode(s), 0)
          Integer(n) => c_db_integer(db, i, j, n)
          Unsigned(n) => c_db_unsigned(db, i, j, n)
          Blob(data) => c_db_param(db, i, j, 3, data, 0)
        }
      }
    }
    c_db_submit(db)
    guard conn.fd.read(FixedArray::make(1, b'\x00')) == 1 else {
      raise CompletionLost
    }
    completed = true
    let error = c_db_error(db)
    guard error == 0 else {
      match error {
        -2 => raise ResultTooLarge
        -3 => raise InvalidParameter
        _ => raise ServerError(error)
      }
    }
    let columns = Array::makei(c_db_cols(db), i => {
      (@utf8.decode(c_db_name(db, i)), c_db_kind(db, i))
    })
    let rows = Array::makei(c_db_rows(db), row => {
      let values : Map[String, Value] = Map([])
      for col, (name, kind) in columns {
        values[name] = if c_db_null(db, row, col) {
          Null
        } else {
          let bytes = c_db_cell(db, row, col)
          if kind == 5 {
            Blob(bytes)
          } else {
            let text = @utf8.decode(bytes)
            match kind {
              1 => Integer(@string.parse_int64(text))
              2 => Unsigned(@string.parse_uint64(text))
              3 => Float(@string.parse_double(text))
              4 => Decimal(text)
              _ => Text(text)
            }
          }
        }
      }
      { values, }
    })
    {
      rows,
      has_rows: !columns.is_empty(),
      affected_rows: c_db_affected(db),
      insert_id: c_db_insert_id(db),
    }
  })
}

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend Value with @debug.Debug::{to_repr}
