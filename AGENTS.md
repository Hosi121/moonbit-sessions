# servicekit.mbt

Use the MoonBit practice skill for MoonBit changes. `mysql` and `postgres` depend on the shared
`sql` module, never on each other or an application. `ws_session` is independent
of all database modules. Keep examples in separate consumer modules. Do not add an umbrella
module, routing, auth, room identifiers, environment loading, or HTTP error policy
to the library API. Do not introduce `Any`, `JSValue`, or generic unchecked casts.

Never pass MoonBit-managed memory to foreign threads. Changes to worker ownership,
pool shutdown, or cancellation need the isolated MySQL integration test. WebSocket
lifecycle changes need the real protocol tests. Use `node scripts/moon.mjs`,
`npm run check`, `npm test`, `npm run test:consumer`, and `npm run test:databases`.
Database tests require explicit, disposable `SERVICEKIT_TEST_DATABASE_URL` and
`SERVICEKIT_TEST_POSTGRES_URL`. Both adapters must pass the shared conformance
suite. Async resource cleanup belongs in cancellation-protected `errdefer`;
ordinary catch does not guarantee cleanup on cancellation.

Do not claim portability, schema typing, Mooncakes publication, or performance
improvements that have not been verified. Keep version-specific upstream
workarounds outside the library when they concern caller-owned transports.
