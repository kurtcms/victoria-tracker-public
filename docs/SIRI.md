# Siri recording

## Supported flow

1. “Hey Siri, Victoria Tracker.”
2. Siri asks “What’s up?”
3. Describe one completed event. Wait for the database-backed confirmation.

If the bare app name opens the app, say “Hey Siri, Talk to Victoria Tracker.” These and “Log/Record with Victoria Tracker” and “Log/Record an event with Victoria Tracker” route to the same intent. Every registered phrase uses the application-name placeholder. The required String parameter has no default; `AppShortcuts.xcstrings` supplies compiled English phrase resources.

Arbitrary trailing free speech is not a reliable App Shortcut phrase slot. This MVP intentionally uses a prompted second utterance, following [Apple’s App Shortcuts guidance](https://developer.apple.com/videos/play/wwdc2023/10102/). Fixed milk/diaper presets are retired: semantic routing previously matched different spoken quantities to a preset. Hidden compatibility identifiers now fail before networking rather than submitting a hardcoded event.

## Examples after the prompt

- “Victoria drank 180 mL.” Say millilitres or the letters M L.
- “Victoria drank 100 millilitres half an hour ago.”
- “Victoria had a wet diaper.” / “A dirty diaper.” / “A wet and dirty diaper.”
- “Victoria fell asleep five minutes ago.” / “Victoria woke up.”
- “Victoria weighed 7.365 kilograms on August 21.” A date-only weight needs no clock time.
- “Victoria waved hello for the first time on November 1.”
- “Victoria left 20 millilitres in her last bottle.” Siri reads back the target feeding and proposed total; approve before it changes.

Use the actual profile name. With multiple babies the description must name exactly one; dashboard selection is never used to guess. With one baby, pronouns can resolve to that profile. Clarification asks for a new complete description rather than filling missing details silently. Repeated full invocations are separate recordings, not retries.

## Responses and recovery

Successful dialog comes from validated persisted data, not model-authored claims. Corrections use native confirmation before applying an actor/revision-bound proposal. Cancelling or silence does not approve a change.

Future statements reject with an informative no-recording response. Ambiguity, unsupported input and unclear text ask for clarification or give a static explanation. Interpretation failures are handled before writes. A database/transport uncertainty preserves the pending command; use **Retry / check recording** in the app with its original ID. Do not record again while unsure whether it saved.

Siri controls speech recognition, trigger routing and dialog presentation. Failures before App Intent invocation cannot be customized by the backend. The model cannot repair misheard transcription. Under Siri Responses, **Always Show Request** displays speech, **Always Show Siri Captions** displays replies, and spoken-response preferences control audio. See [Apple’s settings guide](https://support.apple.com/en-au/guide/iphone/iphc28624b81abc/ios).

Locked invocation is allowed by the intent, but still requires a signed-in parent and Keychain availability after the first unlock following reboot. This does not bypass backend authentication or RLS. Locked-after-restart invocation was physically verified after unlocking once; before-first-unlock use is not promised. English is supported; Cantonese is future work.

If indexing is slow, open the app once and check Shortcuts for its “Record an event” action. A personal shortcut can use that action with **Event → Ask Each Time** and a short name. Do not prefill a numerical event as a variable recording action. [Release verification and limits](RELEASE.md)
