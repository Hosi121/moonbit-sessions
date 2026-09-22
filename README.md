# servicekit.mbt

Experimental database and WebSocket utilities for native MoonBit. The current
implementation provides a **MySQL-specific driver/pool** and a **text WebSocket
session helper**. It does not yet provide a database-independent API.

| Available module | Use it for | Runtime requirements |
| --- | --- | --- |
| [`hosi121/mysql`](mysql) | Prepared queries and batch transactions without blocking the MoonBit event loop on Connector/C | `moonbitlang/async@0.22.1`, MariaDB Connector/C, pthread |
| [`hosi121/ws_session`](ws_session) | Limit pending sends and manage heartbeat and final-message ordering on an existing WebSocket connection | `moonbitlang/async@0.22.1` |

The modules can be imported separately. Tested environments are Linux x86_64,
MoonBit **0.10.14+7d59c7ec9** / moon **0.1.20260920**, and MySQL **8.4**.
Other databases and JS/Wasm implementations are not available in this repository.
Node is used for development scripts and protocol tests, not the native runtime.

## MySQL example

In an async function, with `"hosi121/mysql" @mysql` imported:

```moonbit
let db = @mysql.Pool::new(
  host="127.0.0.1", user="app", password="password", database="app", size=4,
)
defer db.close()
let result = db.query("SELECT name FROM users WHERE id=?", params=[Integer(42L)])
for row in result.rows {
  if row.get("name") is Some(Text(name)) { println(name) }
}
```

See the [MySQL API and limitations](mysql/README.md), including exact numeric
values, batch-only transactions, and cancellation that drains rather than
interrupts submitted SQL. The [WebSocket guide](ws_session/README.md) describes
its separate API and the caller's ownership of the underlying connection.

## Add to a project

This is source distribution; neither module is registered on Mooncakes or npm.
Check out a revision in your application and register the modules you use in its
Moon workspace:

```sh
git submodule add https://github.com/Hosi121/servicekit.mbt vendor/servicekit
# Commit .gitmodules and the submodule entry to pin the revision.
```

```moonbit
// application's moon.work
members = [".", "vendor/servicekit/mysql"]
```

Add `"hosi121/mysql@0.1.0"` to the application's `moon.mod` import block and
`"hosi121/mysql" @mysql` to its `moon.pkg`. The workspace resolves the checked-out
source; `moon add` alone cannot fetch it. For WebSocket, select
`vendor/servicekit/ws_session`, `hosi121/ws_session@0.1.0`, and
`"hosi121/ws_session" @session` instead. Neither module imports the other.

The MySQL **consumer executable** also needs:

```moonbit
options(link: { "native": { "cc-link-flags": "-lmariadb -lpthread" } })
```

Submodules pin source versions; they do not make an API database-independent.
The current standalone consumers demonstrate build independence only. The
[database abstraction assessment](docs/database-abstraction.md) describes the
missing shared layer and the proposed PostgreSQL adapter used to validate it.
That design is **not implemented or released**.

## Develop and verify

On Ubuntu 24.04 x86_64, with Node 24.13+ and a C compiler:

```sh
sudo apt-get install build-essential libmariadb-dev libssl-dev
bash scripts/install-moon.sh
npm run moon -- update
npm run check
npm test
npm run test:consumer
```

The checksum-pinned installer writes to `.tools/moon`. An existing matching
installation can be selected with `MOON_HOME`. The development scripts use only
Node built-ins; no npm install is needed. With the toolchain and system headers
installed, standard `moon check --target native` / `moon build --target native
--release` also work.

`test:consumer` builds each module and its example outside this repository and
checks that the WebSocket executable does not link MySQL. `npm test` exercises
real WebSocket connections. For database tests, explicitly select a disposable DB:

```sh
docker compose -p servicekit-tests up -d --wait
SERVICEKIT_TEST_DATABASE_URL=mysql://servicekit:local-test-only@127.0.0.1:3310/servicekit_test npm run test:mysql
docker compose -p servicekit-tests down --volumes
```

The database test creates and drops `servicekit_contract`. It covers numeric and
binary preservation, commit/rollback, cancellation and reuse, event-loop progress,
pool shutdown, and result limits. These tests validate the current MySQL adapter;
they are not evidence of cross-database compatibility or a performance advantage.

## Design and origin

Read the [scope assessment](docs/design.md) and
[database design proposal](docs/database-abstraction.md) for reuse boundaries,
existing MoonBit database libraries, and the remaining work. Source provenance is
in [NOTICE.md](NOTICE.md). The implementation originated in SpeakUp-moonbit;
application code, schema, and authentication are not dependencies of these modules.
