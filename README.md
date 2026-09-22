# servicekit.mbt

Experimental, typed SQL sessions and WebSocket utilities for native MoonBit.
MySQL and PostgreSQL share **session lifetime, transaction callbacks, admission,
and cleanup rules**. SQL dialects, parameter codecs and command metadata remain
specific to each driver. No application schema or JavaScript runtime is required.

| Module | Responsibility | Dependencies |
| --- | --- | --- |
| [`hosi121/sql@0.1.0`](sql) | Scoped sessions, interactive transactions, bounded admission, shutdown | `moonbitlang/async@0.22.1` |
| [`hosi121/mysql@0.2.0`](mysql) | MySQL typed values, Connector/C workers and physical pool | `sql`, async, MariaDB Connector/C, pthread |
| [`hosi121/postgres@0.1.0`](postgres) | Adapter over the existing PostgreSQL client and pool | `sql`, async, `moonbit-community/postgres@0.0.8` |
| [`hosi121/ws_session@0.1.0`](ws_session) | Bounded text sends, heartbeat and final-message ordering | async; independent of SQL and both drivers |

Tested: Linux x86_64, MoonBit **0.10.14+7d59c7ec9** / moon **0.1.20260920**,
MySQL **8.4** and PostgreSQL **17**. These modules are native-only. Node runs
build/test scripts; it is not part of the native runtime.

## Use the common SQL API

Inside an async function with `"hosi121/mysql" @mysql` imported:

```moonbit
let pool = @mysql.Pool::new(
  host="127.0.0.1", user="app", password="password", database="app", size=4,
)
let db = pool.database()
defer db.close()
let name = db.with_transaction(@mysql.TransactionOptions::new(), async fn(tx) {
  let rows = tx.query("SELECT name FROM users WHERE id=?", params=[Integer(42L)])
  if rows.is_empty() { return None }
  ignore(tx.execute("UPDATE users SET visits=visits+1 WHERE id=?", params=[Integer(42L)]))
  rows[0].get("name")
})
ignore(name)
```

`query` returns rows, `execute` returns backend command metadata, and `run`
returns both. `with_session` and `with_transaction` pin one connection and reject
use of the session after the callback. The transaction callback commits on
success and rolls back on error or cancellation. Cleanup runs through `errdefer`.
There is no automatic write retry. See the [SQL contract](sql/README.md),
[MySQL guide](mysql/README.md), and [PostgreSQL guide](postgres/README.md).

The type is `Database[P, R, M, O]`: parameters, rows, command metadata and
transaction options stay typed. A PostgreSQL `RETURNING` result is not converted
into a MySQL insert ID. Both row adapters preserve column order and reject
ambiguous name lookup. No `Any`, `JSValue`, or unchecked generic cast is used.

This is not an ORM or SQL translator. Switching a driver does not migrate an
application's queries/schema. SQLite and sqlc integration remain future work.
The [design and limits](docs/database-abstraction.md) distinguish the implemented
contract from those additional layers. No performance improvement is claimed.

## Add to a project

Source distribution uses Git revisions; these modules are **not registered on
Mooncakes or npm**. Add a submodule and commit its pinned revision:

```sh
git submodule add https://github.com/Hosi121/servicekit.mbt vendor/servicekit
```

For MySQL, register the driver and the shared SQL module:

```moonbit
// application's moon.work
members = [".", "vendor/servicekit/sql", "vendor/servicekit/mysql"]
```

Add `"hosi121/sql@0.1.0"` and `"hosi121/mysql@0.2.0"` to your `moon.mod`
import block, and the packages you use to `moon.pkg`. The workspace resolves
these local modules; `moon add` alone cannot fetch them. The **consumer
executable** needs:

```moonbit
options(link: { "native": { "cc-link-flags": "-lmariadb -lpthread" } })
```

For PostgreSQL, choose `vendor/servicekit/postgres` instead of `mysql` and follow
its [dependency/import example](postgres/README.md). It does not link MariaDB.
WebSocket consumers need only `vendor/servicekit/ws_session` and
`hosi121/ws_session@0.1.0`; neither SQL nor a DB driver is required.

## Develop and verify

On Ubuntu 24.04 x86_64 with Node 24.13+:

```sh
sudo apt-get install build-essential libmariadb-dev libssl-dev
bash scripts/install-moon.sh
npm run moon -- update
npm run check
npm test
npm run test:consumer
```

The checksum-pinned installer writes to `.tools/moon`; `MOON_HOME` can select a
matching installation. Development scripts use only Node built-ins. `npm test`
runs deterministic SQL lifetime/fault tests and real WebSocket protocol tests.
`test:consumer` builds each driver plus SQL, or WebSocket alone, in a temporary
workspace and verifies PostgreSQL/WebSocket executables do not link MySQL.

The same generic conformance suite runs against both actual databases:

```sh
docker compose -p servicekit-tests up -d --wait
export SERVICEKIT_TEST_DATABASE_URL=mysql://servicekit:local-test-only@127.0.0.1:3310/servicekit_test
export SERVICEKIT_TEST_POSTGRES_URL=postgres://servicekit:local-test-only@127.0.0.1:5433/servicekit_test
npm run test:databases
docker compose -p servicekit-tests down --volumes
```

Use disposable databases: tests create/drop `servicekit_contract`,
`servicekit_shared` and temporary tables. Shared tests cover pinning, interactive
commit/rollback, constraint failure, cancellation during SQL and callback code,
wait cancellation/timeout, saturation, expired sessions, concurrent operations,
session/temporary-table cleanup, and closing with active leases. Driver tests add
exact integer/binary values, result limits, MySQL insert IDs and PostgreSQL
`RETURNING`. Fault injection covers lost commit responses and failed cleanup.
TLS and production failover are not exercised by these local tests.

## Design and origin

Read the [reuse boundaries](docs/design.md) and [database design](docs/database-abstraction.md).
Source provenance is in [NOTICE.md](NOTICE.md). The initial MySQL/WebSocket code
came from SpeakUp-moonbit. The shared SQL module and the conformance suite do not
import SpeakUp or either database driver. Existing PostgreSQL transport/pooling
comes from the upstream package, rather than a new protocol implementation.
