# Physical acceptance procedure

This procedure is for a deliberate test session, not an automatic checklist to run against real care records. Obtain permission for target-project changes and paid interpretation. Use a separate test family where possible. Existing parent-requested checks were stopped; [release notes](RELEASE.md) record what passed and what remains unverified.

## First live Siri save

1. Follow the [README](../README.md), sign in on an iPhone and open a child dashboard. Record the baseline event count.
2. Say “Hey Siri, Victoria Tracker”, then “Victoria drank 180 mL” after the prompt. Use the actual name.
3. Verify the Siri confirmation matches the spoken amount and appears only after saving. Check exactly one new Supabase feeding with the right child, UTC instant, actor, source and 180 mL.
4. Refresh the same child on the second parent’s phone. Verify the same entry appears once, attributed to the other parent.

## Optional regression pass

- Variable quantities and units: 200 millilitres, 190 M L; wet, dirty and mixed changes. Mixed contributes once to each diaper total. Check amounts against both transcript/confirmation and rows.
- Names: with two babies, an unnamed command must clarify without saving. A named command reaches only that child. Rename a profile and confirm its UUID/history remain.
- Relative/date-only time: feeding fifteen minutes earlier; weight on a specific past day without inventing a clock time; exact-day and month-only milestones with appropriate age labels. Future events must reject informatively with no row.
- Corrections: create a feeding, propose 20 mL leftover, cancel and verify no change; then propose/confirm and verify one revision on the same feeding, no duplicate. Verify revision conflicts do not silently overwrite.
- Sleep: start, restart/unlock the phone once, confirm the same running session/start, then wake from the other phone. Verify one completed duration and correct day totals across midnight.
- Offline retry: save a manual event once while offline. No successful-save claim should appear. Reconnect and use its original Retry/check entry; verify exactly one record and matching receipt, including on the other phone.
- Locked Siri: reboot, unlock once, then lock and record. Check exact amount and no duplicate. Before-first-unlock Keychain access is outside the supported promise.
- Non-events: separately submit a question, negation and hypothetical; verify no new records. Stop immediately if any saves.
- Manual diaper, milestone edit/cancel and signed-out Siri/re-login: check persistence, no mutation on cancel, useful sign-in guidance and recovery.

A new Siri invocation is a new request; use the pending original ID when uncertain whether a prior command saved. Do not delete/modify real records as test cleanup without explicit permission. Automated mocks are not substitutes for these live semantics and system behaviors.
