///|
fn setting(name : String) -> String raise {
  @env.get_env_var("SERVICEKIT_MYSQL_" + name).unwrap_or_else(fn() raise {
    fail("Missing example database configuration")
  })
}

///|
async fn pool(
  max_rows? : Int = 10000,
  max_bytes? : Int = 16777216,
) -> @mysql.Pool {
  @mysql.Pool::new(
    host=setting("HOST"),
    user=setting("USER"),
    password=setting("PASSWORD"),
    database=setting("DATABASE"),
    port=@string.parse_int(setting("PORT")),
    size=1,
    plugin_dir=@env.get_env_var("MYSQL_PLUGIN_DIR").unwrap_or(""),
    max_rows~,
    max_bytes~,
  )
}

///|
async fn main {
  let a = pool()
  defer a.close()
  let b = pool()
  defer b.close()
  let row = a.query(
      "SELECT ? AS signed_value, ? AS unsigned_value, CAST(? AS DECIMAL(30,10)) AS decimal_value, CAST(? AS BINARY) AS binary_value, ? AS text_value, ? AS null_value",
      params=[
        Integer(-9223372036854775808L),
        Unsigned(18446744073709551615UL),
        Decimal("12345678901234567890.1234567890"),
        Blob(b"\x00\xff\x01"),
        Text("日本語\u0000text"),
        Null,
      ],
    ).rows[0]
  assert_eq(
    row.get("signed_value"),
    Some(@mysql.Integer(-9223372036854775808L)),
  )
  assert_eq(
    row.get("unsigned_value"),
    Some(@mysql.Unsigned(18446744073709551615UL)),
  )
  assert_eq(
    row.get("decimal_value"),
    Some(@mysql.Decimal("12345678901234567890.1234567890")),
  )
  assert_eq(row.get("binary_value"), Some(@mysql.Blob(b"\x00\xff\x01")))
  assert_eq(row.get("text_value"), Some(@mysql.Text("日本語\u0000text")))
  assert_eq(row.get("null_value"), Some(@mysql.Null))
  // This table exists only in the explicitly configured isolated test DB.
  ignore(
    a.query(
      "CREATE TABLE servicekit_contract (id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT, value VARCHAR(100) NOT NULL UNIQUE)",
    ),
  )
  let inserted = a.query("INSERT INTO servicekit_contract(value) VALUES (?)", params=[
    Text("first"),
  ])
  assert_eq(inserted.affected_rows, 1UL)
  assert_eq(inserted.insert_id, 1UL)
  let failed = try
    a.transaction([
      @mysql.statement("INSERT INTO servicekit_contract(value) VALUES (?)", params=[
        Text("rollback"),
      ]),
      @mysql.statement("INSERT INTO servicekit_contract(value) VALUES (?)", params=[
        Text("first"),
      ]),
    ])
  catch {
    @mysql.ServerError(1062) => true
    error => raise error
  } noraise {
    _ => false
  }
  assert_true(failed)
  assert_eq(
    b.query("SELECT COUNT(*) AS n FROM servicekit_contract").rows[0].get("n"),
    Some(@mysql.Integer(1L)),
  )
  let committed = a.transaction([
    @mysql.statement("INSERT INTO servicekit_contract(value) VALUES (?)", params=[
      Text("second"),
    ]),
    @mysql.statement("SELECT COUNT(*) AS n FROM servicekit_contract"),
  ])
  assert_eq(committed.rows[0].get("n"), Some(@mysql.Integer(2L)))
  assert_true(
    try a.query("SELECT ?", params=[]) catch {
      @mysql.InvalidParameter => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  let connection = a.query("SELECT CONNECTION_ID() AS id").rows[0].get("id")
  let ticks : Ref[Int] = { val: 0, }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      for ;; {
        @async.sleep(5)
        ticks.val += 1
      }
    })
    assert_eq(
      @async.with_timeout_opt(20, async fn() {
        ignore(a.query("SELECT SLEEP(0.2)"))
      }),
      None,
    )
    assert_eq(
      a.query("SELECT CONNECTION_ID() AS id").rows[0].get("id"),
      connection,
    )
  })
  assert_true(ticks.val >= 5)
  assert_eq(
    b.query("SELECT 42 AS answer").rows[0].get("answer"),
    Some(@mysql.Integer(42L)),
  )
  let limited = pool(max_rows=1)
  defer limited.close()
  let rejected = try limited.query("SELECT 1 UNION ALL SELECT 2") catch {
    @mysql.ResultTooLarge => true
    error => raise error
  } noraise {
    _ => false
  }
  assert_true(rejected)
  assert_eq(
    limited.query("SELECT 7 AS n").rows[0].get("n"),
    Some(@mysql.Integer(7L)),
  )
  let small = pool(max_bytes=2)
  defer small.close()
  assert_true(
    try small.query("SELECT 'long'") catch {
      @mysql.ResultTooLarge => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  // Close while one query runs and another waits: queued work fails, the
  // running worker drains, and a separate pool remains usable.
  let ready : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
  @async.with_task_group(async fn(group) {
    let running = group.spawn(async fn() {
      ready.put(())
      a.query("SELECT SLEEP(0.2)")
    })
    ready.get()
    let queued = group.spawn(async fn() {
      ready.put(())
      try a.query("SELECT 'must not run'") catch {
        @mysql.Closed => true
        error => raise error
      } noraise {
        _ => false
      }
    })
    ready.get()
    a.close()
    a.close()
    assert_true(queued.wait())
    ignore(running.wait())
  })
  assert_true(
    try a.query("SELECT 1") catch {
      @mysql.Closed => true
      error => raise error
    } noraise {
      _ => false
    },
  )
  ignore(b.query("DROP TABLE servicekit_contract"))
  println("servicekit MySQL contract passed")
}
