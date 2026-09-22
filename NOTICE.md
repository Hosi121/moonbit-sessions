# Provenance

The native MySQL worker/pool and WebSocket lifecycle code were written during the
independent MoonBit implementation in Hosi121/SpeakUp-moonbit, extracted from
revision `bfab6d95db6973c9e121cbc426271845a26f645a`, and restructured here.
No original SpeakUp team's React assets, Go application code, schema, domain
model, or oracle fixtures are included. No code from mizchi's repositories was
copied; links in docs/design.md record the API/design comparison.

`moonbitlang/async`, MariaDB Connector/C, `moonbitstack/moondb`, `moonbit-community/postgres`, and its
transitive dependencies `moonbitlang/x` and `tonyfettes/unicode` have their own
licenses. They are not vendored or relicensed by this repository. Development
toolchains downloaded into `.tools` are also excluded from distribution.

The conformance-only consumer also imports `moonbitstack/moonpostgres` and its
dependencies. Those test dependencies are not shipped inside any module archive.
Original source in this repository is licensed under Apache-2.0, as selected by
the project owner. Each distributable module includes its LICENSE and NOTICE.
