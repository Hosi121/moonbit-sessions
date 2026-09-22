# moonbit-sessions

Scoped SQL transactions and WebSocket sessions for native MoonBit.

This repository adds lifetime management to existing I/O libraries: bounded
admission, one connection per callback, rollback on failure/cancellation, and
cleanup before reuse. PostgreSQL uses `moonbit-community/postgres` and its pool.
The moondb adapter accepts existing `AsyncDriver` implementations without
converting their `Value`, `Row`, or `ExecResult` types. MySQL uses MariaDB
Connector/C on foreign workers; no MySQL wire protocol is implemented here.

## Modules

| Mooncakes module | Responsibility | Upstream |
| --- | --- | --- |
| `Hosi121/sql_session@0.1.0` | Callback lifetimes, transaction ownership, admission, cleanup | `moonbitlang/async` |
| `Hosi121/moondb_session@0.1.0` | Lifetime adapter for an existing AsyncDriver and connection source | `moonbitstack/moondb@0.1.8` |
| `Hosi121/postgres_session@0.1.0` | Lifetime adapter retaining PostgreSQL codecs and diagnostics | `moonbit-community/postgres@0.0.8` client and pool |
| `Hosi121/mysql@0.3.0` | Typed prepared statements, native workers and physical pool | MariaDB Connector/C |
| `Hosi121/ws_session@0.1.0` | Bounded text sending, heartbeat and final-message ordering | `moonbitlang/async` WebSocket |

These are independent publication units in one Git repository. WebSocket users
do not acquire SQL or database dependencies. There is no umbrella module.
All modules are experimental and currently target native MoonBit.

## Install

The versions above were published to Mooncakes on **2026-09-22** under the
`Hosi121` namespace. See the [release notes](CHANGELOG.md) for the source revision.
Install the module needed by your native MoonBit project:

```sh
moon update
moon add Hosi121/postgres_session
# Or: moon add Hosi121/mysql
# Or: moon add Hosi121/moondb_session
# Or: moon add Hosi121/ws_session
```

Ordinary registry consumers do not need a Git submodule or a workspace entry for
this repository. Git submodules remain an option for working on both repositories
at once. See [release verification](docs/releasing.md) for package contents,
installation checks and publication order.

For MySQL, the native consumer also installs MariaDB Connector/C and links
`-lmariadb -lpthread`; see the [MySQL module](mysql/README.md).

## Use an existing driver

`moondb_session` accepts acquire/release/close callbacks from a connection source.
Its admission permits bound concurrency even when that source is not a pool.
The example below assumes these callbacks belong to the caller's pool; their
required ownership rules are in the [adapter guide](moondb_session/README.md).

```moonbit
let db = @sessions.database(acquire~, release~, close~, max_leases=4)
defer @async.protect_from_cancel(async fn() { db.close_and_wait() })
db.with_transaction((), async fn(tx) {
  let rows = tx.query("SELECT balance FROM accounts WHERE id = $1", params=[@moondb.Int(1)])
  let balance = rows[0].int64(0)
  ignore(tx.execute("UPDATE accounts SET balance = $1 WHERE id = $2",
    params=[@moondb.Int64(balance + 1L), @moondb.Int(1)]))
})
```

SQL and types retain the chosen driver's semantics. `query` and `execute` call
their upstream counterparts exactly once. `run`, which asks for rows and metadata
together, is available for the MySQL and community PostgreSQL adapters; it raises
`CombinedResultUnavailable` for the separate moondb interface. No metadata is
fabricated and statements are never replayed to obtain it.

For direct community PostgreSQL integration, `@postgres.with_database` owns the
upstream task group and pool; see its [complete example](postgres_session/README.md).
For query-specific record types, evaluate the existing
[sqlc generator](https://github.com/mizchi/sqlc_gen_moonbit). This project does not
introduce an ORM, query builder, SQL translator, schema generator, or shared
value enum. MySQL retains its native unsigned/decimal types; moondb retains its
upstream value model.

## Evidence and limits

The shared real-database lifetime suite runs against MySQL 8.4, community
PostgreSQL 17, and `moonbitstack/moonpostgres@0.6.0` through moondb. It covers
connection pinning, read/decide/write transactions, rollback, cancellation,
expired sessions, admission and shutdown. Separate tests cover unknown commit
outcomes, cleanup failures, exact values, result limits and WebSocket ordering.
`test:packages` builds isolated consumers from actual distributable archives.
`test:registry` builds four fresh consumers using the published Mooncakes modules,
without copying any library source into their workspaces. Both checks passed for
the first release; the registry checks also verify that non-MySQL consumers do
not link MariaDB.

Cancellation drains submitted operations before cleanup; it does not immediately
cancel SQL on the server. A canceled autocommit write may have succeeded, and
uncertain commits are never retried. SQL/schema portability, JS/Wasm support,
production TLS/failover testing, and performance improvements are not claimed.

Tested toolchain: MoonBit **0.10.14+7d59c7ec9**, moon **0.1.20260920**, Linux x86_64.
Node runs development scripts only. See [ecosystem choices](docs/ecosystem.md),
[lifetime contract](sql_session/README.md), and [development](docs/development.md).

## License

Apache-2.0. Each published module includes `LICENSE` and `NOTICE`.
[Source provenance](NOTICE.md) identifies the extraction from SpeakUp-moonbit;
dependencies retain their own licenses.
