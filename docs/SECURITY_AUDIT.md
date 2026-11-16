# Security model and verification

Build 15 deployed baseline (November 15, 2026): five applied immutable migrations; both Edge Functions have `verify_jwt=true`. Local migration/RLS/concurrency tests, source/bundle scans and recorded live checks support the boundaries below. This is an implementation review, not a claim that every possible attack or speech input has been tested.

## Authentication and authorization

The gateway check is defense in depth. Both handlers independently verify Bearer credentials with the configured project’s `/auth/v1/user`, validate the identity and reject anonymous Auth sessions before extraction/writes. Decoding an unverified JWT or accepting a public API key is not authentication. Auth errors stop processing; do not switch off verification as a troubleshooting shortcut. [Supabase gateway guidance](https://supabase.com/docs/guides/functions/auth-headers)

Database requests forward the verified caller JWT with a public project key, keeping RLS active. Child authorization and replay lookup precede new extraction. No service-role key is required by application runtime. Invalid/inaccessible children do not reach OpenAI. Upstream requests reject redirects so credentials are not forwarded elsewhere.

All nine public tables and both private tables enable RLS. Public family reads require membership; proposals/receipts are restricted to their actor. Application roles cannot mutate tables directly. Event-category views use `security_invoker=true`. Security-definer RPCs have empty search paths, qualified relations, explicit authentication/membership checks and restricted grants. Private validators and the moved `private.execute_care_conversation_v14` implementation are not directly callable by application roles; the public wrapper retains authorization and captured-time checks. All 12 hosted postflight checks passed after the fifth migration. SQL constraints enforce payload type, bounds, precision and required fields.

Authenticated users may call the authorized data-entry RPCs directly; this is intentional manual-entry functionality, not an Edge-only secret API. `input_source` is caller-declared metadata, not cryptographic proof of Siri. Privileged database administrators can bypass RLS and must protect their access separately.

Invites use 192-bit random tokens with only SHA-256 digests stored. A new invite replaces the previous one; codes expire after 24 hours and are single-use. Family locking enforces two parents; membership is unique per user.

## Interpretation and consistency

OpenAI receives event text, eligible baby names, reference/timezone context and a closed extraction schema. It receives no user passwords, database credentials, SQL access or trusted actor identity. The handler validates finite actions, names, grounded quantities, supported explicit dates, milestone wording and past time before constrained RPCs. A schema-valid answer is not proof that a sentence describes a real event. A bounded live question returned a read-only answer and a negated 120 mil statement saved nothing; hypothetical rejection remains physically unverified; see [release status](RELEASE.md).

Extraction is limited to 30 attempts per account per minute. Saved requests replay before new extraction/budget. This is a small-app limit, not an overall cost cap. Concurrent requests can both incur model cost while persisting only one record.

Stable UUIDs/hashes, unique constraints and per-request/per-child locks make retries idempotent. Confirmation proposals bind actor, target, expiry and expected revision. Build 14 voice selectors resolve only the latest qualifying record and verify an explicitly stated prior feeding amount before proposing a replacement. Every edit/deletion remains a proposal until confirmation. Competing corrections cannot overwrite each other silently. Whole-bottle leftover requires clarification or an explicit consumed-total correction; zero consumption voids the feeding. Write uncertainty is never relabelled as a definitely unsaved interpretation failure. The new finite conversation RPC keeps one outer batch identity with deterministic inner IDs and rolls back all parts on failure. Query operations read authorized stored facts without writing care rows, proposals or receipts; extraction attempts still consume the existing budget. Explicit guide observations have a unique active child/guide ID and never relabel old free-text memories.

## Keys, storage and logging

- Project URL and publishable/legacy anon key are public client configuration. RLS/authentication provide security; key obscurity does not.
- OpenAI credentials exist only in Edge Function secrets. Optional `VT_SUPABASE_PUBLISHABLE_KEY` replaces disabled legacy public keys. `OPENAI_MODEL` is configurable.
- The Xcode guard permits only public client keys and redacts diagnostics; the runtime checks again. `security_checks.py` scans recognized secrets, privileged/session JWTs and private keys. Pattern scanning is a safeguard, not proof no possible credential format exists.
- iOS uses an ephemeral URLSession without disk cache/cookies. Tokens and unresolved commands use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` Keychain storage. Passwords are not retained. Pending text stays locally only while unresolved and remains bound to its original parent through sign-out.
- Raw speech/model outputs are not retained in application database rows or emitted by application logging. OpenAI uses `store=false`; this does not make claims about providers’ independent infrastructure policies. Error messages are static/redacted rather than forwarding provider diagnostics.
- `.gitignore` excludes local xcconfig, .env files, signing material, tools, build/test outputs and caches. Run the source scan and review staged files before every commit. Secrets already exposed elsewhere require separate rotation; deleting a file is not rotation.

## Hosting/signup

RLS alone does not stop a stranger registering a separate family and consuming your OpenAI quota. Bootstrap the intended parents before adding the model secret, then close new-account signup while keeping email login and confirmation enabled. Close signup on your own deployment after bootstrapping the intended parents.

In CLI 3, `[auth] enable_signup=false` controls registration. `[auth.email] enable_signup=false` maps to the entire email provider and breaks existing login. Use scoped configuration diffs, not a full development-config push. A public `/auth/v1/settings` check should show `disable_signup=true`, `external.email=true`, `mailer_autoconfirm=false`. Do not log secret configuration while checking. [Official CLI mapping](https://github.com/supabase/cli/blob/main/packages/config/src/project-config/registry-auth.ts)

For a fresh project, run [preflight](../supabase/preflight.sql), all six migrations in order, then [catalog/privilege verification](../supabase/verify_deployment.sql). Never run local test fixtures on a live project. Local tests reproduce Supabase’s permissive default grants so explicit revokes are exercised. [Test commands](TESTING.md)

The compositional read path uses `read_care_snapshot`, a stable security-invoker RPC with an empty search path and authenticated-only execution. Caller RLS limits authorized records. Invalid/incomplete snapshots fail explicitly rather than supplying fabricated totals; query answers create no care rows, receipts or proposals.
