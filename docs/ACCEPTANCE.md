# Physical acceptance procedure

This procedure is for a deliberate test session, not an automatic checklist to run against real care records. Obtain permission for target-project changes and paid interpretation. Use a separate test family where possible. Earlier parent-requested checks were stopped; a separately authorized six-case build 14 session is now complete. [Release notes](RELEASE.md) record what passed and what remains unverified.

## First live Siri save

1. Follow the [README](../README.md), sign in on an iPhone and open a child dashboard. Record the baseline event count.
2. Say “Hey Siri, Victoria Tracker”, then “Victoria drank 180 mL” after the prompt. Use the actual name.
3. Verify the Siri confirmation matches the spoken amount and appears only after saving. Check exactly one new Supabase feeding with the right child, UTC instant, actor, source and 180 mL.
4. Refresh the same child on the second parent’s phone. Verify the same entry appears once, attributed to the other parent.

## Optional regression pass

- Variable quantities and units: 200 millilitres, 190 M L; wet, dirty and mixed changes. Mixed contributes once to each diaper total. Check amounts against both transcript/confirmation and rows.
- Names: with two babies, an unnamed command must clarify unless a simple recording uses one uniquely configured she/he pronoun and every active profile has a setting. Shared, unset, unknown or conflicting subjects must clarify without saving. A named command reaches only that child. Rename a profile and confirm its UUID/history remain.
- Relative/date-only time: feeding fifteen minutes earlier; weight on a specific past day without inventing a clock time; exact-day and month-only milestones with appropriate age labels. Future events must reject informatively with no row.
- Corrections: create a feeding, propose 20 mL leftover, cancel and verify no change; then propose/confirm and verify one revision on the same feeding, no duplicate. Verify revision conflicts do not silently overwrite.
- Sleep: start, restart/unlock the phone once, confirm the same running session/start, then wake from the other phone. Verify one completed duration and correct day totals across midnight.
- Offline retry: save a manual event once while offline. No successful-save claim should appear. Reconnect and use its original Retry/check entry; verify exactly one record and matching receipt, including on the other phone.
- Locked Siri: reboot, unlock once, then lock and record. Check exact amount and no duplicate. Before-first-unlock Keychain access is outside the supported promise.
- Non-events: separately submit a supported question, negation and hypothetical; verify no new care records. The supported question should answer stored facts, while negations/hypotheticals reject. Stop immediately if any saves.
- Manual diaper, milestone edit/cancel and signed-out Siri/re-login: check persistence, no mutation on cancel, useful sign-in guidance and recovery.

## Build 14 physical coverage

The authorized six-case session covered an 80 mil + wet-diaper atomic batch, read-only last-feeding answer, confirmed 80-to-90 correction on the same record, confirmed wet-diaper deletion, negated 120 mil with zero saves, and Cantonese 50 mL persistence. Three separate Cantonese invocations created three rows; selecting Victoria, Today and refreshing revealed them per the user. Spoken reply language and the initial visibility cause were not established. The subsequent clearer deletion confirmation was regression-tested/deployed without another aloud test. [Exact results and limits](RELEASE.md)

The broader matrix below remains a procedure, not a claim that every item passed. Four older cases remain deferred: hypothetical rejection, milestone editing/cancellation, manual diaper entry and signed-out Siri/re-login. Supported questions now use read-only answers, superseding the old question-rejection case. No further paid tests are requested. Only run future paid Siri/text interpretation after explicit approval for that session. Use synthetic records in a separate family; deployment/install approval alone does not authorize billable checks.

- Confirm the welcome headline is “Parenting is hands-on. Tracking shouldn’t be.” and the supporting line “Say it. We’ll log it.”
- Check `mil` with a variable feeding amount and leftover correction. In the manual editor, verify **Change amount drunk**, **Subtract milk left in bottle**, the original bottle basis, before/after preview and **Save change** / **Cancel**. Zero consumed total removes the feeding from totals only after confirmation.
- Request a latest-record edit/removal in each supported category; cancel first, then explicitly confirm. Check the exact target/revision and no duplicate. A “from 30 to 80 mil” request must refuse a previous-value mismatch; earlier/nth or tied targets must clarify.
- Ask last-feeding/diaper/weight/milestone and day totals against known fixtures. Check phone-local date boundaries, sleep clipping, both mixed-diaper counts and explicit no-record language. Answers must not create care rows or save confirmations.
- Describe two through five events for one named baby. Check all appear once. Include an invalid or overlapping later sleep part and verify none persist; retry the original uncertain request rather than invoking again. A correction/query mixed with writes must clarify.
- On a phone supporting Siri Cantonese (Hong Kong), check the prompted trigger and Cantonese/code-switching descriptions, full-number quantities and replies. Ambiguous 一百八 and unsupported 安士 must clarify. Check negations, questions and hypotheticals independently; compiled zh-HK resources alone do not establish recognition.
- In **Milestones → Age guide**, verify current/next/earlier checkpoints and source links. **Observed today** must check only after persistence; **Choose an earlier date** cannot predate a known birthday or exceed today. Rapid taps, offline retry and both parents recording the same guide item must produce one active observation. An equal-title old free-text memory must remain separate and unchanged.

A new Siri invocation is a new request; use the pending original ID when uncertain whether a prior command saved. Do not delete/modify real records as test cleanup without explicit permission. Automated mocks are not substitutes for these live semantics and system behaviors.

## Build 15 acceptance coverage

Build 15 was deployed and installed on both phones on November 15, 2026. In the showcase family, the parent confirmed that tapping a milestone title checks it, tapping the checked item and confirming removal unchecks it, and source links appear in checkpoint descriptions.

The six separately authorized English Siri query cases passed: dirty diaper today, milk total today, last sleep start, last wake, status report and care report. The initial milk-total reply unnecessarily included other totals and decimal zeroes; the backend fix and live retry returned only the milk amount. Read-only database snapshots corroborated the answers and showed unchanged events and sleep records across the session.

These are bounded observed results. Cancellation, recheck, offline retries, concurrency, historical reports, alternate wording and Cantonese query replies retain automated coverage but were not all physically verified in this session. No further paid tests are requested.
