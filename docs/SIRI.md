# Siri recording

## Supported flow

1. “Hey Siri, Victoria Tracker.”
2. Siri asks “What’s up?”
3. Describe one to five completed events for one baby, ask about saved care, or request an edit/removal. Wait for the database-backed result.

If the bare app name opens the app, say “Hey Siri, Talk to Victoria Tracker.” These and “Log/Record with Victoria Tracker” and “Log/Record an event with Victoria Tracker” route to the same intent. Every registered phrase uses the application-name placeholder. The required String parameter has no default; `AppShortcuts.xcstrings` supplies compiled English and zh-HK phrase resources. The UI remains English.

Arbitrary trailing free speech is not a reliable App Shortcut phrase slot. This MVP intentionally uses a prompted second utterance, following [Apple’s App Shortcuts guidance](https://developer.apple.com/videos/play/wwdc2023/10102/). Fixed milk/diaper presets are retired: semantic routing previously matched different spoken quantities to a preset. Hidden compatibility identifiers now fail before networking rather than submitting a hardcoded event.

## Examples after the prompt

- “Victoria drank 180 mL.” Say millilitres, the letters M L, or “mil”.
- “Victoria drank 100 millilitres half an hour ago.”
- “Victoria had a wet diaper.” / “A dirty diaper.” / “A wet and dirty diaper.”
- “Victoria fell asleep five minutes ago.” / “Victoria woke up.”
- “Victoria weighed 6.125 kilograms on August 9.” A date-only weight needs no clock time.
- “Victoria waved hello for the first time on November 1.”
- “Victoria left 20 millilitres in her last bottle.” Siri reads back the target feeding and proposed total; approve before it changes.
- “Change Victoria’s last feeding from 30 to 80 mil.” The stored previous amount must match 30; review the target and approve 80.
- “Delete Victoria’s last wet diaper.” Review the selected record and confirm removal. Earlier/nth-record selection is unsupported in speech; choose it in the app.
- “Victoria drank 100 mL and had a wet diaper.” All parts must validate and save together; the maximum is five events for one baby. A question or correction cannot share that batch.
- “When and how much was Victoria’s last feeding?” / “How much has Victoria drunk today?” / “How many wet diapers has Victoria had today?”
- “Has Victoria had any dirty diapers today?” / “How long has Victoria slept today?” / “What was Victoria’s last weight?” / “What was Victoria’s latest milestone?” / “What was Victoria’s last diaper?”
- “Victoria飲咗一百八十毫升。” / “Victoria五分鐘前瞓著。” / “Victoria今日有冇大便？” Code-switching uses the same name, quantity and date checks.

Questions use authorized stored records and a closed set of latest-record/day-total queries, with phone-local today/yesterday or a clear calendar date. Mixed diapers count in both categories. No saved latest record is stated explicitly; a read answer never says an event was saved. Medical advice, unsupported metrics and multi-day windows clarify.

Use the actual profile name. With multiple babies the description must name exactly one; dashboard selection is never used to guess. With one baby, pronouns can resolve to that profile. Clarification asks for a new complete description rather than filling missing details silently. `一百八` is ambiguous: use `一百八十` for 180 or `一百零八` for 108. Ounces/安士 and unsupported clock/date expressions clarify; Siri transcription is never repaired by guessing. Repeated full invocations are separate recordings, not retries.

## Build 15 query examples

These six common English forms are matched by an authenticated closed grammar without a model call in deployed build 15:

- “Has Victoria had a dirty diaper today?”
- “How much has Victoria drunk today?”
- “When did Victoria fall asleep?”
- “When did Victoria wake up?”
- “Status report, Victoria.”
- “Care report, Victoria.”

The report combines today’s totals, the latest feeding and recorded sleep state. Supported historical reports stop at that day’s cutoff. Use the actual profile name; multiple babies still require one literal name, and mixed write requests do not match this shortcut grammar. The six English examples passed physical checks; Cantonese query replies have automated coverage only. The endpoint is deployed as the matching `care-command` function as of November 15, 2026, and build 15 is installed on both phones. The six separately authorized English query cases passed with unchanged care snapshots. No further paid live tests are requested.

## Responses and recovery

Saving confirmations come from persisted data; read-only answers come from database facts. Successful deletion replies now name the child and record, such as “Deleted Victoria’s wet diaper record.” This wording was deployed and regression-tested after the confirmed deletion case; it was not retested aloud. Corrections and deletions use native confirmation before applying an actor/revision-bound proposal. Cancelling or silence does not approve a change.

Future statements reject with an informative no-recording response. Ambiguity, unsupported input and unclear text ask for clarification or give a static explanation. Interpretation failures are handled before writes. A database/transport uncertainty preserves the pending command; use **Retry / check recording** in the app with its original ID. Do not record again while unsure whether it saved.

Siri controls speech recognition, trigger routing and dialog presentation. Failures before App Intent invocation cannot be customized by the backend. The model cannot repair misheard transcription. Under Siri Responses, **Always Show Request** displays speech, **Always Show Siri Captions** displays replies, and spoken-response preferences control audio. See [Apple’s settings guide](https://support.apple.com/en-au/guide/iphone/iphc28624b81abc/ios).

Locked invocation is allowed by the intent, but still requires a signed-in parent and Keychain availability after the first unlock following reboot. This does not bypass backend authentication or RLS. Build 13 locked-after-restart invocation was physically verified after unlocking once; before-first-unlock use is not promised. Build 14 implements English/Cantonese extraction and static Cantonese replies. For Cantonese recognition, use Siri’s Cantonese (Hong Kong) language where available. The bundled zh-HK phrases include “同 Victoria Tracker 講低” and “用 Victoria Tracker 記低”, and the authorized live session confirmed a 50 mL Cantonese recording with server language `yue`. Three separate invocations created three distinct 50 mL rows; the user later saw all three after selecting Victoria, Today and refreshing. This does not establish the cause of initial timeline visibility or the language spoken in the reply. Device support and Siri language determine recognition; do not assume automatic mixing of Siri recognition languages or that every example utterance will route correctly.

If indexing is slow, open the app once and check Shortcuts for its “Record an event” action. A personal shortcut can use that action with **Event → Ask Each Time** and a short name. Do not prefill a numerical event as a variable recording action. [Release verification and limits](RELEASE.md)
