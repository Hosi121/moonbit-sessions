# Source development

Normal library consumption uses independently versioned Mooncakes modules.
Use a Git checkout/workspace only when editing library source or
testing an unpublished revision.

```sh
git clone https://github.com/Hosi121/moonbit-sessions
cd moonbit-sessions
sudo apt-get install build-essential libmariadb-dev libssl-dev unzip
bash scripts/install-moon.sh
npm run moon -- update
npm run check
npm test
npm run test:consumer
npm run test:packages
```

`npm run test:registry` separately checks the published versions declared by the
examples. It copies only consumer/conformance code into fresh workspaces and
resolves all library modules from Mooncakes. Use `test:consumer` and
`test:packages` above when checking an unpublished source revision.

Node 24.13+ runs scripts with built-in modules. The checksum-pinned MoonBit
installation lives in `.tools/moon`; no npm install is required in this repo.

To test an unpublished MySQL module in another project:

```sh
git submodule add https://github.com/Hosi121/moonbit-sessions vendor/sessions
```

```moonbit
// consumer moon.work
members = [".", "vendor/sessions/sql_session", "vendor/sessions/mysql"]
```

Declare `Hosi121/mysql@0.3.0` and any directly imported `Hosi121/sql_session@0.1.0`
in `moon.mod`. PostgreSQL consumers select `postgres_session`, moondb consumers
select `moondb_session`, and WebSocket consumers need only `ws_session`.
Commit the submodule revision when using this development arrangement.

## Real database tests

The commands below only target disposable test containers. They create/drop
`servicekit_contract`, `servicekit_shared` and temporary tables.

```sh
docker compose -p sessions-conformance up -d --wait
export SERVICEKIT_TEST_DATABASE_URL=mysql://servicekit:local-test-only@127.0.0.1:3310/servicekit_test
export SERVICEKIT_TEST_POSTGRES_URL=postgres://servicekit:local-test-only@127.0.0.1:5433/servicekit_test
npm run test:databases
docker compose -p sessions-conformance down --volumes
```

The two PostgreSQL paths run sequentially because they intentionally use the same
conformance table. Never point these tests at application databases.
