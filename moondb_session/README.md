# Hosi121/moondb_session

Scoped transactions and bounded admission for existing
[`moonbitstack/moondb@0.1.8`](https://github.com/moonbitstack/moonorm/tree/master/db)
`AsyncDriver` implementations. Native MoonBit; Apache-2.0.

After registry publication: `moon add Hosi121/moondb_session`.
Import `"Hosi121/moondb_session" @sessions`, `"moonbitstack/moondb"`, and
`"moonbitlang/async"` in the consumer package.

```moonbit
// acquire/release/close are callbacks for the caller's connection source.
let db = @sessions.database(acquire~, release~, close~, max_leases=4)
defer @async.protect_from_cancel(async fn() { db.close_and_wait() })
db.with_transaction((), async fn(tx) {
  let rows = tx.query("SELECT value FROM counters WHERE id = $1", params=[@moondb.Int(1)])
  ignore(tx.execute("UPDATE counters SET value = $1 WHERE id = $2",
    params=[@moondb.Int64(rows[0].int64(0) + 1L), @moondb.Int(1)]))
})
```

`database` returns `Database[Value, Row, ExecResult, Unit]`, using the upstream
moondb types unchanged. `database_with_options` accepts a typed
`begin(connection, options)` callback and preserves its options type.
Placeholders and SQL remain the backend's responsibility.

## Connection-source contract

- `acquire: async () -> C`, where `C: AsyncDriver`, transfers one exclusive
  connection. It must close any connection it cannot return, including on
  cancellation. It must not return a connection already owned by another scope.
- `release: async (C, Bool) -> Unit` takes ownership back. The boolean means
  **discard**: never put that connection back into service. It may already have
  been closed after a failed operation. A reusable source must rollback/reset
  session state before reusing a healthy connection, and retire it if reset fails.
- `close: () -> Unit` stops the source and wakes pending acquisition calls.
  Existing leases are released through the normal callback after their scopes end.

The adapter owns admission permits, not a second physical pool. A source may
open/close per scope, or delegate to an existing pool. Limits default to 128
waiters and a 5-second checkout timeout; capacity is `max_leases`.

SQL operations drain under cancellation protection. On an operation error the
connection is closed before being discarded, because AsyncDriver alone cannot
prove that a partial protocol exchange is safe to reuse. Closing also aborts a
transaction on that connection; ROLLBACK is not sent to the broken stream.
Ordinary errors retain their upstream type. Callback cancellation rolls back an
otherwise healthy transaction before release. No writes are retried.

## Deliberate boundaries

- `query` and `execute` delegate separately and exactly once. `run` raises
  `CombinedResultUnavailable`; the upstream contract has no combined result.
- Value cases, row lookup, command metadata and errors are moondb's. In
  particular, its first-match duplicate-column lookup and its limited numeric
  value model are not silently changed. Prefer explicit column aliases.
- This adapter collects rows using upstream `query`; it adds no row/byte memory
  limit or streaming API. Use an appropriate driver or bounded SQL queries.
- It does not adopt the synchronous `moondb.Pool` for an async server, implement
  a wire protocol, or convert native unsigned/decimal values to Double.

The [upstream-driver consumer](https://github.com/Hosi121/moonbit-sessions/tree/main/examples/moondb)
uses `moonbitstack/moonpostgres@0.6.0` and runs the shared lifetime suite against
PostgreSQL 17. It opens/closes per scope to exercise this contract without adding
another production pool. Other AsyncDriver implementations need their own
conformance run; compile-time trait conformance alone is insufficient.
