///|
fn setting(name : String) -> String raise {
  @env.get_env_var("SERVICEKIT_POSTGRES_" + name).unwrap_or_else(fn() raise {
    fail("Missing PostgreSQL test configuration")
  })
}

///|
fn config() -> @pgpool.Config raise {
  @pgpool.Config::new(
    setting("HOST"),
    port=@string.parse_int(setting("PORT")),
    user=setting("USER"),
    password=setting("PASSWORD"),
    dbname=setting("DATABASE"),
    ssl_mode=@client.SslMode::Disable,
    application_name="servicekit-conformance",
    pool=@pgpool.PoolConfig::new(
      1,
      recycling_method=@pgpool.RecyclingMethod::clean(),
    ),
  )
}

///|
async fn main {
  @postgres.with_database(
    config(),
    async fn(db) {
      println("PostgreSQL: exact values")
      let row = db.query(
          "SELECT $1::bigint AS signed_value, $2::bytea AS binary_value, $3::text AS text_value, $4::bigint AS null_value",
          params=[
            -9223372036854775808L,
            b"\x00\xff\x01",
            "日本語",
            (None : Int64?),
          ],
        )[0]
      assert_eq((row.get("signed_value") : Int64), -9223372036854775808L)
      assert_eq((row.get("binary_value") : Bytes), b"\x00\xff\x01")
      assert_eq((row.get("text_value") : String), "日本語")
      assert_eq((row.get("null_value") : Int64?), None)
      // PostgreSQL NUMERIC remains PostgreSQL's codec. No invented Double mapping.
      let decimal = db.query(
          "SELECT 12345678901234567890.1234567890::numeric(30,10)::text AS exact_value",
        )[0]
      assert_eq(
        (decimal.get("exact_value") : String),
        "12345678901234567890.1234567890",
      )
      db.with_session(async fn(session) {
        ignore(
          session.execute(
            "CREATE TEMPORARY TABLE servicekit_returning (id INTEGER)",
          ),
        )
        let result = session.run(
          "INSERT INTO servicekit_returning VALUES ($1) RETURNING id",
          params=[42],
        )
        assert_eq((result.rows[0].get("id") : Int), 42)
        assert_eq(result.metadata.command_tag, "INSERT 0 1")
        assert_eq(result.metadata.row_count, 1)
      })
      // Even raw SQL that leaves a transaction open is rolled back on recycle.
      db.with_session(async fn(session) {
        ignore(session.execute("BEGIN"))
        ignore(session.execute("SET application_name = 'uncommitted-setting'"))
      })
      assert_eq(
        (db.query("SHOW application_name")[0].get("application_name") : String),
        "servicekit-conformance",
      )
      @contract.run(db, {
        name: "PostgreSQL",
        options: @pgpool.TransactionOptions::new(
          isolation_level=@pgpool.IsolationLevel::read_committed(),
        ),
        read_only: @pgpool.TransactionOptions::new(read_only=true),
        insert: "INSERT INTO servicekit_shared(id, value) VALUES ($1, $2)",
        params: (id, value) => [id, value],
        number: fn(row, name) raise { row.get(name) },
        duplicate: fn(row) raise {
          assert_eq((row.get_at(0) : Int), 1)
          assert_eq((row.get_at(1) : Int), 2)
          assert_true(
            try {
              let _ : Int = row.get("duplicate")
              false
            } catch {
              @sql.AmbiguousColumn("duplicate") => true
              error => raise error
            },
          )
        },
        constraint_error: error => {
          match error {
            @client.ClientError::Database(detail) =>
              detail.code == Some("23505")
            _ => false
          }
        },
        read_only_error: error => {
          match error {
            @client.ClientError::Database(detail) =>
              detail.code == Some("25006")
            _ => false
          }
        },
        connection_id: "SELECT pg_backend_pid()::bigint AS n",
        slow: "SELECT pg_sleep(0.2)",
        set_session: "SET application_name = 'borrower-local'",
        check_session: "SELECT CASE WHEN current_setting('application_name') = 'servicekit-conformance' THEN 1::bigint ELSE 0::bigint END AS n",
      })
    },
    max_waiters=1,
    checkout_timeout_ms=3000,
  )
  @postgres.with_database(
    config(),
    async fn(db) {
      assert_true(
        try db.query("SELECT 1 UNION ALL SELECT 2") catch {
          @postgres.ResultTooLarge => true
          error => raise error
        } noraise {
          _ => false
        },
      )
      assert_eq((db.query("SELECT 7::bigint AS n")[0].get("n") : Int64), 7L)
    },
    max_rows=1,
  )
  @postgres.with_database(
    config(),
    async fn(db) {
      assert_true(
        try db.query("SELECT 'long'::text") catch {
          @postgres.ResultTooLarge => true
          error => raise error
        } noraise {
          _ => false
        },
      )
    },
    max_bytes=2,
  )
  println("servicekit PostgreSQL contract passed")
}
