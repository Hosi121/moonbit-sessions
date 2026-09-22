///|
priv struct Handle[C] {
  connection : C
  mut broken : Bool
}

///|
/// Add lifetime management to an existing AsyncDriver and its connection source.
/// acquire transfers an exclusive connection; release receives discard=true when
/// it must not be reused. Both callbacks must be cancellation-safe. A reusable
/// pool's release callback must reset transaction/session state before reuse.
/// close stops that source from accepting new work; active leases finish normally.
/// No Value, Row or ExecResult conversions occur here.
pub fn[C : @moondb.AsyncDriver] database(
  acquire~ : async () -> C,
  release~ : async (C, Bool) -> Unit,
  close~ : () -> Unit,
  max_leases~ : Int,
  max_waiters? : Int = 128,
  checkout_timeout_ms? : Int = 5000,
) -> @sql.Database[@moondb.Value, @moondb.Row, @moondb.ExecResult, Unit] raise {
  database_with_options(
    acquire~,
    release~,
    close~,
    begin=async fn(conn, _) { @moondb.AsyncDriver::begin(conn) },
    max_leases~,
    max_waiters~,
    checkout_timeout_ms~,
  )
}

///|
/// Keep backend transaction options with the backend. The supplied begin callback
/// opens a transaction with those options; commit/rollback use AsyncDriver.
pub fn[C : @moondb.AsyncDriver, O] database_with_options(
  acquire~ : async () -> C,
  release~ : async (C, Bool) -> Unit,
  close~ : () -> Unit,
  begin~ : async (C, O) -> Unit,
  max_leases~ : Int,
  max_waiters? : Int = 128,
  checkout_timeout_ms? : Int = 5000,
) -> @sql.Database[@moondb.Value, @moondb.Row, @moondb.ExecResult, O] raise {
  guard max_leases > 0 && max_leases <= 1000000 else {
    raise @sql.InvalidConfig("Invalid admission limits")
  }
  let permits : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
  for _ in 0..<max_leases {
    ignore(permits.try_put(()))
  }
  @sql.Database::new(
    {
      acquire: async fn() {
        permits.get()
        errdefer ignore(permits.try_put(()) catch { _ => false })
        { connection: acquire(), broken: false, }
      },
      release: async fn(handle, discard) {
        defer ignore(permits.try_put(()) catch { _ => false })
        release(handle.connection, discard || handle.broken)
      },
      close: fn() {
        permits.close(error=@sql.Closed, clear=true)
        close()
      },
      executor: @sql.Separate(
        query=async fn(handle, sql, params) {
          @async.protect_from_cancel(async fn() {
            errdefer {
              handle.broken = true
              @moondb.AsyncDriver::close(handle.connection)
            }
            @moondb.AsyncDriver::query(handle.connection, sql, params)
          })
        },
        execute=async fn(handle, sql, params) {
          @async.protect_from_cancel(async fn() {
            errdefer {
              handle.broken = true
              @moondb.AsyncDriver::close(handle.connection)
            }
            @moondb.AsyncDriver::execute(handle.connection, sql, params)
          })
        },
      ),
      begin: async fn(handle, options) { begin(handle.connection, options) },
      commit: async fn(handle) {
        @moondb.AsyncDriver::commit(handle.connection)
      },
      rollback: async fn(handle) {
        // A failed operation closes the connection, which aborts its transaction.
        // Do not issue ROLLBACK into possibly unfinished protocol state.
        if !handle.broken {
          @moondb.AsyncDriver::rollback(handle.connection)
        }
      },
    },
    max_leases~,
    max_waiters~,
    checkout_timeout_ms~,
  )
}
