# Milestone guide sources

Verified against official sources on **2026-11-14**. The guide is a static, curated selection for birth through age five; it does not download clinical content at runtime. Labels are brief paraphrases, not a reproduction of a complete checklist. Attribution does not imply endorsement by a source organization.

## How to read the ages

CDC checkpoints describe skills that at least 75% of children can demonstrate **by** a stated age. They are neither average first-achievement dates nor deadlines, and the selection is not a validated developmental screen. The Rourke Baby Record (RBR) uses clinician surveillance visits, with checks scheduled after typical acquisition. Its one-month visit items therefore retain a separate `visitSurveillance` meaning.

The app derives chronological age from the birthday and the phone's current calendar date. It shows the current and next checkpoints, keeps earlier checkpoints accessible, and offers all-age browsing. For example, an eight-month-old sees the six-month checkpoint and upcoming nine-month checkpoint. The first-month visit checks are accessible from birth. No checkpoint beyond five years is invented. A missing, invalid, or future birthday produces no guessed age. A premature baby's profile does not provide the dates needed to compute corrected age; the UI explains this and directs parents to their clinician.

## Item provenance

Every entry retains its stable identifier, source-age meaning, and direct source link. All CDC entry labels below use their respective age page as their primary source; only the two-month entries additionally cite the AAP page. RBR supplies four early visit observations. The guide currently has 88 entries (4 RBR and 84 CDC), a deliberately selected subset.

| Stable ID prefix | Source age and meaning | Official source |
| --- | --- | --- |
| `rbr-1m-` | One-month visit surveillance: gaze, loud-noise response, expressing needs, settling with comfort | [Rourke Baby Record 2024, National Guide I, PDF page 1](https://www.rourkebabyrecord.ca/pdf/2024/RBR%202024%20NAT-EN-3vpp-May%2018-BLACK-Feb%209.pdf#page=1) |
| `cdc-2m-` | By two months; 6 selected observations | [CDC two months](https://www.cdc.gov/act-early/milestones/2-months.html) |
| `cdc-4m-` | By four months; 7 observations | [CDC four months](https://www.cdc.gov/act-early/milestones/4-months.html) |
| `cdc-6m-` | By six months; 7 observations | [CDC six months](https://www.cdc.gov/act-early/milestones/6-months.html) |
| `cdc-9m-` | By nine months; 8 observations | [CDC nine months](https://www.cdc.gov/act-early/milestones/9-months.html) |
| `cdc-12m-` | By one year; 7 observations | [CDC one year](https://www.cdc.gov/act-early/milestones/1-year.html) |
| `cdc-15m-` | By fifteen months; 7 observations | [CDC fifteen months](https://www.cdc.gov/act-early/milestones/15-months.html) |
| `cdc-18m-` | By eighteen months; 7 observations | [CDC eighteen months](https://www.cdc.gov/act-early/milestones/18-months.html) |
| `cdc-24m-` | By two years; 7 observations | [CDC two years](https://www.cdc.gov/act-early/milestones/2-years.html) |
| `cdc-30m-` | By thirty months; 7 observations | [CDC thirty months](https://www.cdc.gov/act-early/milestones/30-months.html) |
| `cdc-36m-` | By three years; 7 observations | [CDC three years](https://www.cdc.gov/act-early/milestones/3-years.html) |
| `cdc-48m-` | By four years; 7 observations | [CDC four years](https://www.cdc.gov/act-early/milestones/4-years.html) |
| `cdc-60m-` | By five years; 7 observations | [CDC five years](https://www.cdc.gov/act-early/milestones/5-years.html) |

[AAP developmental milestones](https://www.aap.org/en/patient-care/developmental-surveillance-and-screening-patient-care/developmental-milestones/) independently displays the same two-month observations; it is a secondary citation for that group only. The other labels are derived from individual CDC age pages, rather than reproducing the AAP's full age table. The AAP page reports an update of July 13, 2026; retrieved CDC age pages report May 15, 2026.

The RBR PDF is the 2024 national English edition, revised May 18, 2024, with a February 9, 2025 footer. Its first page distinguishes the early visit columns and describes the surveillance timing. The app includes only the four observations under the one-month visit; it does not assign newborn feeding checks to an acquisition age. [CPS's RBR description](https://cps.ca/en/tools-outils/rourke-baby-record) is linked as Canadian preventive-care context.

[CPS Caring for Kids: feeding in the first year](https://caringforkids.cps.ca/handouts/healthy-living/feeding_your_baby_in_the_first_year) supplies the separately labelled feeding-readiness context around six months. Readiness advice is not a guide checkbox, not a directive to start solids on a birthday, and does not redefine unsupported sitting's CDC nine-month checkpoint. Parents can follow the direct link for the complete guidance.

## Recording and preservation

“Observed today” submits a manual `milestone` command with `guide_id`, the curated title, the phone-local `occurred_on` date, `date_precision: day`, and `is_first: false`. The earlier-date form uses a selected calendar day; it rejects dates before a known birthday or after today. Observing a skill does not assert when it first appeared.

A checkbox follows a persisted milestone's exact `guide_id` for the same child or a successful persisted response for that command's child. Titles, synonyms, and semantic similarity never check an item. In particular, an imported memory saying “learned to sit” is not automatically equated with unsupported sitting. Existing imported memories are read-only inputs here and are never relabelled or assigned guide IDs.

Rapid taps are gated before the network call. An uncertain response does not check an item and retains the original command; “Retry / check recording” resubmits that same request identity. Server uniqueness on the child's active guide ID handles two parents recording the same item. The guide makes no overdue score or daily milestone target.

## Maintenance

When updating this selection, verify the exact source-age column and item, retain provenance and retrieval dates, and keep paraphrases short. Source meaning is part of an ID: change the ID if the underlying skill or checkpoint meaning changes. Review individual-page derived text budgets (under 200 words per CDC page), and keep AAP-, RBR-, and CPS-derived content each under 200 words in total. Do not expand this into a complete republished table. Clinical text is versioned in `Core/MilestoneGuide.swift`; source changes do not silently rewrite saved family memories.
