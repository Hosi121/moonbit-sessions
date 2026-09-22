# hosi121/postgres

Native adapter for `moonbit-community/postgres@0.0.8`, reusing its async protocol
client and `pgpool`. There is no libpq dependency, foreign worker or extra pool.
Tested with PostgreSQL 17 and the repository's pinned MoonBit toolchain.

## Install and use

Register `vendor/servicekit/sql` and `vendor/servicekit/postgres` in `moon.work`.
Your `moon.mod` imports:

```moonbit
import {
  "hosi121/sql@0.1.0",
  "hosi121/postgres@0.1.0",
  "moonbit-community/postgres@0.0.8",
  "moonbitlang/async@0.22.1",
}
```

Import `"hosi121/postgres" @postgres`,
`"moonbit-community/postgres/client" @client`, and
`"moonbit-community/postgres/pgpool" @pgpool` in the consumer package.
Inside an async function:

```moonbit
let config = @pgpool.Config::new(
  "127.0.0.1", user="app", password="password", dbname="app",
  ssl_mode=@client.SslMode::Disable, // local test only; default is VerifyFull
  application_name="example",
  pool=@pgpool.PoolConfig::new(4, recycling_method=@pgpool.RecyclingMethod::clean()),
)
@postgres.with_database(config, async fn(db) {
  let rows = db.with_transaction(@pgpool.TransactionOptions::new(), async fn(tx) {
    tx.query("INSERT INTO notes(body) VALUES ($1) RETURNING id", params=["hello"])
  })
  let id : Int = rows[0].get("id")
  println(id)
})
```

Use an `Int64` decode for a BIGINT column. `with_database` owns the background
task group, database and leases. Applications already owning a
`TaskGroup[Unit]` can call `database(config, group)` instead; the group must
outlive every scope and `close_and_wait()`.

## Types and behavior

The returned type is
`@sql.Database[&@client.ToSql, Row, @client.QuerySummary, @pgpool.TransactionOptions]`.
Trait-object parameters use upstream typed `ToSql` implementations, with checked
PostgreSQL type acceptance; they are not unchecked casts. `Row.get[T: FromSql]`
and `get_at` retain upstream decoders. Columns remain ordered, with OID/type/format
metadata. Name lookup reports duplicates instead of picking the first column.
Unsupported codecs remain explicit upstream errors; NUMERIC is not silently
converted to Double. A SQL cast to text is an explicit application choice.

Command tags and row counts are upstream `QuerySummary`, not a universal insert
ID or a widened/rounded number. PostgreSQL errors retain SQLSTATE, message and
other diagnostic fields. Isolation/read-only/deferrable options use upstream
`TransactionOptions`; server restrictions are reported as errors.

Clean recycling is required and validated. A pre-recycle ROLLBACK also cleans
up an unmanaged transaction before upstream resets settings, temporary objects,
listeners and advisory locks. The facade adds bounded admission and lifetime
checks, not another connection pool. Both transaction and query operations
currently drain on cancellation; upstream operation-cancel tokens/streaming are
not exported by this adapter.

Results default to 10,000 rows and 16 MiB value bytes, configurable with
`max_rows`/`max_bytes`. These are collected-result limits, **not a hard cap on
upstream protocol buffers, individual incoming messages, or peak process memory**.
Over-limit streams drain before the connection is discarded. Checkout defaults
to 5 seconds and 128 waiters. See the [shared SQL contract](../sql/README.md).

The new registry dependency also pulls `moonbitlang/x@0.4.41` and
`tonyfettes/unicode@0.3.0`; async remains 0.22.1. No npm dependency was added.
The [consumer](../examples/postgres/src/main.mbt) and CI exercise a real database,
exact values, RETURNING, cleanup, result limits and the shared conformance suite.
TLS/failover configurations are not integration-tested here.
