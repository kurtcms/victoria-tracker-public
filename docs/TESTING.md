# Testing

Run from the repository root. Export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The default automated suites use mocks or disposable/synthetic data; they do not call OpenAI or access a hosted project.

## Recent-event regression coverage

Handler tests cover 152 combinations of diaper/feeding wording, explicit quantities/units, punctuation and now/relative extraction. Additional cases preserve calendar/clock constraints, reject unsafe/ambiguous input, validate atomic named batches and retain a sleep interval’s elapsed start when its end is “just now.” External model/database responses are mocked; these tests do not establish live model extraction or physical speech recognition.

## Backend and security

```sh
deno task --config supabase/functions/care-command/deno.json check
deno task --config supabase/functions/care-command/deno.json test
deno task --config supabase/functions/record-event/deno.json check
deno task --config supabase/functions/record-event/deno.json test
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/security_checks.py source
python3 scripts/test_database.py
```

Deno tests cover Auth forwarding/failure, anonymous rejection, names, quantities/units, time/DST, date-only weights, milestone grounding, finite actions/conversations, strict operation-specific schema/neutral-default regressions, deletion wording, atomic batches, read-query routing, explicit edit/delete confirmation, English/Cantonese/code-switching quantities and static replies, retries, interpretation failures and uncertain writes. They mock extraction; they cannot prove live model semantics or speech recognition.

The database runner requires Docker. It uses `postgres:15-alpine`, starts a disposable container with `--network none`, applies all migrations, checks the verification SQL and runs real role/RLS, precision, cross-family, invite, idempotency, correction/sleep and concurrent-write tests. Build 14 adds `conversation.sql` checks for atomic rollback/inner receipts, latest qualifying selectors, expected previous values, read-only queries with captured phone day/DST boundaries, mixed counts, latest date-only weights, and independent guide-ID uniqueness across parents/retries. It removes the container afterward. Docker may need to download that image on its first run. Never copy these fixtures to a live project.

## Native tests and build

```sh
swift test --scratch-path /private/tmp/victoria-core-tests
xcrun simctl list devices available

# Replace YOUR_SIMULATOR_ID with an installed runtime/device ID.
xcodebuild -project ios/VictoriaTracker.xcodeproj -scheme VictoriaTracker \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -derivedDataPath /private/tmp/victoria-ios-tests CODE_SIGNING_ALLOWED=NO test

# Compile for the physical-device SDK without signing or installing.
xcodebuild -project ios/VictoriaTracker.xcodeproj -scheme VictoriaTracker \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/victoria-device-build CODE_SIGNING_ALLOWED=NO build

python3 scripts/check_intents_metadata.py \
  /private/tmp/victoria-device-build/Build/Products/Debug-iphoneos/VictoriaTracker.app
python3 scripts/security_checks.py bundle \
  /private/tmp/victoria-device-build/Build/Products/Debug-iphoneos/VictoriaTracker.app
```

Swift Package tests cover core calculations only. The Xcode suite additionally covers Auth callbacks, model history/concurrency, Siri forwarding/confirmation language, answered-versus-persisted responses and actual native screen rendering. Core coverage includes guide checkpoints, source/identity coverage, observation dates and retry state; presentation coverage includes feeding correction basis/preview and the exact welcome copy. Presentation attachments in the `.xcresult` use synthetic data; inspect them in Xcode. They are not physical Siri evidence.

The built-artifact checker requires exactly one discoverable recording shortcut, a required String without a default, hidden preset tombstones and nonempty compiled English and zh-HK `nlu.appintents` resources. A successful compile alone is insufficient if phrase training failed. A signed device build additionally needs `codesign --verify --deep --strict PATH_TO_APP` and a valid profile covering the target device.

Validation results for this release belong in [release status](RELEASE.md). Mock/local checks do not establish live provider, speech-recognition or care-flow acceptance. Existing historical physical results remain separately bounded in [acceptance coverage](ACCEPTANCE.md).

## Reproducibility and resources

`python3 scripts/generate_project.py` rebuilds the committed Xcode project deterministically and preserves configured versions, bundle IDs and signing choices. Regenerating twice should produce no second diff. Build with the ignored local config temporarily absent to verify the credential-free default still compiles; it intentionally shows “Connect Supabase.”

WHO CSV hashes/row counts are pinned in [SOURCE.json](../ios/VictoriaTracker/Resources/Growth/SOURCE.json). `scripts/import_who_reference.py` downloads the original WHO workbooks and regenerates them; network access is required and output changes need review. `scripts/generate_app_icon.swift` regenerates the included opaque PNG using the Xcode Swift toolchain. Neither is a setup/build prerequisite.

Actual Siri/model, locked/background, offline recovery and two-phone behavior require a separately authorized physical procedure. Use [acceptance checks](ACCEPTANCE.md); do not run billable tests automatically as part of a build. [Recorded results and deferred cases](RELEASE.md)
