# Victoria Tracker

## Boundaries that matter

- Keep credentials, sessions, auth links, recordings, real family observations, device IDs and signing material out of Git and logs. Do not read secret-bearing files merely to document configuration.
- The private repository has private history. Publish a reviewed, sanitized snapshot to the separate public repository; never merge, mirror or force-push private history into it. Preserve the public MIT license, third-party notices, demo and Codex disclosure.
- Public snapshots exclude the numerical WHO CSVs. Preserve their provenance manifest and local download instructions; source-code licensing does not relicense WHO material.
- Deployments, account/settings changes, paid resources and paid OpenAI tests need explicit authorization for their scope. Reuse existing authorization; routine local fixes/tests need no extra confirmation. Commit, push, merge and publish only when authorized.
- Existing SQL migrations are immutable after application. Add a new migration for schema/RPC changes. Preserve deployed legacy contracts and existing records.

## Product decisions to preserve

- The supported Siri flow is a short trigger, then a prompted free-text description. Do not claim arbitrary single-utterance App Shortcut capture works. A required String has no preset/default; keep English and Cantonese phrase resources.
- Confirm a recording only after database persistence. Questions answer stored facts without care writes. Edits/deletions propose an exact target/revision and require separate confirmation.
- Accept `mL`, spoken M L and `mil`; preserve quantities and distinguish actual events from questions, negations, plans and hypotheticals. Clarify ambiguity rather than inventing a value/date/name.
- Multiple events for one baby validate/save atomically. With multiple babies, require exactly one spoken profile name; dashboard selection is not an implicit voice target. Keep the single-baby dashboard simple.
- Retries reuse the original request ID. A new Siri invocation is a new request. Preserve pending recovery when persistence is uncertain; do not relabel a transport failure as definitely unsaved.
- Record instants in UTC, but use captured phone-local dates/timezone transitions for reports/history. Follow the phone timezone during travel. Weight and milestone date-only/month-only observations must not acquire invented clock times or exact days.
- Milk questions return milk only, without unnecessary decimal zeroes. Care/status reports include totals, latest feeding and sleep status. Report detail times omit the date within the report day; earlier-day facts retain dates. Never reinterpret RPC local display strings as UTC.
- Prioritize daily milk, total sleep, wet and dirty counts. Mixed diapers count once in each diaper total. Sleep start/wake share one persisted session; clip daily duration to the selected day.
- Growth is a separate trajectory view using explicit WHO reference selection; no diagnosis or alarm for a missing daily weight. Milestones can be absent or multiple on a day without a score/goal.
- Age-guide titles/checkmarks record observations; source links belong in checkpoint descriptions. Unchecking confirms removal of the exact guide observation, then permits rechecking. Keep free-text memories separate from guide IDs.
- English app screens and English/Cantonese extraction/replies are supported. Mock tests and compiled phrase resources do not establish physical speech-recognition accuracy.

## Start with the relevant files

- `ios/VictoriaTracker/App/`: SwiftUI entry point and shared `AppModel`; `Services/`: Auth, Keychain, backend requests; `Core/`: dependency-free models/calculations.
- `ios/VictoriaTracker/Views/`: Day, Growth, Milestones/age guide, Family and recording/correction flows. `Intents/RecordIntents.swift` owns prompted Siri behavior.
- `supabase/functions/care-command/`: current authenticated endpoint. `conversation.ts` validates extraction/closed read-query routing; `language.ts` renders database facts; `handler.ts` handles Auth, retries and RPC calls.
- `supabase/functions/record-event/`: legacy endpoint and shared validators. Keep compatibility for older pending commands.
- `supabase/migrations/`, `supabase/tests/`: schema/RLS/RPC sources and isolated SQL fixtures. `preflight.sql` is for fresh projects; `verify_deployment.sql` checks applied schema/privileges.
- `tests/swift/` runs in both the Swift package and native XCTest target. Python security tests are in `tests/test_security_checks.py`.
- Read [architecture](docs/ARCHITECTURE.md), [API](docs/CARE_API.md), [Siri](docs/SIRI.md) or [milestone provenance](docs/MILESTONE_SOURCES.md) as needed. Use [release status](docs/RELEASE.md) and [acceptance coverage](docs/ACCEPTANCE.md) for evidence and unverified limits, not old plans as proof of shipped behavior.

## Setup and generated files

Follow [README](README.md) for iPhone/backend setup. Full Xcode is required; the release was verified with Xcode 27.2, Deno 2, Supabase CLI 3.1.0 and PostgreSQL 15. Python scripts use the standard library. There are no third-party iOS package dependencies.

- `ios/Config.xcconfig` and the example are safe defaults. Keep local public URL/key and signing choices in ignored `ios/Config.local.xcconfig`. Never put service-role/OpenAI keys in the app.
- Backend secrets: `OPENAI_API_KEY`, optional `OPENAI_MODEL`, and `VT_SUPABASE_PUBLISHABLE_KEY`; Supabase supplies its URL/key environment. `gpt-4.1-mini` is the configurable extraction default.
- Both Edge Functions use `verify_jwt=true` plus explicit Auth/user validation. Never disable gateway verification or expose the `private` schema to the Data API.
- `scripts/generate_project.py` deterministically generates the committed Xcode project and preserves existing signing, bundle-ID and version settings. New source files require regeneration; changing its default version alone does not bump an existing project.
- `scripts/import_who_reference.py` downloads official data and regenerates CSVs/manifest; review WHO terms and outputs. Do not run it on every build. Keep downloads/build outputs outside publication artifacts.
- Keep local config and Supabase linking state when cleaning. Remove obsolete caches/logs, not required resources, applied migrations or useful provenance. Build/test scratch output belongs outside the repo.

## Local validation

Run from the repository root. These commands have passed for the release; mock/local checks do not contact production or OpenAI. Docker must be running for the database suite; its initial image pull may require network access.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/generate_project.py
deno task --config supabase/functions/care-command/deno.json check
deno task --config supabase/functions/care-command/deno.json test
deno task --config supabase/functions/record-event/deno.json check
deno task --config supabase/functions/record-event/deno.json test
python3 -B -m unittest discover -s tests -p 'test_*.py'
python3 -B scripts/security_checks.py source
python3 scripts/test_database.py
swift test --scratch-path /private/tmp/victoria-core-tests
```

For native tests, choose an existing simulator ID with `xcrun simctl list devices available`, then run:

```sh
xcodebuild -project ios/VictoriaTracker.xcodeproj -scheme VictoriaTracker \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -derivedDataPath /private/tmp/victoria-ios-tests CODE_SIGNING_ALLOWED=NO test
```

Use [testing](docs/TESTING.md) for device-SDK compilation, source/bundle secret checks, compiled English/zh-HK shortcut checks and signing verification. Restricted runners may need local execution/sandbox allowances; do not weaken product build settings to accommodate a runner. Run proportionate checks after changes, preserving others' work and reporting actual failures, blockers and unverified behavior. Physical/paid tests need their own authorization; never silently restart a stopped suite.

## Release work

Maintain [CHANGELOG](CHANGELOG.md) with concrete features/fixes and [release status](docs/RELEASE.md) with bounded evidence. A GitHub source release is separate from backend deployment, iPhone installation and App Store/TestFlight distribution; do not imply one performs the others. Never upload development-signed apps, local configurations or WHO tables to a public release.
