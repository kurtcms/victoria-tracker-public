# Release status

## v1.2.1 — iOS 1.0 (17)

This documentation-only patch corrects stale release/version claims and clarifies historical Siri acceptance. App and backend source are unchanged from v1.2.0, which improved recent-event recording, memory browsing and recorded sleep-state replies. It retains conversational recorded-care queries across feeding, diapers, sleep, weight and milestones. Configure your own backend, Auth and development signing through [README](../README.md). No hosted service access, family accounts, signing credentials or App Store/TestFlight binary is included.

The public snapshot has independent Git history. Examples and fixtures are synthetic, not records of a real child. WHO numerical CSVs are excluded and downloaded locally under the separate [third-party terms](../THIRD_PARTY_NOTICES.md). The MIT license covers original application code, documentation and artwork; it does not relicense third-party material or imply endorsement. The public snapshot is not byte-identical to the developer-installed application.

## Changes in v1.2.0

“Had” with one explicit mL quantity now validates as feeding. “Just now” accepts a zero-minute relative interpretation at the captured request reference; conflicting clocks or earlier dates still clarify. Questions, negations, plans, ambiguous amounts and unnamed multiple-child requests cannot create events.

Memory forms use “Record a memory” and “Memory” without a first-time option. Search titles/notes, sort newest first, oldest first or A–Z, and preserve month-only precision. Care/status reports exclude memories; explicit memory questions remain supported. Sleep-state replies identify the last recorded transition and missing next event, with an out-of-date warning after six hours.

## Query behavior

Compositional interpretation distinguishes recorded sleep state from historical sleep, existence from counts, latest records from latest subtypes, durations from elapsed time, and consumed milk from unsupported offered/remaining observations. Missing records do not prove that an activity did not occur. Open sleep is shown separately from completed duration; stale or inconsistent histories produce qualified answers. Short feeding follow-ups may bind an exact prior record, with explicit names/times taking precedence. [Taxonomy, examples and limitations](CONVERSATIONAL_QUERIES.md)

## Verification

The v1.2.0 sanitized source passed 145 current-care and 42 legacy backend tests/type checks, 60 Swift core tests, 72 native simulator tests, six Python security tests, isolated PostgreSQL, unsigned iPhone-SDK compilation, source/bundle secret scans and compiled English/Cantonese Siri-resource checks. Validation-only WHO CSVs matched the pinned manifest and remain excluded from publication.

For v1.2.1, application/backend/test/configuration bytes and modes are unchanged; those source-bound results remain applicable. Documentation, local links, release mappings, the exact exported tree and secret/privacy boundaries are rechecked. This source-only metadata patch does not install a new binary or establish new live model/speech accuracy. Historical v1.1.0 results remain recorded in its immutable release; counts from different releases are not combined. Run [testing](TESTING.md) to reproduce checks with synthetic mocks or disposable PostgreSQL.

Historical bounded physical checks are documented in [acceptance coverage](ACCEPTANCE.md). They do not prove every new paraphrase, historical window, follow-up or Cantonese response. Do not restart stopped physical/paid suites without explicit authorization.

## Runtime limits

Siri uses a short trigger followed by a prompted description. Unrestricted trailing speech inside one App Shortcut utterance is not promised. Recording requires internet access; uncertain submissions retry the original prepared request rather than creating a general offline queue. The app UI is English; Cantonese recognition depends on the phone's configured Siri language.

Multiple babies require an explicit spoken profile name; selection or follow-up context cannot replace it. Batches validate/save atomically, and edits/deletions need separate confirmation. Context is in-memory and expires after ten minutes. Naps are defined by local start time because no nap label is stored. Offered/remaining/estimated milk observations and broad semantic milestone matching are not stored or inferred. Incomplete snapshots fail explicitly above 10,000 records per domain. Growth charts make no medical conclusions.

## Backend upgrades

Apply all six migrations in filename order before deploying the matching functions. The new `202611160001_read_snapshot.sql` adds a stable security-invoker snapshot under caller RLS. Preserve all previously applied migration bytes and legacy RPC contracts. Keep gateway JWT verification enabled and the `private` schema unexposed. Run the read-only post-migration checks; never run destructive SQL fixtures on a hosted database. [API](CARE_API.md), [security](SECURITY_AUDIT.md)
