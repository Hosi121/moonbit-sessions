///|
pub(all) suberror SqlError {
  Closed
  Saturated
  CheckoutTimeout
  InvalidConfig(String)
  SessionReleased
  SessionFailed
  OperationInProgress
  CommitOutcomeUnknown(Error)
  CleanupFailed(Error?, Error)
  AmbiguousColumn(String)
  ColumnNotFound(String)
  CombinedResultUnavailable
}

///|
/// Metadata stays specific to the backend. execute() drains and drops rows;
/// use query() for RETURNING, or run() when both rows and metadata are needed.
pub(all) struct Response[R, M] {
  rows : Array[R]
  metadata : M
}

///|
/// Preserve the upstream execution API. Separate query/execute drivers need not
/// invent command metadata for queries or execute a statement twice. run() is an
/// optional capability, available only for Combined executors.
pub(all) enum Executor[C, P, R, M] {
  Combined(async (C, String, Array[P]) -> Response[R, M])
  Separate(
    query~ : async (C, String, Array[P]) -> Array[R],
    execute~ : async (C, String, Array[P]) -> M
  )
}

///|
/// Lifetime adapter. acquire must be cancellation-safe. Every operation must drain
/// or discard unfinished work before returning/raising. release must retire a
/// dirty connection even when cleanup raises. No automatic retries of writes.
pub(all) struct Driver[C, P, R, M, O] {
  acquire : async () -> C
  release : async (C, Bool) -> Unit
  close : () -> Unit
  executor : Executor[C, P, R, M]
  begin : async (C, O) -> Unit
  commit : async (C) -> Unit
  rollback : async (C) -> Unit
}

///|
pub struct Status {
  leased : Int
  acquiring : Int
  max_leases : Int
  max_waiters : Int
  closed : Bool
}

///|
pub struct Session[P, R, M] {
  priv run_impl : (async (String, Array[P]) -> Response[R, M])?
  priv query_impl : async (String, Array[P]) -> Array[R]
  priv execute_impl : async (String, Array[P]) -> M
  priv mut live : Bool
  priv mut busy : Bool
  priv mut failed : Bool
  priv mut drained : @async.Queue[Unit]?
}

///|
priv struct Lease[P, R, M, O] {
  session : Session[P, R, M]
  begin : async (O) -> Unit
  commit : async () -> Unit
  rollback : async () -> Unit
  release : async (Bool) -> Unit
}

///|
/// One async event loop. Admission is bounded; physical pooling belongs to the
/// adapter. O is the backend's transaction-options type, not a common SQL dialect.
pub struct Database[P, R, M, O] {
  priv acquire : async () -> Lease[P, R, M, O]
  priv close_impl : () -> Unit
  priv max_leases : Int
  priv max_waiters : Int
  priv checkout_timeout_ms : Int
  priv mut acquiring : Int
  priv mut leased : Int
  priv mut closed : Bool
  priv finished : @async.Queue[Unit]
}

///|
pub fn[C, P, R, M, O] Database::new(
  driver : Driver[C, P, R, M, O],
  max_leases~ : Int,
  max_waiters? : Int = 128,
  checkout_timeout_ms? : Int = 5000,
) -> Database[P, R, M, O] raise {
  guard max_leases > 0 &&
    max_waiters >= 0 &&
    max_waiters <= 1000000 &&
    max_leases <= 1000000 &&
    checkout_timeout_ms > 0 else {
    raise InvalidConfig("Invalid admission limits")
  }
  {
    acquire: async fn() {
      let conn = (driver.acquire)()
      {
        session: {
          run_impl: match driver.executor {
            Combined(run) =>
              Some(async fn(sql, params) { run(conn, sql, params) })
            Separate(..) => None
          },
          query_impl: async fn(sql, params) {
            match driver.executor {
              Combined(run) => run(conn, sql, params).rows
              Separate(query~, ..) => query(conn, sql, params)
            }
          },
          execute_impl: async fn(sql, params) {
            match driver.executor {
              Combined(run) => run(conn, sql, params).metadata
              Separate(execute~, ..) => execute(conn, sql, params)
            }
          },
          live: true,
          busy: false,
          failed: false,
          drained: None,
        },
        begin: async fn(options) { (driver.begin)(conn, options) },
        commit: async fn() { (driver.commit)(conn) },
        rollback: async fn() { (driver.rollback)(conn) },
        release: async fn(discard) { (driver.release)(conn, discard) },
      }
    },
    close_impl: driver.close,
    max_leases,
    max_waiters,
    checkout_timeout_ms,
    acquiring: 0,
    leased: 0,
    closed: false,
    finished: @async.Queue(kind=Unbounded),
  }
}

///|
pub fn[P, R, M, O] Database::status(self : Database[P, R, M, O]) -> Status {
  {
    leased: self.leased,
    acquiring: self.acquiring,
    max_leases: self.max_leases,
    max_waiters: self.max_waiters,
    closed: self.closed,
  }
}

///|
fn[P, R, M, O] Database::notify_closed(self : Database[P, R, M, O]) -> Unit {
  if self.closed && self.leased == 0 && self.acquiring == 0 {
    self.finished.close()
  }
}

///|
/// Existing leases finish their scopes; queued/new borrowers fail.
pub fn[P, R, M, O] Database::close(self : Database[P, R, M, O]) -> Unit {
  if !self.closed {
    self.closed = true
    (self.close_impl)()
    self.notify_closed()
  }
}

///|
pub async fn[P, R, M, O] Database::close_and_wait(
  self : Database[P, R, M, O],
) -> Unit {
  self.close()
  ignore(
    self.finished.get() catch {
      error => if self.leased != 0 || self.acquiring != 0 { raise error }
    },
  )
}

///|
async fn[P, R, M, T] Session::guarded(
  self : Session[P, R, M],
  f : async () -> T,
) -> T {
  guard self.live else { raise SessionReleased }
  guard !self.busy else { raise OperationInProgress }
  guard !self.failed else { raise SessionFailed }
  self.busy = true
  defer {
    self.busy = false
    if self.drained is Some(queue) {
      ignore(queue.try_put(()) catch { _ => false })
    }
  }
  errdefer {
    self.failed = true
  }
  f()
}

///|
/// Available when the upstream driver returns rows and metadata together.
/// A separate query/execute driver raises CombinedResultUnavailable; no SQL is
/// guessed, replayed, or given fabricated metadata.
pub async fn[P, R, M] Session::run(
  self : Session[P, R, M],
  sql : String,
  params? : Array[P] = [],
) -> Response[R, M] {
  self.guarded(async fn() {
    match self.run_impl {
      Some(run) => run(sql, params)
      None => raise CombinedResultUnavailable
    }
  })
}

///|
pub async fn[P, R, M] Session::query(
  self : Session[P, R, M],
  sql : String,
  params? : Array[P] = [],
) -> Array[R] {
  self.guarded(async fn() { (self.query_impl)(sql, params) })
}

///|
pub async fn[P, R, M] Session::execute(
  self : Session[P, R, M],
  sql : String,
  params? : Array[P] = [],
) -> M {
  self.guarded(async fn() { (self.execute_impl)(sql, params) })
}

///|
async fn[P, R, M] Session::retire(self : Session[P, R, M]) -> Unit {
  self.live = false
  if self.busy {
    let queue = @async.Queue(kind=Unbounded)
    self.drained = Some(queue)
    queue.get()
  }
}

///|
async fn[P, R, M, O] Database::checkout(
  self : Database[P, R, M, O],
) -> Lease[P, R, M, O] {
  guard !self.closed else { raise Closed }
  guard self.leased + self.acquiring < self.max_leases + self.max_waiters else {
    raise Saturated
  }
  self.acquiring += 1
  defer {
    self.acquiring -= 1
    self.notify_closed()
  }
  // This bounds checkout, including create/recycle. It cannot preempt a driver
  // that must first drain a native operation; its cleanup remains mandatory.
  let lease = {
    // A driver may defer cancellation while establishing/recycling a connection.
    // with_timeout can then fail while leaving its body's returned lease behind.
    // Keep ownership here until the timeout scope itself has returned successfully.
    let acquired : Ref[Lease[P, R, M, O]?] = { val: None, }
    let mut primary : Error? = None
    errdefer @async.protect_from_cancel(async fn() {
      if acquired.val is Some(lease) {
        (lease.release)(true) catch {
          error => raise CleanupFailed(primary, error)
        }
      }
    })
    @async.with_timeout(
      self.checkout_timeout_ms,
      async fn() {
        let lease = (self.acquire)()
        acquired.val = Some(lease)
        lease
      },
      error=CheckoutTimeout,
    ) catch {
      error => {
        primary = Some(error)
        if self.closed {
          raise Closed
        } else {
          raise error
        }
      }
    }
  }
  if self.closed {
    @async.protect_from_cancel(async fn() { (lease.release)(true) })
    raise Closed
  }
  self.leased += 1
  lease
}

///|
async fn[P, R, M, O, T] Database::scoped(
  self : Database[P, R, M, O],
  options : O?,
  f : async (Session[P, R, M]) -> T,
) -> T {
  let lease = self.checkout()
  defer {
    self.leased -= 1
    self.notify_closed()
  }
  let mut started = false
  let mut discard = false
  let mut released = false
  let mut primary : Error? = None
  // Cancellation bypasses ordinary catch in MoonBit. Resource cleanup must be
  // in errdefer, including cancellation between callback operations.
  errdefer @async.protect_from_cancel(async fn() {
    lease.session.retire()
    let mut cleanup_error : Error? = None
    discard = discard || lease.session.failed
    if started {
      (lease.rollback)() catch {
        error => {
          discard = true
          cleanup_error = Some(error)
        }
      }
    }
    if !released {
      released = true
      (lease.release)(discard) catch {
        error =>
          cleanup_error = Some(
            match cleanup_error {
              Some(previous) => CleanupFailed(Some(previous), error)
              None => error
            },
          )
      }
    }
    if cleanup_error is Some(error) {
      raise CleanupFailed(primary, error)
    }
  })
  let outcome : Result[T, Error] = try {
    if options is Some(options) {
      discard = true
      @async.protect_from_cancel(async fn() { (lease.begin)(options) })
      started = true
      discard = false
    }
    let result = f(lease.session)
    lease.session.live = false
    guard !lease.session.busy else { raise OperationInProgress }
    guard !lease.session.failed else { raise SessionFailed }
    // Observe cancellation deferred by the last operation before issuing COMMIT.
    @async.sleep(0)
    if started {
      started = false
      discard = true
      @async.protect_from_cancel(lease.commit) catch {
        error => raise CommitOutcomeUnknown(error)
      }
      discard = false
    }
    @async.protect_from_cancel(async fn() {
      lease.session.retire()
      released = true
      (lease.release)(false) catch {
        error => raise CleanupFailed(None, error)
      }
    })
    Ok(result)
  } catch {
    error => Err(error)
  }
  match outcome {
    Ok(value) => value
    Err(error) => {
      primary = Some(error)
      raise error
    }
  }
}

///|
pub async fn[P, R, M, O, T] Database::with_session(
  self : Database[P, R, M, O],
  f : async (Session[P, R, M]) -> T,
) -> T {
  self.scoped(None, f)
}

///|
pub async fn[P, R, M, O, T] Database::with_transaction(
  self : Database[P, R, M, O],
  options : O,
  f : async (Session[P, R, M]) -> T,
) -> T {
  self.scoped(Some(options), f)
}

///|
pub async fn[P, R, M, O] Database::run(
  self : Database[P, R, M, O],
  sql : String,
  params? : Array[P] = [],
) -> Response[R, M] {
  self.with_session(async fn(session) { session.run(sql, params~) })
}

///|
pub async fn[P, R, M, O] Database::query(
  self : Database[P, R, M, O],
  sql : String,
  params? : Array[P] = [],
) -> Array[R] {
  self.with_session(async fn(session) { session.query(sql, params~) })
}

///|
pub async fn[P, R, M, O] Database::execute(
  self : Database[P, R, M, O],
  sql : String,
  params? : Array[P] = [],
) -> M {
  self.with_session(async fn(session) { session.execute(sql, params~) })
}

///|
/// Ordered row adapters can share checked name lookup without sharing codecs.
pub fn column_index(names : Array[String], name : String) -> Int raise {
  let mut found : Int? = None
  for i, candidate in names {
    if candidate == name {
      guard found is None else { raise AmbiguousColumn(name) }
      found = Some(i)
    }
  }
  match found {
    Some(i) => i
    None => raise ColumnNotFound(name)
  }
}
