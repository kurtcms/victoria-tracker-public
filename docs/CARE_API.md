# Care command API

Deployed endpoint: `POST /functions/v1/care-command` (version 4, gateway JWT verification enabled). Headers are the same public apikey and signed-in user Bearer JWT used by record-event. No service key is accepted by the app. JSON body is at most 8 KiB; text at most 1,000 UTF-16 code units.

Common fields: request_id UUID, reference_at UTC instant, time_zone IANA name, utc_offset_seconds integer bounded to ±14h, zone_offsets array of 1–16 `{from:UTC,seconds:integer}` entries covering the preceding 366 days in ascending order, and source (`siri`, `text`, `manual`). The final transition offset must match utc_offset_seconds. Capture once and reuse the exact command for retries. Hashing canonicalizes object key order and UUID casing; changing time/name context is a different command.

Modes:

- text: mode="text", text description, optional child_id for app context. With multiple babies the text itself must name exactly one profile; a selected child_id does not satisfy this rule. The model’s extracted name must agree with the literal authorized name. No selected child is attached to Siri input.
- action: mode="action", source="manual", explicit child_id, action and typed payload. Actions are record, sleep_start, sleep_end, sleep_interval, milestone, propose_feeding and propose_edit. Unknown keys are rejected. Ordinary record payloads retain the legacy feeding/diaper/weight shape and explicit unrelated nulls; weight adds its local measurement_date. Sleep uses occurred_at and optional ended_at. Milestones use title, optional note, occurred_on, date_precision and is_first. Feeding proposals use correction_kind (leftover/total), amount_ml and optional target_id; omitted target means the latest unambiguous feeding within six hours. Generic edit proposals bind target_type, target_id, expected_revision, void and applicable replacement fields.
- confirm: mode="confirm", explicit child_id, proposal_id and confirmed Boolean. It never invokes OpenAI. A fresh transport request UUID identifies this decision; uncertain retries reuse that UUID and the exact original command. The proposal itself is already bound to actor, target and revision.

HTTP 200 statuses:

- recorded: event_id, child_id and server-authored message after transactional persistence. isPersisted requires both IDs. A replay adds replayed=true and neutral wording about current details.
- needs_confirmation: proposal_id, child_id and a before/after message. The actual record is unchanged. App/Siri must request approval before sending confirmed=true. Cancel/silence never means approval.
- needs_clarification: a request for a new complete named description or missing information; no partial event.
- rejected: informative unsaved/unchanged outcome, including future events, expiry/staleness and interpretation failure. Provider errors/raw model explanations are not returned.

HTTP errors preserve the pending command when the outcome is uncertain. 401 requires sign-in, 403 rejects anonymous sessions, 404 hides inaccessible targets, 409 detects conflicting request IDs, 413/415 reject malformed transport, 422 rejects invalid manual data, 429 limits extraction attempts, and 503 means persistence/access could not be confirmed. A failed write is never relabelled as a definite unsaved interpretation failure.

Structured extraction uses a closed schema of action/name/value/time fields, with all unrelated fields null. Absolute clock times are returned as local `absolute_local` / `end_absolute_local` values without a suffix; deterministic code resolves phone-captured offsets. DST overlaps/gaps ask for clarification. Questions, negations, examples and hypotheticals do not create events. The model may request only the finite validated action set and cannot execute SQL.

## Additional validation

Extracted feeding/weight/correction quantities must agree with numeric or English-word amounts/units in the supplied text. Common mL letter forms are recognized. Ambiguity clarifies; whole-bottle leftover needs an explicit consumed-total correction. Old unsafe zero proposals cannot apply.

Date-only weight extraction uses time_kind=date, absolute_local=YYYY-MM-DD and other time fields null. The payload includes measurement_date and an internal occurred_at day anchor. Other event types cannot use date-only time. Common explicit English/ISO dates must agree with interpreted weight/milestone dates. Milestone titles/notes must be extractively grounded in the submitted words. This is not a complete date parser or a repair of Siri transcription.

## Legacy endpoint

`POST /functions/v1/record-event` remains for older pending entries and shares domain validators with the current handler. It requires the same headers and authenticated-family checks. Its closed body contains request_id, child_id, reference_at, source, locale=en, mode=text/manual, optional time_zone and text or event. Manual events specify event_type, occurred_at, volume_ml, diaper_kind and weight_kg with unrelated fields null. New clients retain absent timezone fields when replaying older requests to preserve hashes.

It returns recorded with a persisted event row, replayed flag and server-authored message, or needs_clarification/rejected without saving. Future/unsupported/interpretation-unavailable outcomes have informative static messages. Uncertain writes remain errors requiring the original pending ID. Limits are the same 8 KiB body/1,000-character text; source is siri/text/manual, feeding up to 2,000 mL (two decimals), weight up to 100 kg (three decimals), diapers wet/dirty/mixed. These are integrity bounds, not clinical guidance. Both functions remain deployed with verify_jwt=true.
