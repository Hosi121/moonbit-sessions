///|
#external
priv type Database

///|
#borrow(host, user, pass, name, ssl_ca, plugin_dir)
extern "C" fn c_db_new(
  host : Bytes,
  user : Bytes,
  pass : Bytes,
  name : Bytes,
  port : Int,
  ssl_ca : Bytes,
  plugin_dir : Bytes,
  timeout : Int,
  max_rows : Int,
  max_bytes : Int,
) -> Database = "sk_mysql_new"

///|
#borrow(db)
extern "C" fn c_db_fd(db : Database) -> Int = "sk_mysql_fd"

///|
#borrow(db)
extern "C" fn c_db_reset(
  db : Database,
  count : Int,
  transaction : Bool,
) -> Unit = "sk_mysql_reset"

///|
#borrow(db, sql)
extern "C" fn c_db_statement(
  db : Database,
  index : Int,
  sql : Bytes,
  count : Int,
) -> Unit = "sk_mysql_statement"

///|
#borrow(db, data)
extern "C" fn c_db_param(
  db : Database,
  index : Int,
  col : Int,
  kind : Int,
  data : Bytes,
  number : Double,
) -> Unit = "sk_mysql_param"

///|
#borrow(db)
extern "C" fn c_db_submit(db : Database) -> Unit = "sk_mysql_submit"

///|
#borrow(db)
extern "C" fn c_db_error(db : Database) -> Int = "sk_mysql_error"

///|
#borrow(db)
extern "C" fn c_db_rows(db : Database) -> Int = "sk_mysql_rows"

///|
#borrow(db)
extern "C" fn c_db_cols(db : Database) -> Int = "sk_mysql_cols"

///|
#borrow(db)
extern "C" fn c_db_kind(db : Database, col : Int) -> Int = "sk_mysql_kind"

///|
#borrow(db)
extern "C" fn c_db_null(db : Database, row : Int, col : Int) -> Bool = "sk_mysql_null"

///|
#borrow(db)
extern "C" fn c_db_name(db : Database, col : Int) -> Bytes = "sk_mysql_name"

///|
#borrow(db)
extern "C" fn c_db_cell(db : Database, row : Int, col : Int) -> Bytes = "sk_mysql_cell"

///|
#borrow(db)
extern "C" fn c_db_affected(db : Database) -> UInt64 = "sk_mysql_affected"

///|
#borrow(db)
extern "C" fn c_db_insert_id(db : Database) -> UInt64 = "sk_mysql_insert_id"

///|
#borrow(db)
extern "C" fn c_db_close(db : Database) -> Unit = "sk_mysql_close"

///|
#borrow(db)
extern "C" fn c_db_integer(
  db : Database,
  index : Int,
  col : Int,
  number : Int64,
) -> Unit = "sk_mysql_integer"

///|
#borrow(db)
extern "C" fn c_db_unsigned(
  db : Database,
  index : Int,
  col : Int,
  number : UInt64,
) -> Unit = "sk_mysql_unsigned"
