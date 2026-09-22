# Module releases

License: Apache-2.0. Publisher namespace: `Hosi121`. Git repository names are
independent of registry module names; this repo has five publication units.

## Verify without credentials

```sh
npm run moon -- fmt
npm run check
npm test
npm run test:databases
npm run test:packages
```

The database tests require the explicit disposable configuration in
[development.md](development.md). `test:packages` runs the official `moon package`
command for each module. On the pinned CLI, `moon publish --dry-run` requires
login even though it does not upload; `moon package` does not.

For every ZIP, the release script checks metadata, an allowlist of paths,
LICENSE/NOTICE/README and the generated interface. It ensures MySQL includes its
C worker and excludes tools, credentials, environments, applications and build
outputs. It unpacks the archives into temporary directories, builds independent
consumers, tests the packaged lifetime layers, and checks that non-MySQL consumers
do not link MariaDB. `_build/publish/manifest.json` records paths and SHA-256 hashes.

All module documentation must describe current availability accurately. A
successful packaging check is not proof of Mooncakes publication.

## Publish

Commit the reviewed changes, then authenticate through the official CLI:

```sh
npm run moon -- login
npm run moon -- whoami
npm run release
```

Choose GitHub login and authenticate as the owner of the `Hosi121` namespace.
Do not put passwords, OAuth codes, API tokens or credential files in the repository
or release assets. The release script does not read or print them.

Publication order is `sql_session`, `moondb_session`, `postgres_session`, `mysql`,
then independent `ws_session`. Every module carries its own semantic version.
Before publishing a later revision, update changed modules' versions and dependent
minimum versions; do not overwrite an existing release. A partial publication is
not rolled back by deleting public versions: inspect registry state and publish
only the remaining modules using `moon -C <module> publish`.

After uploading all modules, the release script runs `test:registry`. This builds
four fresh consumers with only their application/conformance code in the
workspace; all library modules come from Mooncakes. It also checks that non-MySQL
consumers do not link MariaDB. Run this check independently with:

```sh
npm run test:registry
```

Verify each exact version with `moon view`, compare registry checksums with
`_build/publish/manifest.json`, and record the source revision in the release
notes. Update the README availability statement after the registry check, never
before it. Downstream applications update `moon.mod` and run their integration
tests against the published modules. SpeakUp uses this registry workflow; its
development submodule was removed after the first release passed those tests.
