///|
/// Only SQL dialect and codecs vary; every ownership test below is shared.
/// Use a disposable database with one connection, one waiter and a finite checkout timeout.
pub(all) struct Case[P, R, O] {
  name : String
  options : O
  read_only : O
  insert : String
  params : (Int, String) -> Array[P]
  number : (R, String) -> Int64 raise
  duplicate : (R) -> Unit raise
  constraint_error : (Error) -> Bool
  read_only_error : (Error) -> Bool
  connection_id : String
  slow : String
  set_session : String
  check_session : String
}

///|
pub(all) suberror Abort

///|
pub async fn[P, R, M, O] run(
  db : @sql.Database[P, R, M, O],
  case : Case[P, R, O],
) -> Unit {
  println(case.name + ": sessions and rows")
  ignore(db.execute("DROP TABLE IF EXISTS servicekit_shared"))
  ignore(
    db.execute(
      "CREATE TABLE servicekit_shared (id INTEGER PRIMARY KEY, value VARCHAR(100) NOT NULL)",
    ),
  )
  let count = async fn() {
    (case.number)(
      db.query("SELECT COUNT(*) AS n FROM servicekit_shared")[0],
      "n",
    )
  }
  let escaped = db.with_session(session => session)
  assert_true(
    try escaped.query("SELECT 1") catch {
      @sql.SessionReleased => true
      error => raise error
    } noraise {
      _ => false
    },
  )

  db.with_session(async fn(session) {
    let id = (case.number)(session.query(case.connection_id)[0], "n")
    assert_eq((case.number)(session.query(case.connection_id)[0], "n"), id)
    ignore(session.execute(case.set_session))
    ignore(
      session.execute(
        "CREATE TEMPORARY TABLE servicekit_session_temp (id INTEGER)",
      ),
    )
  })
  assert_eq((case.number)(db.query(case.check_session)[0], "n"), 1L)
  // The second scope must be able to create the same temporary table anew.
  db.with_session(async fn(session) {
    ignore(
      session.execute(
        "CREATE TEMPORARY TABLE servicekit_session_temp (id INTEGER)",
      ),
    )
  })
  (case.duplicate)(db.query("SELECT 1 AS duplicate, 2 AS duplicate")[0])

  println(case.name + ": callback transactions")
  let retired_tx : Ref[@sql.Session[P, R, M]?] = { val: None, }
  let result = db.with_transaction(case.options, async fn(tx) {
    retired_tx.val = Some(tx)
    let id = (case.number)(tx.query(case.connection_id)[0], "n")
    ignore(tx.execute(case.insert, params=(case.params)(1, "one")))
    let n = (case.number)(
      tx.query("SELECT COUNT(*) AS n FROM servicekit_shared")[0],
      "n",
    )
    if n == 1L {
      ignore(tx.execute(case.insert, params=(case.params)(2, "two")))
    }
    assert_eq((case.number)(tx.query(case.connection_id)[0], "n"), id)
    42
  })
  assert_eq(result, 42)
  assert_eq(count(), 2L)
  assert_true(
    try
      db.with_transaction(case.read_only, async fn(tx) {
        ignore(tx.execute(case.insert, params=(case.params)(3, "read-only")))
      })
    catch {
      error => if (case.read_only_error)(error) { true } else { raise error }
    } noraise {
      _ => false
    },
  )
  assert_eq(count(), 2L)

  assert_true(
    try
      db.with_transaction(case.options, async fn(tx) {
        ignore(tx.execute(case.insert, params=(case.params)(3, "before-error")))
        ignore(
          tx.execute(case.insert, params=(case.params)(1, "duplicate-key")),
        )
      })
    catch {
      error => if (case.constraint_error)(error) { true } else { raise error }
    } noraise {
      _ => false
    },
  )
  assert_eq(count(), 2L)
  assert_true(
    try retired_tx.val.unwrap().query("SELECT 1") catch {
      @sql.SessionReleased => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_true(
    try
      db.with_transaction(case.options, async fn(tx) -> Unit {
        ignore(tx.execute(case.insert, params=(case.params)(3, "rollback")))
        raise Abort
      })
    catch {
      Abort => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_eq(count(), 2L)

  println(case.name + ": in-flight cancellation")
  // A canceled SQL operation is drained before rollback and pool reuse.
  assert_eq(
    @async.with_timeout_opt(30, async fn() {
      db.with_transaction(case.options, async fn(tx) {
        ignore(tx.execute(case.insert, params=(case.params)(4, "cancel")))
        ignore(tx.query(case.slow))
      })
    }),
    None,
  )
  assert_eq(count(), 2L)
  // An old timeout/cancel must not affect this borrower's operation.
  ignore(db.query(case.slow))

  // Cancel between SQL operations, while user code is suspended.
  assert_eq(
    @async.with_timeout_opt(30, async fn() {
      db.with_transaction(case.options, async fn(tx) {
        ignore(
          tx.execute(case.insert, params=(case.params)(5, "cancel-callback")),
        )
        @async.sleep(1000)
      })
    }),
    None,
  )
  assert_eq(count(), 2L)

  db.with_session(async fn(session) {
    @async.with_task_group(async fn(group) {
      let started : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
      let first = group.spawn(async fn() {
        started.put(())
        ignore(session.query(case.slow))
      })
      started.get()
      assert_true(
        try session.query("SELECT 1") catch {
          @sql.OperationInProgress => true
          error => raise error
        } noraise {
          _ => false
        },
      )
      first.wait()
    })
  })

  println(case.name + ": admission and waiting cancellation")
  // The only connection is held; cancellation/timeout must restore admission.
  db.with_session(async fn(_) {
    assert_eq(
      @async.with_timeout_opt(15, async fn() { ignore(db.query("SELECT 1")) }),
      None,
    )
    assert_eq(db.status().acquiring, 0)
    assert_true(
      try db.query("SELECT 1") catch {
        @sql.CheckoutTimeout => true
        error => raise error
      } noraise {
        _ => false
      },
    )
    @async.with_task_group(async fn(group) {
      let waiting = group.spawn(async fn() {
        @async.with_timeout_opt(40, async fn() { ignore(db.query("SELECT 1")) })
      })
      while db.status().acquiring == 0 {
        @async.pause()
      }
      assert_true(
        try db.query("SELECT 1") catch {
          @sql.Saturated => true
          error => raise error
        } noraise {
          _ => false
        },
      )
      assert_eq(waiting.wait(), None)
    })
  })
  assert_eq(db.status().acquiring, 0)
  assert_eq(count(), 2L)
  ignore(db.execute("DROP TABLE servicekit_shared"))

  println(case.name + ": shutdown")
  // Closing rejects queued borrowers but lets already borrowed sessions finish.
  @async.with_task_group(async fn(group) {
    let borrowed : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
    let continue_scope : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
    let running = group.spawn(async fn() {
      db.with_session(async fn(session) {
        borrowed.put(())
        continue_scope.get()
        ignore(session.query("SELECT 1"))
      })
    })
    borrowed.get()
    let waiting = group.spawn(async fn() {
      try db.query("SELECT 1") catch {
        @sql.Closed => true
        error => raise error
      } noraise {
        _ => false
      }
    })
    while db.status().acquiring == 0 {
      @async.pause()
    }
    db.close()
    db.close()
    assert_true(waiting.wait())
    assert_eq(db.status().leased, 1)
    continue_scope.put(())
    running.wait()
  })
  db.close_and_wait()
  assert_eq(db.status().leased, 0)
  assert_true(
    try db.query("SELECT 1") catch {
      @sql.Closed => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  println(case.name + " shared SQL conformance passed")
}
