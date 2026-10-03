/// Stored on every verdict so recomputes reproduce (plan §5). Bump on any change
/// to metrics, trimming, floor/band constants or verdict wording.
///
/// Founder decision (25-Sep-2026): on a bump every past verdict is
/// RECALCULATED; the frozen one is kept only as `verdict_history`. A frozen
/// verdict is authoritative only while its `engine_version` equals this
/// value and its `inputs_key` still matches the sidecar (`RunEngine.analyze`);
/// overrides and fix-laps edits always apply to the recompute.
///
/// 2: D3 max-HR resolver (observed beats typed, 190 fallback) moves every
///    HR zone and time-in-zone; sustained-30 s rule for the observed max.
/// 3: Phase 3 I3: every Intervals session judged like with like (step
///    detection, metric per session kind, floor per comparison key, rep time
///    for distance reps, D4 note). Every Norwegian 4x4 verdict keeps its
///    exact words (migration golden); the bump re-freezes them once without
///    a history line (same text).
/// 4: Phase 3 K1: a parkrun with no lap boundary gets a verdict (it had
///    none), parkrun copy takes the flavour's event name, courses key the
///    comparison, and a plausible official time replaces the GPS finish.
///    Every other verdict keeps its words (re-frozen without history).
///
/// 5: True Pace. Every pace a verdict compares is the pace with the hills
///    (Minetti 2002) and the heat (Hadley table) taken out, always on (the
///    "Compare heat-adjusted paces" setting is retired). A flat, cool run, or
///    one with no elevation or weather, compares on its actual pace exactly as
///    before; only a hilly or hot one reads differently. Priors enter at their
///    own True Pace, so runs without weather are no longer left out.
const int engineVersion = 5;
