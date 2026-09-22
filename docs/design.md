# Scope assessment

Status: the repository has two working native modules, not a general service
framework. The database API is MySQL-specific. It has not been validated with a
second RDBMS. An independent build proves package separation, not generality.

## What exists and what remains

| Concern | Current location | Reuse assessment |
| --- | --- | --- |
| Connector/C binding and workers | `mysql` | Reusable for MySQL on the supported runtime; intrinsically driver-specific |
| Pool checkout, cancellation cleanup, shutdown | Mixed into `mysql` | Useful common contracts, but no shared abstraction has been implemented |
| SQL parameters, rows, execution result | MySQL `Value` / `Row` / `QueryResult` | Typed, but shaped by one driver; not a portable database contract |
| Bounded text sends, heartbeat, final flush | `ws_session` | Reusable within native async WebSocket text connections; no transport-neutral sender or binary queue |
| Peer IDs, rooms, auth, HTTP ingress policy | Application | Application choices, with generic ingredients that do not need this repo's DB API |
| JSON numeric validation and JS callbacks | Application | Concrete policies remain there; this does not prove that generic codecs or callback helpers are impossible |
| TS2Mbt / Mbt2TS generation | Existing tools plus application checks | Reuse the generator; application export/ABI checks remain a consumer contract |

The initial extraction stopped at driver independence from SpeakUp. It did not
establish that database abstraction was undesirable. In particular, a common
query/transaction interface does **not** require an ORM or SQL dialect rewriting.
See [database-abstraction.md](database-abstraction.md) for the proposed boundary,
its alternatives, and the second adapter needed to validate it.

The `servicekit` repository name groups these experiments. MySQL and WebSocket
remain separate modules because one should not require the other. They do not
currently share an implemented resource-lifecycle core. A stronger umbrella API
would need a concrete consumer benefit, not merely a common origin.

## Existing ecosystem

Primary source versions inspected on 2026-09-22:

- [`mizchi/x`](https://github.com/mizchi/x/tree/d75653b21707eb2c791b2465d1613f98115b8114)
  implements async-style I/O across targets. `ws_session` currently composes
  `moonbitlang/async` directly and adds bounded sending. Compatibility with `x`
  remains untested; it is not claimed from similar names or signatures.
- [`mizchi/sqlite.mbt`](https://github.com/mizchi/sqlite.mbt/tree/2758ae427e2afd640bfe9c5a24885bdf0efaf0ad)
  exposes a synchronous native SQLite binding and typed SQL values. It is a
  candidate building block for an adapter, not evidence against a shared DB API.
- [`moonbit-community/postgres.mbt`](https://github.com/moonbit-community/postgres.mbt/tree/a0e4097af3f40444bd1e997ede672ba4adaf05ad)
  already includes async connection, pool, transaction, and cancellation APIs.
  A PostgreSQL adapter should evaluate those instead of duplicating the driver
  or wrapping one pool inside another.
- [`mizchi/sqlc_gen_moonbit`](https://github.com/mizchi/sqlc_gen_moonbit/tree/8fa8213b1b4eb33325e5c5045d330daf11eade2d)
  separates generated query types from backend-specific execution. A shared
  runtime contract can complement that model while SQL and codecs stay explicit.
- [`mizchi/js.mbt`](https://github.com/mizchi/js.mbt/blob/8c9e27de7c81ab3ebf3a9cbe75590c7349317e0c/modules/js_core/promise.mbt)
  already handles Promise/async interoperation. SpeakUp's string callback is a
  narrower convention, not a general alternative.
- [`mizchi/ts.mbt`](https://github.com/mizchi/ts.mbt/tree/e98d1b84ec1719e4be656c8738623f302a652160)
  owns bridge/package generation. SpeakUp still uses `@mizchi/ts@0.6.0`; its
  version-specific checks stay in the application. No generator update or new
  ecosystem dependency is part of this design review.

These comparisons inform the proposal; they are not compatibility tests or an
endorsement by the upstream authors. No source from those repositories was copied.
