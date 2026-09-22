# servicekit.mbt

Small native MoonBit infrastructure modules extracted from
[SpeakUp-moonbit](https://github.com/Hosi121/SpeakUp-moonbit). Each module can be
used independently. There is no umbrella `hosi121/servicekit` dependency.

| Module | Responsibility | Runtime dependencies |
| --- | --- | --- |
| [`hosi121/mysql`](mysql) | Typed prepared statements, worker pool, batch transactions, cancellation-safe reclamation | `moonbitlang/async@0.22.1`, MariaDB Connector/C, pthread |
| [`hosi121/ws_session`](ws_session) | Scoped text sender, bounded pending messages, heartbeat, final-message ordering | `moonbitlang/async@0.22.1` |

Experimental; verified on Linux x86_64, MoonBit **0.10.14+7d59c7ec9** / moon
**0.1.20260920**. MySQL integration is tested against MySQL **8.4**. Other OSes,
JS/Wasm targets, and other database servers are not covered. There are no
JavaScript runtime dependencies and no `Any` or unchecked generic casts in these
modules. Node is used only for development scripts and protocol tests.

## Use one module

This is source distribution, **not yet a Mooncakes or npm release**. In your
application repository:

```sh
git submodule add https://github.com/Hosi121/servicekit.mbt vendor/servicekit
# Commit .gitmodules and the submodule entry to pin the exact revision.
```

For MySQL, add only its module to your workspace:

```moonbit
// moon.work
members = [".", "vendor/servicekit/mysql"]
```

Add `"hosi121/mysql@0.1.0"` to your application's `moon.mod` import block and
`"hosi121/mysql" @mysql` to its `moon.pkg`. The workspace resolves the checked-out
source; `moon add` alone cannot fetch an unpublished module. For WebSocket use
`vendor/servicekit/ws_session`, `hosi121/ws_session@0.1.0`, and
`"hosi121/ws_session" @session` instead. Neither module imports the other.

The [MySQL consumer](examples/mysql) and [WebSocket consumer](examples/websocket)
are separate MoonBit modules with no application dependency. `test:consumer`
copies each library and its consumer into a separate temporary workspace and
builds it. It also verifies that the WebSocket executable does not link MySQL.

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

The installer pins archive checksums and writes only to `.tools/moon`. An existing
matching toolchain can be selected with `MOON_HOME`. The development scripts use
Node built-ins only; no npm installation is needed. Alternatively, standard
`moon check --target native` and `moon build --target native --release` work with
the pinned toolchain and system development libraries installed.

For the database tests, use a disposable database explicitly:

```sh
docker compose -p servicekit-tests up -d --wait
SERVICEKIT_TEST_DATABASE_URL=mysql://servicekit:local-test-only@127.0.0.1:3310/servicekit_test npm run test:mysql
docker compose -p servicekit-tests down --volumes
```

The test creates and drops `servicekit_contract` in that database. It covers
64-bit integer/decimal/binary preservation, commit/rollback, parameter mismatch,
event-loop progress during blocked SQL, cancellation and connection reuse, close
with queued/in-flight work, independent pools, and result limits. `npm test`
exercises real WebSocket connections with Node's built-in client. CI runs both.
No throughput improvement is claimed by this extraction.

## Scope and ecosystem

The previous application-local `servicekit` also contained connection IDs, HTTP
body policy, JSON numeric checks, a string callback convention, and TS2Mbt/Mbt2TS
wrappers. Those were not a coherent general API. The two modules here isolate
resource lifetime and backpressure; domain state and boundary policy stay in the
application. See [the design assessment](docs/design.md) for the concrete split
and the comparison with mizchi's `x`, `sqlite.mbt`, `js.mbt`, and `ts.mbt`.

This repository is not affiliated with or endorsed by mizchi. Dependency licenses
remain with their authors. Source provenance is recorded in [NOTICE.md](NOTICE.md).
