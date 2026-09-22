///|
struct Probe {
  events : Array[String]
}

///|
impl @moondb.AsyncDriver for Probe with fn query(self, sql, params) {
  self.events.push("query:" + sql)
  if sql == "fail" {
    raise @moondb.QueryError("original")
  }
  if sql == "slow" {
    @async.sleep(50)
    self.events.push("drained")
  }
  [{ columns: ["value"], values: params, }]
}

///|
impl @moondb.AsyncDriver for Probe with fn execute(self, sql, _) {
  self.events.push("execute:" + sql)
  { rows_affected: 7L, last_insert_id: 9007199254740993L, }
}

///|
impl @moondb.AsyncDriver for Probe with fn begin(self) {
  self.events.push("begin")
}

///|
impl @moondb.AsyncDriver for Probe with fn commit(self) {
  self.events.push("commit")
}

///|
impl @moondb.AsyncDriver for Probe with fn rollback(self) {
  self.events.push("rollback")
}

///|
impl @moondb.AsyncDriver for Probe with fn close(self) {
  self.events.push("close")
}

///|
fn probe(
  events : Array[String],
) -> @sql.Database[@moondb.Value, @moondb.Row, @moondb.ExecResult, Unit] raise {
  database(
    acquire=fn() {
      events.push("acquire")
      Probe::{ events, }
    },
    release=fn(_, discard) {
      events.push(if discard { "discard" } else { "release" })
    },
    close=fn() { events.push("shutdown") },
    max_leases=1,
    max_waiters=1,
    checkout_timeout_ms=50,
  )
}

///|
async test "reuse moondb values and dispatch each statement once" {
  let events = []
  let db = probe(events)
  defer db.close()
  db.with_transaction((), async fn(tx) {
    let row = tx.query("SELECT", params=[@moondb.Int64(9007199254740993L)])[0]
    assert_eq(row.int64(0), 9007199254740993L)
    let metadata = tx.execute("UPDATE")
    assert_eq(metadata.rows_affected, 7L)
    assert_eq(metadata.last_insert_id, 9007199254740993L)
  })
  assert_eq(events, [
    "acquire", "begin", "query:SELECT", "execute:UPDATE", "commit", "release",
  ])
}

///|
async test "combined result is unavailable without executing or replaying SQL" {
  let events = []
  let db = probe(events)
  defer db.close()
  assert_true(
    try db.run("INSERT") catch {
      @sql.CombinedResultUnavailable => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_eq(events, ["acquire", "discard"])
}

///|
async test "query error closes protocol state before discarding, preserving error" {
  let events = []
  let db = probe(events)
  defer db.close()
  assert_true(
    try db.with_transaction((), async fn(tx) { tx.query("fail") }) catch {
      @moondb.QueryError("original") => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_eq(events, ["acquire", "begin", "query:fail", "close", "discard"])
  assert_eq(db.status().leased, 0)
}

///|
async test "cancelled query drains before rollback and release" {
  let events = []
  let db = probe(events)
  defer db.close()
  assert_eq(
    @async.with_timeout_opt(10, async fn() {
      db.with_transaction((), async fn(tx) { ignore(tx.query("slow")) })
    }),
    None,
  )
  assert_eq(events, [
    "acquire", "begin", "query:slow", "drained", "rollback", "release",
  ])
  assert_eq(db.status().leased, 0)
}

///|
async test "admission permits bound a source with no pool and survive cancellation" {
  let events = []
  let db = probe(events)
  defer db.close()
  db.with_session(async fn(_) {
    assert_eq(
      @async.with_timeout_opt(10, async fn() { ignore(db.query("waiting")) }),
      None,
    )
    assert_eq(events, ["acquire"])
    assert_eq(db.status().acquiring, 0)
  })
  ignore(db.query("next"))
  assert_eq(events, ["acquire", "release", "acquire", "query:next", "release"])
}

///|
async test "checkout timeout retires a connection returned after protected acquisition" {
  let events = []
  let db = database(
    acquire=async fn() {
      @async.protect_from_cancel(async fn() {
        @async.sleep(50)
        events.push("acquired")
        Probe::{ events, }
      })
    },
    release=fn(_, discard) {
      events.push(if discard { "discard" } else { "release" })
    },
    close=fn() { () },
    max_leases=1,
    checkout_timeout_ms=10,
  )
  defer db.close()
  assert_true(
    try db.query("never") catch {
      @sql.CheckoutTimeout => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_eq(events, ["acquired", "discard"])
  assert_eq(db.status().acquiring, 0)
  assert_eq(db.status().leased, 0)
  // A second attempt reaches the source again, proving its permit was returned.
  ignore(
    db.query("never") catch {
      @sql.CheckoutTimeout => []
      error => raise error
    },
  )
  assert_eq(events, ["acquired", "discard", "acquired", "discard"])
}

///|
async test "caller cancellation retires a late acquisition before returning" {
  let events = []
  let db = database(
    acquire=async fn() {
      @async.protect_from_cancel(async fn() {
        @async.sleep(50)
        events.push("acquired")
        Probe::{ events, }
      })
    },
    release=fn(_, discard) {
      events.push(if discard { "discard" } else { "release" })
    },
    close=fn() { () },
    max_leases=1,
  )
  defer db.close()
  assert_eq(
    @async.with_timeout_opt(10, async fn() { ignore(db.query("never")) }),
    None,
  )
  assert_eq(events, ["acquired", "discard"])
  ignore(db.query("next"))
  assert_eq(events, ["acquired", "discard", "acquired", "query:next", "release"])
}
