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
const int engineVersion = 2;
