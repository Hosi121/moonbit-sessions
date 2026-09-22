///|
fn setting(name : String) -> String raise {
  @env.get_env_var("SERVICEKIT_POSTGRES_" + name).unwrap_or_else(fn() raise {
    fail("Missing disposable PostgreSQL test configuration")
  })
}

///|
async fn main {
  let upstream = @pg.PgDriver::new(
    host=setting("HOST"),
    port=@string.parse_int(setting("PORT")),
    user=setting("USER"),
    password=setting("PASSWORD"),
    database=setting("DATABASE"),
  )
  // This conformance consumer opens one connection per scope, with bounded
  // concurrency. Production callers can supply an existing pool's callbacks.
  // It deliberately tests an upstream AsyncDriver without wrapping our own SQL
  // driver back into the moondb interface.
  let db = @sessions.database_with_options(
    acquire=async fn() {
      @async.protect_from_cancel(async fn() { upstream.connect() })
    },
    release=async fn(conn, _) { @moondb.AsyncDriver::close(conn) },
    close=fn() { () },
    begin=async fn(conn, read_only : Bool) {
      @moondb.AsyncDriver::begin(conn)
      if read_only {
        ignore(
          @moondb.AsyncDriver::execute(conn, "SET TRANSACTION READ ONLY", []),
        )
      }
    },
    max_leases=1,
    max_waiters=1,
    checkout_timeout_ms=3000,
  )
  defer @async.protect_from_cancel(async fn() { db.close_and_wait() })
  let bytes = b"\x00\xff\x01"
  let row = db.query("SELECT $1::bigint AS n, $2::bytea AS b, $3::text AS t", params=[
      @moondb.Int64(-9223372036854775808L),
      @moondb.Blob(bytes),
      @moondb.Text("日本語"),
    ])[0]
  assert_eq(row.int64_by("n"), -9223372036854775808L)
  assert_eq(row.blob_by("b"), bytes)
  assert_eq(row.text_by("t"), "日本語")
  // moondb exposes first-match name lookup; preserve that upstream contract.
  // Ambiguity-sensitive callers use positional access or explicit SQL aliases.
  @contract.run(db, {
    name: "moondb AsyncDriver / moonpostgres",
    options: false,
    read_only: true,
    insert: "INSERT INTO servicekit_shared(id, value) VALUES ($1, $2)",
    params: (id, value) => [@moondb.Int(id), @moondb.Text(value)],
    number: fn(row, name) raise { row.int64_by(name) },
    duplicate: fn(row) raise {
      assert_eq(row.int(0), 1)
      assert_eq(row.int(1), 2)
      assert_eq(row.columns, ["duplicate", "duplicate"])
    },
    constraint_error: error => {
      match error {
        @moondb.QueryError(message) => message.contains("23505")
        _ => false
      }
    },
    read_only_error: error => {
      match error {
        @moondb.QueryError(message) => message.contains("25006")
        _ => false
      }
    },
    connection_id: "SELECT pg_backend_pid()::bigint AS n",
    slow: "SELECT pg_sleep(0.2)",
    set_session: "SET application_name = 'borrower-local'",
    check_session: "SELECT CASE WHEN current_setting('application_name') = '' THEN 1::bigint ELSE 0::bigint END AS n",
  })
  println("moondb upstream conformance passed")
}
