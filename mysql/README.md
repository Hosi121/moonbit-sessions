# hosi121/mysql

Async MySQL access for **native MoonBit on Linux**, using one MariaDB Connector/C
worker per pool connection. No JSON, HTTP, application schema, environment loading,
or Node dependency is part of the API.

Use `"hosi121/mysql@0.1.0"` in `moon.mod` and `"hosi121/mysql" @mysql` in
`moon.pkg`, with this directory registered in your workspace as described in the
[repository README](../README.md). This module is not yet on Mooncakes.

The **consumer executable's** `moon.pkg` must specify its native link flags:

```moonbit
options(link: { "native": { "cc-link-flags": "-lmariadb -lpthread" } })
```

The pinned moon does not propagate those flags from dependency libraries. This
requirement is tested by building a consumer outside the repository. Install
MariaDB Connector/C development files and a C compiler first.

## API

Inside an `async fn`:

```moonbit
let db = @mysql.Pool::new(
  host="127.0.0.1", port=3306,
  user="app", password="password", database="app", size=4,
)
defer db.close()
let result = db.query("SELECT name FROM users WHERE id=?", params=[Integer(42L)])
for row in result.rows {
  if row.get("name") is Some(Text(name)) { println(name) }
}
```

The generated [public interface](src/pkg.generated.mbti) is the API reference.
The [executable consumer](../examples/mysql/src/main.mbt) exercises the API against
a real MySQL instance without depending on SpeakUp.

- Parameters and columns use `Value`: `Null`, `Text(String)`, `Integer(Int64)`,
  `Unsigned(UInt64)`, `Float(Double)`, `Decimal(String)`, `Blob(Bytes)`. Native
  64-bit binds preserve integer precision. Decimal parameters bind as decimal
  text. Date/time results are text; each new session uses UTC and utf8mb4.
- `QueryResult` has `rows`, `has_rows`, `affected_rows: UInt64`, and
  `insert_id: UInt64`. `Row.values` maps column names to values; duplicate names
  overwrite earlier columns, so use unique SQL aliases. This is a typed SQL-value
  boundary, not generated schema typing or an ORM.
- Result types follow server metadata. `SELECT ?` may give a string charset even
  for a binary parameter; use a binary column or `CAST(? AS BINARY)` for that
  expression. Null and binary NUL bytes are preserved.
- `transaction([statement(sql, params=...), ...])` runs on one connection,
  commits or rolls back, and returns the **last** statement's result. There is
  no interactive transaction callback. DDL implicit commits and manual session
  SQL follow MySQL semantics. A later query may use a different pooled session.
- Connector flags include `CLIENT_FOUND_ROWS`: affected rows report matched rows
  for updates. Multi-statements and LOCAL INFILE are disabled.

## Ownership and failure

Each pool owns its workers and must be closed. Use it on one async event loop.
Workers only touch copied malloc memory and Connector/C handles. Completion is
observed through a pipe; no MoonBit-managed memory crosses into foreign threads.

Cancellation drains an already submitted query before reusing its connection.
It **does not cancel SQL**, and a timeout may therefore return after the SQL
finishes. There are no automatic retries of uncertain writes. `close()` is
idempotent: new and queued requests fail, while in-flight requests reclaim their
workers when they complete. Finish the tasks using a pool before closing it in
normal scope-based use.

`DatabaseError` exposes `Closed`, `InvalidConfig(String)`, `InvalidParameter`,
`ServerError(Int)`, `CompletionLost`, `WorkerUnavailable`, and `ResultTooLarge`.
Server codes such as 1062 are not converted into HTTP status codes. Connection
setup is lazy; configuration validation does not prove connectivity. Allocation
failure inside the C stub currently aborts the process.

Defaults: 10 connections, Connector/C connect/read/write timeout 5 seconds,
10,000 result rows, and 16 MiB total value payload. `size`, `timeout_seconds`,
`max_rows`, and `max_bytes` are configurable. Payload limits exclude metadata
and allocation overhead. Waiting query count is not bounded by the pool;
applications must set their own admission limit.

An explicit `ssl_ca` enables required TLS and server certificate verification.
Without it, Connector/C's default TLS policy applies. `plugin_dir` can be supplied
for Connector/C authentication plugins. Neither option is read from environment
variables by the library. TLS configurations are not exercised by the local tests.
