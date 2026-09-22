# hosi121/mysql

Native MySQL adapter for the [shared SQL contract](../sql/README.md), using one
MariaDB Connector/C worker per physical connection. It imports `hosi121/sql`
and async, with no dependency on PostgreSQL, WebSocket, an application or Node.

Version **0.2.0** changes rows to ordered columns/values and moves scope/admission
errors to `hosi121/sql`. Add `vendor/servicekit/sql` and `vendor/servicekit/mysql`
to your workspace, and import `hosi121/sql@0.1.0` / `hosi121/mysql@0.2.0` in
`moon.mod`. These are source modules, not Mooncakes releases.

The **consumer executable** needs Connector/C development files and:

```moonbit
options(link: { "native": { "cc-link-flags": "-lmariadb -lpthread" } })
```

The pinned moon does not propagate executable link flags from a library.

## API and values

```moonbit
let pool = @mysql.Pool::new(
  host="127.0.0.1", user="app", password="password", database="app", size=4,
)
let db = pool.database()
defer db.close()
let rows = db.query("SELECT name FROM users WHERE id=?", params=[Integer(42L)])
for row in rows {
  if row.get("name") is Some(Text(name)) { println(name) }
}
```

`pool.database()` returns
`@sql.Database[Value, Row, Command, TransactionOptions]`. Use
`db.with_transaction(@mysql.TransactionOptions::new(), callback)` for an
interactive transaction. Options expose typed isolation and optional read-only
mode. SQL remains MySQL SQL, including DDL's implicit-commit behavior.

- `Value`: Null, Text(String), Integer(Int64), Unsigned(UInt64), Float(Double),
  Decimal(String), Blob(Bytes). Native integer binds preserve all 64 bits.
  Decimal parameters bind decimal text; date/time results are text.
- `Row.columns` and `Row.values` are parallel, ordered arrays. `get_at(index)`
  returns an optional value. `get(name)` returns None for a missing column and
  raises `@sql.AmbiguousColumn` for duplicates; SQL NULL is `Some(Null)`.
- `Command` retains `has_rows`, `affected_rows: UInt64`, `insert_id: UInt64`.
  The default `found_rows=true` means UPDATE reports matched rows; set false for
  changed-row semantics. These are not database-neutral insert/count semantics.
- For binary expressions use a binary column or `CAST(? AS BINARY)`; types follow
  server metadata. Null and embedded NUL bytes in values are preserved.
- Legacy `Pool.query` and `Pool.transaction(Array[Statement])` remain conveniences
  over the shared API, returning `QueryResult`; the latter returns the last
  statement's result. Their old row-map/Closed-error behavior is not preserved.

See [generated signatures](src/pkg.generated.mbti) and the
[independent executable consumer](../examples/mysql/src/main.mbt).

## Ownership and limits

Workers touch only copied malloc memory and Connector/C handles. Completion is
observed through a pipe; no MoonBit-managed memory crosses into foreign threads.
The application uses one async event loop and closes each database it creates.

Each lease is reset with `mysql_reset_connection` before reuse, then its configured
charset/timezone are reapplied. Temporary tables, user variables and unmanaged
transactions cannot leak between borrowers. A worker keeps its physical connection
through the whole callback, including interactive transactions. A SQL error closes
that physical connection; the failed shared session rejects further operations
and never silently reconnects inside a transaction.

Cancellation drains submitted work; it does not interrupt SQL. Timeout return
can therefore be delayed. Callback cancellation rolls back before returning the
connection. Closing rejects queued/new requests, while active leases retain their
workers until cleanup. `db.close_and_wait()` observes completion.

Defaults: 10 connections, 128 waiting requests, 5-second checkout and Connector/C
connect/read/write timeouts, 10,000 result rows and 16 MiB value payload. Payload
limits exclude metadata and allocation overhead. Allocation failure in the C stub
currently aborts. There are no automatic retries of uncertain writes.

`charset` supports utf8mb4 (default), utf8mb3 or utf8, matching the Unicode text
codec. `time_zone` defaults to `+00:00` and accepts MySQL timezone names/offsets.
`found_rows` defaults to true. These are explicit MySQL settings, not policies
in the shared SQL module. Multi-statements and LOCAL INFILE remain disabled.

Driver errors retain `InvalidConfig`, `InvalidParameter`, `ServerError(Int)`,
`CompletionLost`, `WorkerUnavailable` and `ResultTooLarge`. The shared module
supplies admission/lifetime/cleanup errors and retains underlying causes. No
HTTP status or automatic retry policy is assigned here.

Connection setup is lazy. A nonempty `ssl_ca` requires TLS and certificate
verification; otherwise Connector/C's default TLS policy applies. `plugin_dir`
configures authentication plugins. No environment variables are loaded by the
library, and local tests do not exercise TLS.
