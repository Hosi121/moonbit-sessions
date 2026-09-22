# Hosi121/sql_session

A native MoonBit session-lifetime extension for existing SQL drivers. Apache-2.0. This module imports only
`moonbitlang/async@0.22.1`; it contains no SQL dialect, database protocol, schema,
or application policies. MySQL, community PostgreSQL, and moondb AsyncDriver integration share this implementation.

After registry publication: `moon add Hosi121/sql_session`.

## Application API

`Database[P, R, M, O]` retains the driver's parameter, row, command metadata and
transaction-options types. See [generated signatures](src/pkg.generated.mbti).

- `query(sql, params=[]) -> Array[R]` collects rows.
- `execute(sql, params=[]) -> M` drains any rows and returns command metadata.
  Use `query` for SQL `RETURNING`. `run` returns both rows and metadata only
  for a `Combined` executor; `Separate` raises `CombinedResultUnavailable`.
- `with_session(callback)` borrows one physical session for the callback.
- `with_transaction(options, callback)` begins on that session, commits the
  callback's result, or rolls back on failure/cancellation. The callback can read
  rows and choose its next SQL operation. There are no nested transaction or
  savepoint helpers in this first shared API.
- `close()` rejects new/queued borrowers and lets existing scopes finish.
  `close_and_wait()` also waits for their cleanup. Call it outside borrowed
  scopes, after arranging that active callbacks can finish.
- `status()` reports leased/acquiring counts, limits and closed state. Acquiring
  includes connection creation/recycling, not only requests waiting for a slot.

A session is invalid after the callback. Concurrent operations on the same
session raise `OperationInProgress`; returning with an unjoined operation is
also an error, and cleanup waits for it before reusing/discarding the connection.
A SQL operation error poisons that scope: catching it does not allow a later
commit to succeed silently. This deliberately does not expose each driver's
savepoint recovery or concurrent pipelining through the shared API.

## Admission, cancellation and failures

Defaults are 128 waiting requests and a 5-second checkout timeout. Adapters pass
their actual connection capacity. At most `max_leases + max_waiters` requests
are admitted across acquisition and active scopes. There is no second pool or
connection queue here; acquisition remains the driver's responsibility.

If cancellation-protected acquisition returns a connection after its deadline,
the timeout scope retains ownership and retires that connection before raising.
The same rule applies to caller cancellation during acquisition. A late result
cannot leak a lease or permanently consume an admission permit.

Timeouts bound how long a caller waits before cancellation is requested; they do
not guarantee immediate preemption of native work. All shipped adapters drain
submitted operations. Transaction callback cancellation then rolls back before
release. A canceled autocommit write can still have succeeded. No write is retried.

`SqlError` preserves errors as typed `Error` causes:

- `Closed`, `Saturated`, `CheckoutTimeout`, `InvalidConfig` describe admission.
- `SessionReleased`, `SessionFailed`, `OperationInProgress` describe scope use.
- `CommitOutcomeUnknown(cause)` conservatively reports failed commit completion;
  it is not evidence that the write failed, and is not a retry recommendation.
- `CleanupFailed(primary?, cleanup)` retains callback and cleanup failures.
  Cancellation has no ordinary caught primary error; cleanup still runs in
  cancellation-protected `errdefer`. A failed/uncertain session is discarded.
- `AmbiguousColumn(name)` and `ColumnNotFound(name)` support ordered row adapters.

Driver SQL errors are otherwise preserved, including MySQL numeric codes and
PostgreSQL diagnostic fields. Do not infer SQL dialect or safe retry policy from
this generic interface. DDL implicit commits, manually issued transaction SQL,
and server-side effects retain their engine semantics; use the callback API
for managed transactions.

## Adapter SPI

`Driver[C, P, R, M, O]` supplies typed acquire/release/close, an executor, begin, commit,
and rollback operations. `Database::new(driver, max_leases=...)` captures the
concrete `C` in typed closures. It does not turn the connection or values into
an untyped object.

`Executor::Combined` takes one rows-plus-metadata operation. `Executor::Separate`
takes existing query and execute operations independently; neither replays SQL
nor fabricates metadata. The moondb adapter uses this shape directly.

`acquire` must restore its resources if canceled before returning. Query, execute and
transaction operations must not leave unowned in-flight work when they finish
or raise. `release(connection, discard)` must either reset for reuse or retire
the physical connection, even when reset raises. `close` must wake waiting
acquisitions while preserving active leases. Set `max_leases` to the underlying
pool's capacity and do not resize that pool behind the facade.

See the [shared real-DB suite](https://github.com/Hosi121/moonbit-sessions/blob/main/examples/conformance/src/contract.mbt) and
[deterministic fault tests](src/database_test.mbt) before adding an adapter.
SQLite, streaming, generated schema types, JS/Wasm, and cross-driver parameter
coercion are not implemented here.
