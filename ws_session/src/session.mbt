///|
pub(all) suberror InvalidLimits

///|
/// Immutable per-session limits. Counts include the message being written.
pub struct Limits {
  max_pending_bytes : Int
  max_pending_messages : Int
  write_timeout_ms : Int
  heartbeat_ms : Int
  close_timeout_ms : Int
}

///|
pub fn Limits::Limits(
  max_pending_bytes? : Int = 262144,
  max_pending_messages? : Int = 1024,
  write_timeout_ms? : Int = 30000,
  heartbeat_ms? : Int = 30000,
  close_timeout_ms? : Int = 1000,
) -> Limits raise InvalidLimits {
  guard max_pending_bytes > 0 &&
    max_pending_messages > 0 &&
    write_timeout_ms > 0 &&
    heartbeat_ms > 0 &&
    close_timeout_ms > 0 else {
    raise InvalidLimits
  }
  {
    max_pending_bytes,
    max_pending_messages,
    write_timeout_ms,
    heartbeat_ms,
    close_timeout_ms,
  }
}

///|
priv struct Message {
  payload : String
  bytes : Int
  close_code : @ws.CloseCode?
}

///|
/// A scoped, text-only sender. The application owns receiving and identity.
pub struct Session {
  priv ws : @ws.Conn
  priv output : @async.Queue[Message]
  priv limits : Limits
  priv finished : @async.Queue[Unit]
  priv mut finishing : Bool
  priv mut bytes : Int
  priv mut messages : Int
  priv mut closing : Bool
}

///|
/// Disconnect immediately. Idempotent; subsequent sends return false.
pub fn Session::close(self : Session) -> Unit {
  self.closing = true
  self.ws.close()
}

///|
fn Session::enqueue(
  self : Session,
  payload : String,
  close_code : @ws.CloseCode?,
) -> Bool {
  if self.closing {
    return false
  }
  let bytes = @utf8.encode(payload).length()
  if bytes > self.limits.max_pending_bytes - self.bytes ||
    self.messages >= self.limits.max_pending_messages {
    self.close()
    return false
  }
  self.bytes += bytes
  self.messages += 1
  let queued = self.output.try_put({ payload, bytes, close_code, }) catch {
    _ => false
  }
  if !queued {
    self.close()
  }
  if queued && close_code is Some(_) {
    self.closing = true
    self.finishing = true
  }
  queued
}

///|
/// False means closed or overloaded. Overflow disconnects the slow consumer.
/// Successful enqueue is not a delivery acknowledgement.
pub fn Session::send(self : Session, payload : String) -> Bool {
  self.enqueue(payload, None)
}

///|
/// Queue one final payload followed by the close frame. with_session waits for
/// that write even when the handler returns immediately. Further sends fail.
pub fn Session::finish(
  self : Session,
  payload : String,
  code? : @ws.CloseCode = Normal,
) -> Bool {
  self.enqueue(payload, Some(code))
}

///|
/// Owns one data writer and optional heartbeat task for the callback lifetime.
/// The caller owns the underlying connection and must close it after return.
/// Handler/write errors are passed to on_error, then its close code is sent.
/// A normal remote close is ignored. The default error code is 1011.
pub async fn with_session(
  ws : @ws.Conn,
  limits? : Limits = try! Limits(),
  heartbeat? : Bool = true,
  on_error? : (Error) -> @ws.CloseCode = _ => InternalError,
  handle : async (Session) -> Unit,
) -> Unit {
  let session = {
    ws,
    output: @async.Queue(kind=Unbounded),
    limits,
    finished: @async.Queue(kind=Unbounded),
    finishing: false,
    bytes: 0,
    messages: 0,
    closing: false,
  }
  defer {
    session.closing = true
    session.output.close(clear=true)
  }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(no_wait=true, async fn() {
      for ;; {
        let message = session.output.get()
        @async.with_timeout(limits.write_timeout_ms, async fn() {
          ws.send_text(message.payload)
        })
        session.bytes -= message.bytes
        session.messages -= 1
        if message.close_code is Some(code) {
          @async.with_timeout(limits.close_timeout_ms, async fn() {
            ws.send_close(code~)
          })
          session.finished.put(())
          @async.sleep(limits.close_timeout_ms)
          ws.close()
          break
        }
      }
    })
    if heartbeat {
      group.spawn_bg(no_wait=true, async fn() {
        for ;; {
          @async.sleep(limits.heartbeat_ms)
          @async.with_timeout(limits.write_timeout_ms, async fn() { ws.ping() })
        }
      })
    }
    handle(session)
    if session.finishing {
      @async.with_timeout(limits.write_timeout_ms, async fn() {
        session.finished.get()
      })
    }
  }) catch {
    @ws.ConnectionClosed(_, _) => ()
    error => {
      let code = on_error(error)
      @async.with_timeout(limits.close_timeout_ms, async fn() {
        ws.send_close(code~)
      }) catch {
        _ => ()
      }
    }
  }
}
