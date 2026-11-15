# Release status

## v1.0.0 — iOS 1.0 (15)

First tagged source release, November 15, 2026. The [changelog](../CHANGELOG.md) lists new features and fixes. Configure your own backend, Auth and development signing using [README](../README.md). This repository provides no hosted service access, family accounts or App Store/TestFlight binary.

The public repository has independent, sanitized Git history. Examples and fixtures use synthetic observations; it is not byte-identical to the developer-installed application. The WHO numerical CSVs are excluded and downloaded locally under the separate [third-party terms](../THIRD_PARTY_NOTICES.md). The MIT license covers original code/documentation/artwork, not third-party material or endorsement.

## Verification

The release implementation passed 127 mocked backend tests/type checks, 57 Swift core tests, 69 native XCTest tests, six Python security tests and the full isolated PostgreSQL migration/RLS/query/concurrency suite. The signed developer build, source/bundle secret scans and compiled English/zh-HK shortcut archives passed. The sanitized public export independently passed the same 127 backend, 57 core, 69 native and six Python tests, the isolated database suite, source/bundle scans and compiled English/zh-HK shortcut checks. See [testing](TESTING.md) for reproducible commands.

Bounded physical checks on developer phones established:

- Variable-volume milk and wet/dirty/mixed diaper recording, relative dates, clarifications and informative future-event rejection.
- One atomic milk-plus-diaper description, a read-only feeding answer, a confirmed correction preserving the same record, a confirmed deletion and a negation saving nothing.
- A Cantonese recording with the correct amount and persisted result. Spoken reply language and broader speech-recognition variants were not independently established.
- Shared family access on two phones, offline manual retry without duplication, shared sleep across restart and completion by the other parent, and locked-phone Siri after the first unlock.
- Guide milestone check/uncheck and source placement, plus six English queries: dirty diaper today, milk today, latest sleep start, latest wake, status report and care report. Care snapshots remained unchanged across the query session.

The milk-only answer was corrected after a live test to omit other totals and decimal zeroes. Report details subsequently shortened same-day dates to times while retaining dates for earlier days; that final wording has regression coverage without another physical session.

These results do not imply unrestricted model or Siri accuracy. Remaining unverified physical cases include hypothetical rejection, milestone editing/cancellation beyond the guide case, manual diaper entry, signed-out Siri/re-login, historical report variants, and the broader guide/manual-editor/concurrency matrix. Do not run paid or destructive checks automatically; use [acceptance procedures](ACCEPTANCE.md) with explicit authorization.

## Runtime limits

Siri uses a short trigger followed by a prompted description. Unrestricted trailing speech inside a single App Shortcut utterance is not promised. Recording requires internet access; uncertain submissions use the original pending request ID rather than a general offline queue. The app UI is English; Cantonese recognition depends on the phone's configured Siri language.

Multiple babies require an explicit spoken profile name. Multiple events validate and save together. Corrections/deletions require separate confirmation. Normal new descriptions are limited to the preceding 366 days. Growth charts do not diagnose development or interpret premature reference ages.

## Backend upgrades

Apply the five committed migrations in filename order before deploying the matching `care-command` and legacy `record-event` functions. Preserve applied migration bytes. The fifth migration wraps the prior conversation RPC behind a private permission boundary and adds sleep/care-report reads. Keep gateway JWT verification enabled and the `private` schema unexposed. [API](CARE_API.md), [security](SECURITY_AUDIT.md)
