///|
async fn main {
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM])
  let limits = @session.Limits(max_pending_bytes=4096, max_pending_messages=8)
  let active : Ref[Int] = { val: 0, }
  let retired : Ref[@session.Session?] = { val: None, }
  let port = @env.get_env_var("SERVICEKIT_PORT").unwrap_or("18083")
  let server = @http.Server(
    @socket.Addr::parse("127.0.0.1:" + port),
    reuse_addr=true,
  )
  defer server.close()
  @async.with_task_group(async fn(group) {
    for ;; {
      let (conn, _) = server.accept()
      group.spawn_bg(allow_failure=true, async fn() {
        defer conn.close()
        let request = @async.with_timeout(2000, async fn() {
          conn.read_request()
        })
        if request.path == "/health" {
          conn.send_response(
            200,
            "OK",
            extra_headers=Map([
              (@http.CaseInsensitiveString("Content-Type"), "text/plain"),
            ]),
          )
          conn.write(active.val.to_string())
          conn.end_response()
        } else if request.path == "/retired" {
          conn.send_response(200, "OK")
          let rejected = match retired.val {
            Some(session) => !session.send("late")
            None => false
          }
          conn.write(rejected.to_string())
          conn.end_response()
        } else {
          active.val += 1
          defer {
            active.val -= 1
          }
          let ws = @ws.from_http_server(request, conn)
          @session.with_session(
            ws,
            limits~,
            on_error=fn(error) {
              match error {
                TooLarge => @ws.MessageTooBig
                _ =>
                  if request.path == "/policy" {
                    @ws.PolicyViolation
                  } else {
                    @ws.InternalError
                  }
              }
            },
            async fn(peer) {
              retired.val = Some(peer)
              if request.path == "/error" || request.path == "/policy" {
                fail("example handler error")
              }
              if request.path == "/bytes" {
                assert_false(peer.send("界".repeat(1366)))
                return
              }
              if request.path == "/overflow" {
                for _ in 0..<8 {
                  assert_true(peer.send(""))
                }
                assert_false(peer.send(""))
                return
              }
              if request.path == "/finish" {
                assert_true(peer.send("before"))
                assert_true(peer.finish("goodbye"))
                assert_false(peer.send("too late"))
                return
              }
              for ;; {
                let message = ws.recv()
                let text = @utf8.decode(limited_body(message, 4096))
                if !peer.send(text) {
                  break
                }
              }
            },
          )
          drain_close(conn)
        }
      })
    }
  })
}
