///|
suberror Failure {
  Body
  Query
  Commit
  Rollback
  Release
}

///|
fn fake(
  events : Array[String],
  commit_fails? : Bool = false,
  rollback_fails? : Bool = false,
  release_fails? : Bool = false,
) -> @sql_session.Database[Int, Int, Int, Unit] raise {
  @sql_session.Database::new(
    {
      acquire: () => 1,
      close: () => events.push("close"),
      release: fn(_, discard) raise {
        events.push(if discard { "discard" } else { "release" })
        if release_fails {
          raise Release
        }
      },
      executor: @sql_session.Combined(fn(_, sql, _) raise {
        if sql == "fail" {
          raise Query
        }
        { rows: [1], metadata: 1, }
      }),
      begin: (_, _) => events.push("begin"),
      commit: fn(_) raise {
        events.push("commit")
        if commit_fails {
          raise Commit
        }
      },
      rollback: fn(_) raise {
        events.push("rollback")
        if rollback_fails {
          raise Rollback
        }
      },
    },
    max_leases=1,
  )
}

///|
async test "lost commit response is not retried; session is discarded" {
  let events = []
  let db = fake(events, commit_fails=true)
  defer db.close()
  assert_true(
    try db.with_transaction((), _ => ()) catch {
      @sql_session.CommitOutcomeUnknown(Commit) => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_eq(events, ["begin", "commit", "discard"])
  assert_eq(db.status().leased, 0)
}

///|
async test "cancellation runs rollback and release through errdefer" {
  let events = []
  let db = fake(events)
  defer db.close()
  assert_eq(
    @async.with_timeout_opt(10, async fn() {
      db.with_transaction((), async fn(_) { @async.sleep(1000) })
    }),
    None,
  )
  assert_eq(events, ["begin", "rollback", "release"])
  assert_eq(db.status().leased, 0)
  assert_eq(db.query("ok"), [1])
}

///|
async test "rollback failure retains original error and retires the lease" {
  let events = []
  let db = fake(events, rollback_fails=true)
  defer db.close()
  assert_true(
    try db.with_transaction((), fn(_) -> Unit raise { raise Body }) catch {
      @sql_session.CleanupFailed(Some(Body), Rollback) => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_eq(events, ["begin", "rollback", "discard"])
  assert_eq(db.query("ok"), [1])
}

///|
async test "a swallowed SQL failure cannot silently commit" {
  let events = []
  let db = fake(events)
  defer db.close()
  assert_true(
    try
      db.with_transaction((), async fn(tx) {
        ignore(
          tx.query("fail") catch {
            Query => []
            error => raise error
          },
        )
      })
    catch {
      @sql_session.SessionFailed => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_eq(events, ["begin", "rollback", "discard"])
}

///|
async test "release failure reports cleanup without losing callback error" {
  let events = []
  let db = fake(events, release_fails=true)
  defer db.close()
  assert_true(
    try db.with_session(fn(_) -> Unit raise { raise Body }) catch {
      @sql_session.CleanupFailed(Some(Body), Release) => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  assert_eq(db.status().leased, 0)
  assert_true(
    try db.query("ok") catch {
      @sql_session.CleanupFailed(None, Release) => true
      error => raise error
    } noraise {
      _ => false
    },
  )
}

///|
async test "unjoined operation drains before release, rejects new operations" {
  let started : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
  let finish : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
  let retiring : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
  let events : Array[String] = []
  let db : @sql_session.Database[Int, Int, Int, Unit] = @sql_session.Database::new(
    {
      acquire: () => 1,
      close: () => (),
      release: (_, _) => events.push("released"),
      executor: @sql_session.Combined(async fn(_, _, _) {
        @async.protect_from_cancel(async fn() {
          started.put(())
          finish.get()
          events.push("drained")
          { rows: [1], metadata: 1, }
        })
      }),
      begin: (_, _) => (),
      commit: _ => events.push("commit"),
      rollback: _ => events.push("rollback"),
    },
    max_leases=1,
  )
  defer db.close()
  @async.with_task_group(async fn(group) {
    let escaped : Ref[@sql_session.Session[Int, Int, Int]?] = { val: None, }
    let scope = group.spawn(async fn() {
      try
        db.with_transaction((), async fn(tx) {
          escaped.val = Some(tx)
          group.spawn_bg(async fn() { ignore(tx.query("slow")) })
          started.get()
          retiring.put(())
        })
      catch {
        @sql_session.OperationInProgress => true
        error => raise error
      } noraise {
        _ => false
      }
    })
    retiring.get()
    assert_true(
      try escaped.val.unwrap().query("new") catch {
        @sql_session.SessionReleased => true
        error => raise error
      } noraise {
        _ => false
      },
    )
    assert_eq(events.length(), 0)
    finish.put(())
    assert_true(scope.wait())
  })
  assert_eq(events, ["drained", "rollback", "released"])
}
