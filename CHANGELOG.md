# Changes

## 2026-09-22 — First Mooncakes releases

All five modules below are published on Mooncakes. Their source revision is
[`9d53860`](https://github.com/Hosi121/moonbit-sessions/commit/9d53860268561d320b70927f5b46b9a9214a69cc).
Registry checksums match the verified distribution archives. Four fresh registry
consumers compile successfully, and SpeakUp's native database integration and
browser call tests pass with the published modules.

- Rename the source repository from `servicekit.mbt` to `moonbit-sessions`.
- Use the publisher namespace `Hosi121` and license each module under Apache-2.0.
- Narrow the generic module to `Hosi121/sql_session@0.1.0` and name the existing
  upstream PostgreSQL adapter `Hosi121/postgres_session@0.1.0`.
- Add `Hosi121/moondb_session@0.1.0`, preserving upstream AsyncDriver and value
  types. Verify the shared lifetime suite against moonpostgres/PostgreSQL 17.
- Add separate query/execute dispatch. Combined `run` is an explicit optional
  capability; a separate executor raises `CombinedResultUnavailable`.
- Retire a connection when cancellation-protected acquisition returns after
  its deadline or caller cancellation. Ownership transfers only after the
  enclosing timeout scope succeeds; the admission permit is restored on failure.
- Update the MySQL adapter to `Hosi121/mysql@0.3.0` for the new module path and
  executor interface. Its C worker/protocol semantics are unchanged.
- Package `Hosi121/ws_session@0.1.0` independently of all database modules.
- Check the actual distribution archives and build four consumers from them.

Earlier lowercase `hosi121/sql`, `hosi121/mysql`, `hosi121/postgres`, and
`hosi121/ws_session` module paths were source-only and not registered releases.
Update `moon.mod`/`moon.pkg` imports together; no compatibility registry packages
are published for those unpublished names.
