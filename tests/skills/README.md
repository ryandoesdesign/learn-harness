# Aster data skill tests

Run independently of the application, with Python 3.10+ and no dependencies:

```sh
python3 -B -m unittest discover -s tests/skills -v
```

These tests exercise the self-contained readers in `skills/aster/` against
`tests/fixtures/golden-data.sqlite` (the golden JSON data in
`tests/fixtures/golden-data/`, run through the native app's importer) and small
synthetic databases built from `tests/fixtures/schema.sql` (the app's migrated
schema) by `_db.py`. They check preservation of learning evidence, graph
selection/merging, the migration gate, unsupported records, and unchanged database
bytes/mtimes, including the `-wal`/`-shm` files of a database a running app holds
open. A portability test copies the skill and the fixture database outside the
repository and invokes both output formats from an unrelated working directory,
checking that no cache or data files appear.

Both fixtures are drift-tested on the Swift side
(`macos/Packages/LHKit/Tests/LHImportTests/SkillFixtureTests.swift`). After a schema
migration or an importer change, regenerate and commit them:

```sh
LH_WRITE_FIXTURE=1 swift test --package-path macos/Packages/LHKit --filter SkillFixtureTests
```

and add the new migration identifier to `KNOWN_MIGRATIONS` in
`skills/aster/scripts/_data.py` once the readers handle it.

No real installed-user profile, provider keys, app, LLM, or network is used.
The test command is intentionally separate from the app's test suites; the skill
has no app-runtime, release, or website integration.
