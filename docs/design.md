# Why these boundaries

The first extraction in SpeakUp-moonbit grouped everything difficult at a runtime
boundary into one `servicekit` module. Import independence alone was insufficient:
its test runner lived in the application, its WebSocket peer IDs followed the
application's hub, and its JS helper assumed an error-first string callback.

This repository separates two reusable mechanisms:

| Concern | Final owner | Reason |
| --- | --- | --- |
| Connector/C workers, SQL values, pool reclamation | `hosi121/mysql` | Applies to any native application using this driver and runtime |
| Bounded text sends, heartbeat, final flush | `hosi121/ws_session` | Applies to chat, notifications, or text RPC without room/domain types |
| Peer IDs and connection registry | SpeakUp `native_transport` | The hub's identity/lifecycle policy is not needed to send WebSocket data |
| HTTP upgrade, bounded receive, close-drain workaround | Caller adapter / executable example | Owns the transport and its ingress policy; workaround is async-version-specific |
| JSON safe-integer checks | SpeakUp `wire` | Small ingress policy; parser rounding has already happened, so this is not lossless JSON validation |
| Empty-error-string callback and concrete callback casts | SpeakUp `bridge` | A host convention, not a general JS Promise/async API |
| Strict TS2Mbt checks and public declaration selection | SpeakUp `scripts/boundaries` | Policy tied to its pinned generator, export shapes, and runtime contract tests |

Neither module depends on the other. Their manifests and generated public
interfaces are separate. A consumer can checkout the same repository yet select
only one member in `moon.work`; this is verified in separate temporary workspaces.
Examples are consumers, not packages implicitly required by an application.

## Relationship to mizchi's ecosystem

Primary sources inspected on 2026-09-22; these are scope comparisons, not API
compatibility or endorsement claims:

- [`mizchi/x`](https://github.com/mizchi/x/tree/d75653b21707eb2c791b2465d1613f98115b8114)
  provides async-style I/O across targets. Its WebSocket adapter already handles
  the native/JS connection boundary. This repository does not create another
  transport API: `ws_session` composes an actual `moonbitlang/async` connection
  and adds application-independent sending lifetime/limits. It currently targets
  native only; adopting `mizchi/x` would be a separate compatibility exercise,
  including version and connection-type differences.
- [`mizchi/sqlite.mbt`](https://github.com/mizchi/sqlite.mbt/tree/2758ae427e2afd640bfe9c5a24885bdf0efaf0ad)
  demonstrates a focused database boundary with explicit SQL values. The useful
  parallel is a database-specific API and typed parameters, not an invented
  database-neutral ORM. MySQL here additionally needs nonblocking worker ownership
  and precise unsigned/decimal values. No source was copied from that driver.
- [`mizchi/js.mbt`](https://github.com/mizchi/js.mbt/blob/8c9e27de7c81ab3ebf3a9cbe75590c7349317e0c/modules/js_core/promise.mbt)
  already provides Promise/async interoperation. SpeakUp's much narrower
  string-callback convention should not be sold as a replacement. It stays in
  the application to honor its concrete host API and no-`Any` constraint.
- [`mizchi/ts.mbt`](https://github.com/mizchi/ts.mbt/tree/e98d1b84ec1719e4be656c8738623f302a652160)
  owns TypeScript/MoonBit bridge and package generation. Its current interface is
  `mtsc bridge` / `mtsc pkg`. SpeakUp remains pinned to `@mizchi/ts@0.6.0`; its
  local strict checks are not extracted as another competing generator, and this
  refactor does not silently upgrade them.
- [`sqlc_gen_moonbit`'s MySQL JS backend](https://github.com/mizchi/sqlc_gen_moonbit/blob/8fa8213b1b4eb33325e5c5045d330daf11eade2d/lib/codegen/backend_mysql_js.mbt)
  generates access through `mysql2/promise`. It does not replace this native
  Connector/C worker pool. A future native sqlc backend could consume these SQL
  values, but none is implemented or promised here.

The resulting design follows a concrete lesson from these repositories: keep
platform bindings, runtime mechanisms, code generation, and application policy
at distinct boundaries. It does not require adding every related library as a
dependency. Both modules depend only on the already-used `moonbitlang/async`;
Connector/C and pthread are required only for MySQL.

## Known limits

The MySQL result API uses named columns (duplicate aliases overwrite), materializes
results within configured limits, and offers batch rather than interactive
transactions. It cancels waiting tasks without pretending to interrupt SQL.
The WebSocket module only queues text; binary streaming and cross-target support
are separate needs. The HTTP drain workaround is exercised by the example but
is not embedded in the session API. No framework, generic resource-pool API,
universal FFI abstraction, or performance claim is added without a second actual
use that justifies it.
