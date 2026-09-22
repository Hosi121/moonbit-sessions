# Existing implementations and the remaining scope

Inspected on 2026-09-22. Registry versions below are the tested or inspected
versions, not a claim that any project is an official or de facto standard.

| Existing project | Decision and evidence |
| --- | --- |
| [moonbit-community/postgres 0.0.8](https://github.com/moonbit-community/postgres.mbt) | Reuse its protocol client, pool, transaction options, parameter codecs and diagnostics. `postgres_session` adds bounded admission and callback lifetime rules; no replacement pool or wire implementation. |
| [moonbitstack/moondb 0.1.8](https://github.com/moonbitstack/moonorm/tree/master/db) | Reuse `AsyncDriver`, `Value`, `Row`, `ExecResult` directly in `moondb_session`. Its `Pool` is synchronous, so it is not used for async server pooling. Its value enum has no distinct UInt64 or Decimal case; native driver codecs are not forced through it. |
| [moonbitstack/moonpostgres 0.6.0](https://github.com/moonbitstack/moonorm/tree/master/drivers/postgres) | Actual third-party AsyncDriver used by the common conformance consumer. This proves the adapter accepts an upstream implementation; it is not a replacement for the existing community-pgpool integration. |
| [moonbitstack/moonmysql 0.7.0](https://github.com/moonbitstack/moonorm/tree/master/drivers/mysql) | Its synchronous adapter reconnects per statement and cannot span a transaction; its separate async connection can. At this version it sends escaped literals through COM_QUERY rather than prepared-statement binding. Not substituted for the Connector/C worker adapter. |
| [bikallem/mariadb 0.0.1](https://github.com/bikallem/mariadb.mbt) | Existing experimental C bindings, including prepared statements. The inspected public interface is synchronous and lacks the foreign-worker ownership/pooling needed here. A possible upstream home for compatible binding improvements, not a drop-in async replacement. |
| [mizchi/sqlite](https://github.com/mizchi/sqlite.mbt) | Existing SQLite binding to use if a SQLite adapter is needed. No SQLite implementation is being started here. |
| [mizchi/sqlc_gen_moonbit 0.4.0](https://github.com/mizchi/sqlc_gen_moonbit) | Existing query/parameter/result type generation. Reuse at that layer instead of building an ORM or generator. Native PostgreSQL and SQLite exist; the listed MySQL backend is JS/mysql2. Native MySQL generation and session integration are not implemented here. |

The custom SQL module is named `sql_session` to describe the gap it fills:
scoped borrowing, bounded admission, cancellation cleanup, poisoned scopes and
unknown-commit reporting. Its generic execution hooks integrate drivers; they
do not replace moondb's value model or establish a universal SQL standard.
Separate query/execute interfaces need no fabricated metadata or replayed writes.

MySQL remains an adapter over established MariaDB Connector/C, with owned C
memory on worker threads. Passing the synchronous binding's MoonBit-managed
objects to foreign threads would not provide that ownership guarantee. Future
replacement must pass the same prepared-statement, exact-value, cancellation,
reset and shutdown tests; an API-name match is not sufficient.

## Test boundaries

`examples/conformance` runs the same lifetime scenarios against the two native
adapters and the upstream moondb PostgreSQL path. SQL syntax, error inspection,
transaction options and row decoding are injected per driver. The moondb path
preserves its upstream duplicate-column lookup instead of pretending it gained
our native adapters' ambiguity error. The source opens/closes per scope; this
checks ownership and admission, not connection-reuse performance.

The comparisons of moonmysql, bikallem/mariadb, SQLite and sqlc are source/API
assessments, not integration-test results. No performance comparison or author
endorsement is implied. We have not contacted upstream maintainers or opened PRs.
