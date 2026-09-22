///|
priv suberror TooLarge

///|
priv suberror InvalidLimits

///|
async fn limited_body(reader : &@io.Reader, limit : Int) -> Bytes {
  guard limit >= 0 else { raise InvalidLimits }
  let data = @buffer.Buffer()
  while reader.read_some(max_len=8192) is Some(chunk) {
    guard chunk.length() <= limit - data.length() else { raise TooLarge }
    data.write_bytes(chunk)
  }
  data.to_bytes()
}

///|
/// async 0.22.1 stops its WebSocket reader after send_close. After every reader
/// and writer task has stopped, drain the remaining close reply to avoid RST.
async fn drain_close(conn : @http.ServerConnection) -> Unit {
  defer conn.close()
  ignore(
    @async.with_timeout_opt(250, async fn() {
      let mut total = 0
      while conn.read_some(max_len=4096) is Some(bytes) {
        total += bytes.length()
        if total >= 65536 {
          break
        }
      }
    }) catch {
      _ => None
    },
  )
}
