# hosi121/ws_session

Scoped **text** WebSocket sending for native `moonbitlang/async@0.22.1` connections.
The module adds bounded pending messages, one data writer, optional heartbeat,
and final-payload/close-frame ordering. It does not implement a WebSocket parser,
HTTP upgrade, receive protocol, registry, identity, authentication, or room model.

Use `"hosi121/ws_session@0.1.0"` in `moon.mod` and
`"hosi121/ws_session" @session` in `moon.pkg`. Register this directory in the
workspace as described in the [repository README](../README.md). It is not yet
on Mooncakes. No MySQL headers, library, or module dependency is needed.

After upgrading with `moonbitlang/async/websocket`:

```moonbit
let limits = @session.Limits(max_pending_bytes=65536, max_pending_messages=128)
@session.with_session(ws, limits~, async fn(session) {
  ignore(session.finish("goodbye"))
})
```

The caller owns the underlying transport and must close it after return (for an
HTTP server, `defer conn.close()`). See the [runnable server](../examples/websocket)
for receiving, ingress size policy, and the async 0.22.1 HTTP close-drain workaround.
Those caller-owned concerns are intentionally outside this module.

## Contract

- `send(text)` enqueues without waiting. `true` is acceptance, not an acknowledgement
  from the remote peer. Both queued and in-flight data count toward the limit.
- `finish(text, code=Normal)` queues one final payload after earlier messages,
  then sends the close frame. No later sends are accepted. The scope waits for
  that write even when the handler returns immediately.
- Ordinary queued `send` calls are scoped to the handler lifetime; pending data
  can be discarded on return. Use `finish` when final delivery ordering matters.
- `close()` disconnects immediately. Exceeding either pending-byte or pending-message
  limits does the same and returns `false`; clients may observe abnormal close
  1006. Empty payloads count as messages. Byte counts use UTF-8 encoding.
- The callback scope owns the writer and heartbeat tasks. After the scope exits,
  even an escaped `Session` rejects sends. Use a session on the same event loop.
- The caller receives through the original `@ws.Conn`. Handler/write errors are
  reported to `on_error`, whose returned close code is sent; default is 1011.
  Normal remote closure is ignored. Supply error observation and application
  policy in `on_error`. It does not raise the handled error back to the caller.

`Limits(...)` validates positive values. Defaults are 256 KiB pending bytes,
1,024 pending messages, 30-second write timeout, 30-second heartbeat, and 1-second
close timeout. `heartbeat=false` disables pings. Timeouts bound network writes
and final flush; they are not per-application idle deadlines. Incoming message
size, number of open connections, and application rate limits remain caller policy.

The [generated interface](src/pkg.generated.mbti) lists the complete API. Real
protocol tests cover Unicode, byte/count overflow, independent sessions, close
code policy, cleanup, and queued-data → final-payload → close ordering. Current
tests run on Linux x86_64; no JS/Wasm implementation or portability claim is made.
