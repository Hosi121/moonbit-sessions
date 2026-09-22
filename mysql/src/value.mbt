///|
pub(all) suberror DatabaseError {
  InvalidConfig(String)
  InvalidParameter
  ServerError(Int)
  CompletionLost
  WorkerUnavailable
  ResultTooLarge
} derive(Debug)

///|
/// Integers, decimals and binary data never round-trip through Double/JSON.
pub(all) enum Value {
  Null
  Text(String)
  Integer(Int64)
  Unsigned(UInt64)
  Float(Double)
  Decimal(String)
  Blob(Bytes)
} derive(Eq, Debug)

///|
pub(all) struct Statement {
  sql : String
  params : Array[Value]
}

///|
pub fn statement(sql : String, params? : Array[Value] = []) -> Statement {
  { sql, params, }
}

///|
pub struct Row {
  columns : Array[String]
  values : Array[Value]
}

///|
pub fn Row::get(self : Row, name : String) -> Value? raise {
  let index = @sql.column_index(self.columns, name) catch {
    @sql.ColumnNotFound(_) => return None
    error => raise error
  }
  Some(self.values[index])
}

///|
pub fn Row::get_at(self : Row, index : Int) -> Value? {
  self.values.get(index)
}

///|
pub struct Command {
  has_rows : Bool
  affected_rows : UInt64
  insert_id : UInt64
}

///|
pub(all) enum Isolation {
  ReadUncommitted
  ReadCommitted
  RepeatableRead
  Serializable
}

///|
pub(all) struct TransactionOptions {
  isolation : Isolation?
  read_only : Bool?
}

///|
pub fn TransactionOptions::new(
  isolation? : Isolation,
  read_only? : Bool,
) -> TransactionOptions {
  { isolation, read_only, }
}

///|
pub struct QueryResult {
  rows : Array[Row]
  has_rows : Bool
  affected_rows : UInt64
  insert_id : UInt64
}

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend Value with @debug.Debug::{to_repr}

///|
pub extend DatabaseError with @debug.Debug::{to_repr}
