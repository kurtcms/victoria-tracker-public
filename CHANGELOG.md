# Changelog

## [1.1.0] - 2026-11-15

### Added

- Conversational read queries across feeding, diapers, sleep, weight and milestones using shared English/Cantonese interpretation rather than a handler per phrase.
- Separate current recorded state, historical existence, counts, latest subtypes, totals, elapsed time and duration.
- Short-lived exact-feeding follow-ups, with explicit child names and time scopes taking precedence.
- A caller-authorized read snapshot RPC that leaves mutation, confirmation and atomic batch contracts intact.

### Improved

- Qualify missing, incomplete, stale and inconsistent records; missing observations never become proof of a real-world negative.
- Separate completed sleep from elapsed time in open sessions, including local-day boundaries and timezone transitions.
- Report milk consumed without substituting offered volume; count mixed diapers once per change and once toward each wet/dirty total.
- Use natural spoken/visual durations, units and contextual dates; keep concise questions focused and detailed reports relevant.

### Validation and limits

- Public candidate validation results are recorded in [release status](docs/RELEASE.md).
- New real-provider and physical recognition tests are not claimed; existing acceptance evidence retains its recorded scope.
- This is an MIT-licensed source release corresponding to iOS 1.0 (16), with synthetic fixtures and separately governed WHO numerical tables excluded.

## [1.0.0] - 2026-11-15

First tagged source release, corresponding to iOS **1.0 (15)**. This is a source release for developer installation, not an App Store or TestFlight distribution.

### Added

- Record English or Cantonese baby-care descriptions through a prompted Siri conversation, including `mil`, mL and spoken M L units.
- Record up to five events for one baby in one description, saving all together only when every event validates.
- Ask Siri about feeding totals, dirty diapers, the latest feeding, sleep start/wake times, and daily care/status reports.
- Correct or delete the latest qualifying record by voice, with an exact-record proposal and explicit confirmation before changes.
- Browse an age-based milestone guide with CDC, AAP, Rourke Baby Record and CPS source links; record observations by tapping a milestone and confirm removal to uncheck it.
- Share multiple baby profiles, feeding/diaper history, running sleep, date-only weights, WHO growth trajectories and milestone timelines between parents.
- Recover uncertain submissions using their original recording IDs, with authenticated family access and revision checks.

### Improved

- Clarified manual feeding corrections: change the amount drunk or subtract milk left in the bottle, with a before/after preview.
- Added the welcome copy “Parenting is hands-on. Tracking shouldn’t be.” and “Say it. We’ll log it.”
- Kept milestone sources in age-section descriptions so milestone taps record observations.
- Made milk-only questions answer only the milk total, without unnecessary trailing decimal zeroes.
- Made care/status report detail times omit same-day dates while retaining dates for earlier-day records.

### Fixed

- Prevented harmless extraction defaults from blocking multi-event recording and confirmed feeding corrections.
- Added direct, authenticated read-only routing for common English care questions that previously failed interpretation.
- Made deletion confirmations identify the baby and record rather than refer to totals.
- Preserved reported historical dates and milestone wording, including age labels for month-only memories.
- Clarified future-event, ambiguous-input and interpretation-failure responses without claiming a save.

### Validation and limitations

- Passed 127 backend tests, 57 Swift core tests, 69 native XCTest tests, six Python tests, isolated PostgreSQL/RLS/concurrency tests, signing checks and source/bundle scans.
- Physically verified the milestone interactions and six English query cases, alongside the earlier bounded Siri recording/correction tests. Mock coverage does not establish unrestricted recognition accuracy.
- Siri uses a trigger followed by a prompted description; arbitrary trailing speech in one App Shortcut utterance is not promised. Recording requires internet access.
- See [release status](docs/RELEASE.md) and [acceptance coverage](docs/ACCEPTANCE.md) for the remaining unverified cases. WHO numerical tables are excluded from the public source distribution and downloaded locally under WHO’s terms.
