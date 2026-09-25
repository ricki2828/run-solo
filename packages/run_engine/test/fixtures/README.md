# Golden fixtures (plan §5, §12)

Two kinds so the tests are not tautological:

**(a) `synthetic/`** — traces from `TraceGenerator` (`lib/src/synthetic/trace_generator.dart`)
with analytic ground truth. Each file holds `spec` (name in `SyntheticSpecs.all`), `run`
(the run file as the app stores it, schema 2) and `expected` (rep paces, avg work pace,
recovery pace, fade, spread, interrupted reps, lap consistency, rescue edits and the
run-1 headline, all computed from the segment list, never from the engine).
Regenerate after any generator change with `dart run tool/gen_fixtures.dart`; the drift
test in `golden_fixtures_test.dart` fails until you do.

| Fixture | Case |
|---|---|
| `easy_free_run` | 30 min free run (mode `free`, no laps), HR |
| `laps_run_manual_clean_hr` | the `four_by_four_manual_clean_hr` trace recorded as a Laps run (§18.2): lap table, no verdict; a 4x4 override reproduces the by-feel verdict |
| `four_by_four_manual_clean[_hr]` | by-feel 4x4, manual laps, no preset, per-rep speeds differ (fade 6 s) |
| `four_by_four_missed_press` | rep 2 work/recovery merged by a missed LAP; `rescue_edits` splits it |
| `preset_4x4_auto_standard` / `preset_4x4_manual_standard` | same trace, auto vs manual laps → identical verdict |
| `preset_3x4_recovery_2_00`, `preset_4x4_recovery_3_30`, `preset_6x4_recovery_5_00` | every recovery boundary and rep bound (§17 B5) |
| `preset_5x4_recovery_2_00_missing_final_recovery` | last recovery missing is tolerated |
| `preset_4x4[_manual]_ends_after_final_recovery` | 4 reps + 4 recoveries, stopped right after the last recovery, no cool-down (founder field test 25-Sep): complete 4x4, BASELINE SET |
| `gps_dropout_rep2`, `pause_mid_rep3`, `kill_resume_gap_rep2` | one `interrupted` rep each → NO VERDICT |
| `noisy_gps_phone_jitter` | 3 m AR(1) jitter, 5 % bad-accuracy samples: verdict still given, wider tolerance |
| `very_noisy_gps_no_verdict` | 35 % bad-accuracy → `noisy`, no verdict |
| `treadmill_indoor` | no fixes → INDOOR RUN, HR only |
| `four_by_four_no_laps_speed_fallback` | no laps → reps from the speed stream |
| `preset_work_cut_short_inconsistent` | rep 2 at 3:20 → `lapsInconsistent` with the fix-laps copy |
| `preset_rep1_cut_short`, `preset_last_rep_cut_short`, `preset_recovery1_cut_short` | §6 edge phases: flagged, never relabelled warm-up/cool-down |
| `preset_work_4_30_accepted`, `preset_work_3_30_accepted`, `preset_recovery_edges_accepted` | preset ±30 s edges accepted |
| `preset_work_4_31_flagged`, `preset_work_3_29_flagged`, `preset_recovery_3_31_flagged` | 1 s past the tolerance → flagged |
| `pause_8s_in_rep3`, `pause_15s_in_rep3` | short pauses: standstill excluded from pace, never "GPS dropped" |
| `gps_lag_12s` | lag equal to the trim: exact only because the trim exists |
| `preset_4x4_hr_step` | step HR profile with analytic mean/peak HR, zone time and m/beat |
| `warmup_2_15_clean`, `final_recovery_truncated_2_20` | a short warm-up / a run ending inside the final recovery are never phases |
| `pause_moved_while_paused` | writer that kept accumulating dist while the runner walked during a pause; excluded |

**`contract/`** — real Kotlin `RunFile.fromReplay` output copied verbatim from
`android/core-jvm/src/test/fixtures/contract/` (CI `diff -r`s the two copies, subdirs
included). Schema-2 files sit at the top level; the four Phase-1 schema-1 files are frozen
read-only under `contract/schema1/` (§18.7) and must decode with v1 `free` → `laps`.

**(b) `real/`** — the founder's 4x4s converted via `TcxImporter`/`GpxImporter` (they import
as `laps`, never 4x4 by lap count, so each carries a sidecar `run_type_override: fourByFour`), checked
against an independent reading (stopwatch / second-device splits). Not yet populated:
needs the first real runs (plan §13 P0 verify).
