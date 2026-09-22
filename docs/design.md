# Scope assessment

Status: five native modules with an experimental SQL contract validated on
MySQL and PostgreSQL. This is not an application framework or SQL translator.

## Reuse boundaries

| Concern | Location | Evidence / limit |
| --- | --- | --- |
| Session lifetime, interactive transactions, admission and cleanup | `sql_session` | One implementation and conformance suite used by two real RDBMS adapters |
| Connector/C binding, workers, codecs and physical pool | `mysql` | MySQL-specific; consumes the common SQL contract |
| PostgreSQL integration | `postgres_session` | Reuses existing upstream client/pgpool, typed parameters and diagnostics |
| Bounded text sends, heartbeat, final flush | `ws_session` | Independently consumable; no DB dependency or application peer IDs |
| Rooms, auth, HTTP ingress policy, JSON DTO conversion | Application | Application rules, not required by the reusable modules |
| TS2Mbt / Mbt2TS and JS ABI checks | Existing tools and application | Database handles are not exported to JS; no duplicate generator |

`mysql` and `postgres_session` depend on `sql_session`, never on one another. `ws_session` does
not import any database module. There is no all-in-one umbrella module. Modules are independently packaged for Mooncakes from one repository. A Git
submodule is an optional source-development workflow. See [release verification](releasing.md).

See [database-abstraction.md](database-abstraction.md) for implemented behavior,
real-DB evidence, and remaining SQLite/sqlc work.

## Existing ecosystem

Primary source versions inspected on 2026-09-22:

- [`mizchi/x`](https://github.com/mizchi/x/tree/d75653b21707eb2c791b2465d1613f98115b8114)
  implements async-style I/O across targets. `ws_session` currently composes
  `moonbitlang/async` directly and adds bounded sending. Compatibility with `x`
  remains untested; it is not claimed from similar names or signatures.
- [`mizchi/sqlite.mbt`](https://github.com/mizchi/sqlite.mbt/tree/2758ae427e2afd640bfe9c5a24885bdf0efaf0ad)
  exposes a synchronous native SQLite binding and typed SQL values. It is a
  candidate building block for an adapter, not evidence against a shared DB API.
- [`moonbit-community/postgres.mbt`](https://github.com/moonbit-community/postgres.mbt/tree/a0e4097af3f40444bd1e997ede672ba4adaf05ad)
  already includes async connection, pool, transaction, and cancellation APIs.
  The adapter now consumes the registry release 0.0.8 and its existing pool.
- [`mizchi/sqlc_gen_moonbit`](https://github.com/mizchi/sqlc_gen_moonbit/tree/8fa8213b1b4eb33325e5c5045d330daf11eade2d)
  separates generated query types from backend-specific execution. A shared
  runtime contract can complement that model while SQL and codecs stay explicit.
- [`mizchi/js.mbt`](https://github.com/mizchi/js.mbt/blob/8c9e27de7c81ab3ebf3a9cbe75590c7349317e0c/modules/js_core/promise.mbt)
  already handles Promise/async interoperation. SpeakUp's string callback is a
  narrower convention, not a general alternative.
- [`mizchi/ts.mbt`](https://github.com/mizchi/ts.mbt/tree/e98d1b84ec1719e4be656c8738623f302a652160)
  owns bridge/package generation. SpeakUp still uses `@mizchi/ts@0.6.0`; its
  version-specific checks stay in the application. No generator version update
  was needed for the SQL abstraction.

The common PostgreSQL package and `moonbitstack/moondb` are integrated registry
dependencies, with a third-party `moonpostgres` consumer in the test suite.
See [the updated ecosystem comparison](ecosystem.md) for the decisions and
version-specific limits. Other comparisons do not establish compatibility or
author endorsement. No upstream implementation is copied into this repository.
