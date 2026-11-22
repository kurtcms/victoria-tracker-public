# Conversational recorded-care queries

## Assessment

The existing voice pipeline already separated questions from mutations, validated finite extraction, grounded child names/values/dates, preserved atomic batches and required confirmation for corrections. Its reads were limited to latest records and calendar-day totals. Wording checks conflated latest diaper with latest wet/dirty diaper, did not represent current sleep/existence separately, had no follow-up memory, and exposed minute totals and full dates. Open sessions contributed elapsed time without separating it from completed sleep. Missing latest records were already described as unrecorded rather than proof of real-world absence.

## Intent taxonomy

A single `QuerySpec` composes these dimensions, rather than adding a handler per phrase:

| Dimension | Values |
| --- | --- |
| Domain | Feeding, diaper, sleep, weight, milestone, care |
| Operation | Latest, first recorded, exists, count, total, state, elapsed, duration, report |
| Subtype | All; wet/dirty; daytime nap; sleep start/wake |
| Quantity meaning | Consumed, offered, remaining |
| Scope | All history, calendar day, morning, afternoon, tonight/evening, rolling minutes, since last feeding, before/after an identified sleep |
| Presentation | Brief/detailed, time/amount focus, exact date/timestamp, metric/US units, spoken/visual |

Care/status reports exclude memories, including detailed records and month-precision completeness checks. Ask about memories explicitly to retrieve them. Sleep-state replies say “Last recorded asleep from…” or “Last recorded awake at…” and identify the missing next record. “This record may be out of date” appears only when the last sleep start or wake-up is more than six hours old; this is a product heuristic, not a clinical threshold. Replies do not verify the baby's state now.

English/Cantonese/code-switched semantic cues compose the same intents: pee/number one/wet and poop/number two/dirty select diaper subtypes. A mixed diaper contributes to each subtype once and to the change count once. Sleeping/napping/up select state; slept/napped select existence; “how long since” selects elapsed rather than duration. Milestone topics retain the parent's actual contiguous wording, with conservative English inflection matching; they never match an unrelated milestone merely because it is recent.

## Architecture

- `conversation.ts` preserves the finite model schema and existing mutation validation. It accepts legacy query extraction and the compositional alternative.
- `query_interpret.ts` owns semantic components and deterministic date/window interpretation. The authenticated direct path handles recognized questions without paid extraction. Other input retains the strict model route; unvalidated questions clarify.
- `query_service.ts` resolves authorized children, translates validated legacy reads and binds eligible follow-ups to exact records.
- `read_care_snapshot` is an additive, stable, security-invoker RPC. One MVCC snapshot supplies minimum read fields across domains under the parent's RLS. No care writes, proposals or receipts are created. Existing RPCs/migrations remain intact.
- `query_execute.ts` validates facts, intersects captured timezone segments, sums milk in integer hundredths, counts diapers, clips completed sleep, and assesses evidence.
- `query_format.ts` composes bilingual responses and shares locale-aware unit/date/duration formatters. No model performs arithmetic, totals, date formatting or answer translation.
- The existing Siri and in-app text paths receive the same result semantics. The dashboard separates completed sleep from unconfirmed elapsed time in open sessions.

## Evidence and uncertainty

`QueryFacts.evidence` explicitly represents positive, negative, unknown, incomplete or stale evidence. Current storage cannot prove that an unrecorded real-world activity did not occur, so an empty search yields unknown, never a confirmed negative. State answers describe the last recorded transition rather than asserting the child's current activity. State older than six hours is stale; this is a conservative product rule, not a clinical sleep limit.

Open sleep contributes **zero confirmed completed duration**. Its elapsed portion, clipped to the requested window, is shown separately as unconfirmed. Overlapping/inconsistent histories suppress a reliable duration total. Historical reports use their own end cutoff; later wake/feeding events cannot change the historical state. Instant ties, date-only ties and overlapping day/month precision retain possible first/latest candidates and disclose that order is unknown. They cannot produce an arbitrary follow-up target.

`volume_ml` is recorded consumed intake. `feeding_basis_ml` is a correction basis and does not universally establish offered volume; offered/remaining queries therefore acknowledge missing evidence. They never substitute consumed or original bottle volume. Estimated intake is not stored and is not invented.

## Time and context

Captured phone offsets remain authoritative, including midnight, clock changes and travel. There is no child-specific query timezone setting in the existing product; adding one would conflict with the phone-following contract. Calendar arithmetic uses neutral date coordinates; event instants remain UTC. Older instants outside the captured 366-day horizon use the requested IANA zone for display only. A date-only observation remains date-only, and a month-only memory never acquires an exact day.

Today/yesterday, morning (00:00–12:00), afternoon (12:00–18:00), tonight/evening (18:00–24:00), rolling ranges up to seven days, last weekday, and supported English/Chinese calendar dates are deterministic. Missing years use the current local year only for nonfuture dates. Unsupported or ambiguous references (including last night, broad week/month windows, earlier/nth anchors and ambiguous clocks) clarify rather than broaden. Before/after a nap requires one qualifying session that day; naps are explicitly defined as sessions starting 06:00–18:00 local because no nap label is stored.

Fresh text/Siri commands can attach optional `query_context` with child/domain/exact record and reference time. Context expires after ten minutes, remains only in client memory, clears on auth changes/unrelated outcomes/errors, and never changes queued retries or grants mutation authority. A brief feeding amount follow-up can bind the prior exact feeding. Explicit domains, dates, ranges and names override it. With multiple profiles, the existing literal-name requirement remains; dashboard selection or context alone does not authorize a pronoun target.

## Formatting

Durations use minutes below an hour, hours plus remaining minutes thereafter, and omit zero minutes. Visual labels use `3h 20m`; spoken English uses “3 hours and 20 minutes,” with Cantonese composition. Metric milk stays in mL even above 1,000; exact stored fractions survive. US fluid ounces are explicitly approximate. Spoken metric weight uses kilograms plus grams, visual weight uses kg; pounds/ounces use a labelled approximation with fractional ounces. Metric is the default; optional request presentation preferences or explicit requested units select alternatives. No new family settings UI or account-setting mutation is introduced.

Same-day instants use clock time; yesterday/recent weekdays avoid needless calendar dates. Older dates include the year only across years. An explicit timestamp includes date, year, seconds and UTC offset. Dates already established by a requested day are omitted from detail clocks. Milk-only and domain reports exclude unrelated care information. Detailed reports show typed values/times; long lists are bounded with an explicit pointer to the app.

## Before and after

These are synthetic examples of code behavior, not physical speech acceptance results.

| Question / fixture | Previous behavior | New behavior |
| --- | --- | --- |
| “Is she sleeping?”; old open session | Generic clarification | Latest recorded start is reported, missing wake acknowledged, current state uncertain/stale |
| “Has she had a number one today?”; empty history | Unsupported wording | “I don’t have any wet diaper records for Victoria today.” |
| “When was her last wet diaper?”; latest diaper is dirty | Could select latest diaper of any type | Selects latest wet or mixed record and speaks only the relevant time |
| “How long has she slept today?”; 200 completed minutes, open 61 minutes | Minute total could include open elapsed time | “3 hours and 20 minutes of completed sleep; an open session has 1 hour and 1 minute elapsed, unconfirmed.” |
| “How much did she drink?” after a latest-feeding answer | No exact-record memory; daily amount interpretation | Prior exact feeding amount, unless an explicit range overrides context |
| “What was her last weight?”; 7.365 kg, date only | Raw decimal/full date | “7 kilograms and 365 grams,” with an appropriately short measurement date and no clock |
| “Give me a detailed feeding report” | Unsupported or insufficiently specific | Recorded consumption, feed count and individual amounts/times; no diaper/sleep metrics |

## Verification and limits

See [release status](RELEASE.md) and [testing](TESTING.md) for source validation and known limits. Tests exercise actual interpretation, calculations, handler orchestration and formatting with mocked Auth/database/provider boundaries and synthetic PostgreSQL fixtures. They do not establish paid OpenAI extraction quality or physical English/Cantonese recognition. Examples and fixtures in this public snapshot are synthetic, not real child observations.

Remaining limitations: lexical milestone matching cannot establish arbitrary semantic equivalence across languages; unsupported paraphrases clarify. Context is one prior read target, not a full transcript, and does not survive process restart. No stored nap label, offered-volume observation, estimated-quantity metadata or completeness-of-real-world-history flag exists. Snapshot payloads are capped at 10,000 rows per domain and fail explicitly when incomplete; indexed windowed/paginated retrieval is the next scaling improvement. Existing legacy RPC callers retain their old contract; the new Edge path uses the improved calculation/formatting layer. Add provider evals and bounded bilingual physical acceptance only after separate authorization. No medical conclusions are generated.
