///|
priv struct Connection {
  db : Database
  fd : @raw_fd.RawFd
  mut leased : Bool
  mut closed : Bool
  mut broken : Bool
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
async fn Connection::run(
  conn : Connection,
  sql : String,
  params : Array[Value],
) -> @sql.Response[Row, Command] {
  guard !conn.closed && !conn.broken else { raise CompletionLost }
  let statements = [statement(sql, params~)]
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
  @async.protect_from_cancel(async fn() {
    let mut completed = false
    defer (if !completed { conn.broken = true })
    let db = conn.db
    c_db_reset(db, statements.length())
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
    let names = columns.map(c => c.0)
    let rows = Array::makei(c_db_rows(db), row => {
      let values = Array::makei(columns.length(), col => {
        let (_, kind) = columns[col]
        if c_db_null(db, row, col) {
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
      })
      { columns: names, values, }
    })
    {
      rows,
      metadata: {
        has_rows: !columns.is_empty(),
        affected_rows: c_db_affected(db),
        insert_id: c_db_insert_id(db),
      },
    }
  })
}

///|
async fn Connection::recycle(self : Connection, discard : Bool) -> Unit {
  guard !self.broken else { raise CompletionLost }
  @async.protect_from_cancel(async fn() {
    c_db_recycle(self.db, discard)
    c_db_submit(self.db)
    let mut completed = false
    defer (if !completed { self.broken = true })
    guard self.fd.read(FixedArray::make(1, b'\x00')) == 1 else {
      raise CompletionLost
    }
    completed = true
    let code = c_db_error(self.db)
    guard code == 0 else { raise ServerError(code) }
  })
}

///|
/// Connector/C's prepared-statement protocol does not accept all transaction
/// control commands. Only adapter-generated control SQL uses this worker job.
async fn Connection::control(self : Connection, sql : String) -> Unit {
  guard !self.closed && !self.broken else { raise CompletionLost }
  @async.protect_from_cancel(async fn() {
    c_db_control(self.db, @utf8.encode(sql))
    c_db_submit(self.db)
    let mut completed = false
    defer (if !completed { self.broken = true })
    guard self.fd.read(FixedArray::make(1, b'\x00')) == 1 else {
      raise CompletionLost
    }
    completed = true
    let code = c_db_error(self.db)
    guard code == 0 else { raise ServerError(code) }
  })
}
