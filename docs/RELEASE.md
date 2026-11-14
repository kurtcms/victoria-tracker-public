# MVP release status

Baseline: **1.0/build 13**, installed on both parents’ phones. Both deployed endpoints (`care-command`, legacy `record-event`) are version 4 with gateway JWT verification enabled. Three immutable SQL migrations define the shared schema. English, online recording and a prompted two-turn Siri flow are the supported MVP.

## Implemented

Feeding/mL, wet/dirty/mixed diapers, confirmed leftover/consumed-total correction, multiple babies and shared profiles, sleep start/wake/daily duration, date-only weights with official WHO trajectories, day/month milestones and approximate age, manual fallback, local-day history, shared revisions and recovery of uncertain submissions. The Day dashboard prioritizes milk, total sleep, wet and dirty counts; Growth/Milestones/Family have dedicated views.

Build 13 fixes missing age labels on month-only milestones. It shows a completed-age range across the known month (for example About 3–4 months old), clipped to birth and today, rather than inventing an exact milestone day. Exact-day labels retain their behavior.

## Recorded verification

- Final cleanup verification (November 14, 2026): 78 mocked backend tests/type checks, 51 native Xcode tests, 41 standalone Swift core tests, six Python security tests and the PostgreSQL migration/RLS/postflight/concurrency suite passed.
- The previously installed build passed signing checks. The cleaned project passes the simulator suite and an unsigned iPhone-SDK build from a separate checkout with no local configuration. Source/bundle secret scans, compiled English Siri resources, deterministic project generation, documentation links and WHO hashes pass. The three applied migration hashes are unchanged.
- Physical variable-volume feeds, wet/dirty/mixed diapers, relative times, same-event self-correction, clarification/future responses and historical weight/milestone saves passed their recorded cases.
- Feeding correction create/cancel/confirm preserved the same event and applied one revision with no duplicate.
- Multi-baby selection, required-name routing, add/rename continuity and profile access passed.
- Two distinct confirmed parents joined one family and saw existing Growth/Milestones records. Feeding synchronization worked in both directions with correct actor labels.
- Offline manual feeding moved from pending to one persisted record on retry and appeared once on the other phone.
- A running shared sleep survived a phone restart with the same ID/start, then was ended by the other parent with one wake revision.
- Siri recorded 190 mL (spoken letters M L) after reboot/first unlock while the phone stayed locked.

These are bounded recorded results, including parent-reported UI behavior with database corroboration where noted. They are not a claim of unrestricted voice/model accuracy.

## Explicitly deferred

The parent stopped further physical testing. Six cases remain unverified: **question, negation and hypothetical rejection; milestone editing/cancellation; manual diaper entry; signed-out Siri/re-login**. Corresponding automated coverage does not establish physical acceptance. Do not silently restart those paid/manual checks.

Only supported non-premature WHO reference ages are plotted; there is no growth diagnosis or Cantonese support. New normal commands are limited to the preceding 366 days. Recording requires connectivity; uncertain requests have retry recovery, not a general offline queue.

## Deployment and distribution

Each installation needs its own Supabase backend/account access, public client configuration and Apple signing team as described in the README. Provisioning expiry and distribution are the maintainer’s responsibility. Source publication does not deploy a backend or install an app. No production data, account details, import/reset scripts or operational log are included.

Examples and test fixtures use synthetic observations. They are not records of a real child. WHO reference data is third-party material downloaded during setup, excluded from Git and governed by its own terms; see THIRD_PARTY_NOTICES.md.
