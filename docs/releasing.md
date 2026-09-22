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

Finally verify the versions with `moon view`, build a fresh registry consumer,
and switch SpeakUp's production dependency resolution from the development
submodule to `moon.mod` registry dependencies. Remove the submodule only after
that registry build and application integration tests pass. Update the README
availability statement after the registry check, never before it.
