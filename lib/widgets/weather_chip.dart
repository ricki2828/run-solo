/// Weather chip on a run's result (design addendum A6): the hour's weather,
/// the raw number first ("the honest number leads") and its heat-adjusted
/// twin, never in Arc (an adjustment is not a win). Steady runs use the
/// Hadley table ([engine.HeatModel]); a Cooper test uses its own WBGT slope
/// ([engine.CooperHeat], HV1). Every string that carries an adjusted number
/// says it is an estimate (WARN-4 lint, [engine.carriesEstimateMarker]).
library;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import '../screens/settings_screen.dart' show kOpenMeteoAttribution;
import '../theme/theme.dart';

enum WeatherChipState { pending, unavailable, cool, tooHot, adjusted }

/// Everything the chip shows, as plain strings (tests and the lint read
/// these, not the widget tree).
@immutable
class WeatherChipView {
  const WeatherChipView({
    required this.state,
    this.conditions,
    this.rawLabel,
    this.raw,
    this.adjustedLabel,
    this.adjusted,
    this.note,
    this.sheet = const [],
  });

  final WeatherChipState state;

  /// "28 °C · 62% · dew point 21 °C"; null while pending / unavailable.
  final String? conditions;
  final String? rawLabel;

  /// "4:41 /km" (or "2.85 km" for a Cooper test).
  final String? raw;
  final String? adjustedLabel;
  final String? adjusted;

  /// The state line: "Weather: fetching when online", "No heat adjustment",
  /// "+4.7% for heat, a rough estimate", …
  final String? note;

  /// The ⓘ sheet's paragraphs; empty = no ⓘ.
  final List<String> sheet;

  /// Every user-facing string, for the copy lints.
  List<String> get strings => [
    for (final s in [conditions, rawLabel, raw, adjustedLabel, adjusted, note])
      if (s != null) s,
    ...sheet,
  ];
}

const String kWeatherPending = 'Weather: fetching when online';
const String kWeatherUnavailable = 'Weather unavailable';
const String kNoHeatAdjustment = 'No heat adjustment';
const String kTooHotRawOnly = 'Too hot to compare, raw only';
const String kHeatAdjLabel = 'HEAT-ADJ EST.';

/// The ⓘ sheet for a steady run (A6, plan §18.5).
const List<String> kSteadyHeatSheet = [
  'A rough estimate of your pace on a cool day, from the Hadley '
      'temperature and dew point table (Maximum Performance Running, 2013). '
      'Hot, humid air slows you; cold never earns a bonus.',
  'Built for steady running. Short hard reps are probably less affected.',
  'Your verdict always uses the raw pace.',
  '$kOpenMeteoAttribution (CC BY 4.0)',
];

/// The ⓘ sheet for a Cooper test (HV1 copy).
const List<String> kCooperHeatSheet = [
  engine.CooperHeat.disclosure,
  engine.CooperHeat.caveat,
  'Your result always uses the raw distance.',
  '$kOpenMeteoAttribution (CC BY 4.0)',
];

/// The chip for a run, or null when there is nothing to say: an indoor run
/// (weather `skipped`), or no weather yet with "Weather for each run" off.
WeatherChipView? weatherChipView({
  required engine.RunAnalysis analysis,
  required Units units,
  required bool fetchEnabled,
}) {
  final w = analysis.weather;
  // Indoor: nothing is fetched (the queue marks it skipped), so never
  // "fetching".
  if (analysis.indoor) return null;
  if (w == null) {
    return fetchEnabled
        ? const WeatherChipView(
            state: WeatherChipState.pending,
            note: kWeatherPending,
          )
        : null;
  }
  final cooper = analysis.mode == engine.RunMode.cooper;
  final unit = units == Units.mi ? '/mi' : '/km';
  final rawPace = cooper
      ? null
      : analysis.intervals?.avgWorkPaceSecPerKm ??
            analysis.freeRun.avgPaceSecPerKm;
  final metres = analysis.freeRun.distanceM;
  final raw = cooper
      ? Fmt.distance(metres, units)
      : rawPace == null
      ? null
      : '${Fmt.pace(rawPace, units)} $unit';
  switch (w.status) {
    case engine.WeatherStatus.skipped:
      return null;
    case engine.WeatherStatus.pending:
      return const WeatherChipView(
        state: WeatherChipState.pending,
        note: kWeatherPending,
      );
    case engine.WeatherStatus.failed:
      return WeatherChipView(
        state: WeatherChipState.unavailable,
        rawLabel: raw == null ? null : 'RAW',
        raw: raw,
        note: kWeatherUnavailable,
      );
    case engine.WeatherStatus.ok:
      break;
  }
  final tempC = w.tempC, dewC = w.dewPointC;
  if (tempC == null || dewC == null) {
    // `ok` always carries both (W1); treat a short record as not there yet.
    return const WeatherChipView(
      state: WeatherChipState.pending,
      note: kWeatherPending,
    );
  }
  final conditions = [
    '${tempC.round()} °C',
    if (w.rh != null) '${w.rh!.round()}%',
    'dew point ${dewC.round()} °C',
  ].join(' · ');
  final sheet = cooper ? kCooperHeatSheet : kSteadyHeatSheet;
  final (tooHot, fraction) = cooper
      ? (() {
          final c = engine.CooperHeat.of(w)!;
          return (c.tooHot, c.fraction);
        })()
      : (() {
          final h = engine.HeatModel.of(tempC: tempC, dewPointC: dewC);
          return (h.tooHot, h.fraction);
        })();
  if (tooHot) {
    return WeatherChipView(
      state: WeatherChipState.tooHot,
      conditions: conditions,
      rawLabel: raw == null ? null : 'RAW',
      raw: raw,
      note: kTooHotRawOnly,
      sheet: sheet,
    );
  }
  if (fraction == null || fraction <= 0 || raw == null) {
    return WeatherChipView(
      state: WeatherChipState.cool,
      conditions: conditions,
      rawLabel: raw == null ? null : 'RAW',
      raw: raw,
      note: kNoHeatAdjustment,
      sheet: sheet,
    );
  }
  final adjusted = cooper
      ? Fmt.distance(metres / (1 - fraction), units)
      : '${Fmt.pace(rawPace! * (1 - fraction), units)} $unit';
  return WeatherChipView(
    state: WeatherChipState.adjusted,
    conditions: conditions,
    rawLabel: 'RAW',
    raw: raw,
    adjustedLabel: kHeatAdjLabel,
    adjusted: adjusted,
    note: '+${(fraction * 100).toStringAsFixed(1)}% for heat, a rough estimate',
    sheet: sheet,
  );
}

class WeatherChip extends StatelessWidget {
  const WeatherChip({super.key, required this.view});
  final WeatherChipView view;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final v = view;
    final noteColor = v.state == WeatherChipState.tooHot
        ? t.semWarn
        : t.inkSecondary;
    final figure = RunSoloType.body15.copyWith(
      color: t.inkPrimary,
      fontWeight: FontWeight.w500,
      fontFeatures: RunSoloType.tabular,
    );
    Widget column(String label, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: RunSoloType.micro11.copyWith(color: t.inkMuted)),
        const SizedBox(height: 2),
        Text(value, style: figure),
      ],
    );
    return Container(
      key: const ValueKey('weather-chip'),
      width: double.infinity,
      padding: const EdgeInsets.all(Space.x12),
      decoration: BoxDecoration(
        color: t.bgRaised,
        borderRadius: BorderRadius.circular(Radii.button),
        border: Border.all(color: t.lineHair),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (v.conditions != null) ...[
            Text(
              v.conditions!,
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
            const SizedBox(height: Space.x8),
          ],
          if (v.raw != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.x8),
              child: Row(
                children: [
                  column(v.rawLabel!, v.raw!),
                  if (v.adjusted != null) ...[
                    const SizedBox(width: Space.x24),
                    column(v.adjustedLabel!, v.adjusted!),
                  ],
                ],
              ),
            ),
          Row(
            children: [
              if (v.state == WeatherChipState.pending) ...[
                // Static, not a spinner: a fetch can wait for hours offline,
                // and nothing on a result screen should animate forever.
                Icon(Icons.cloud_queue, size: 16, color: t.inkSecondary),
                const SizedBox(width: Space.x8),
              ],
              Flexible(
                child: Text(
                  v.note!,
                  key: const ValueKey('weather-note'),
                  style: RunSoloType.label13.copyWith(color: noteColor),
                ),
              ),
              if (v.sheet.isNotEmpty)
                IconButton(
                  key: const ValueKey('weather-info'),
                  onPressed: () => _showSheet(context, v.sheet),
                  icon: Icon(Icons.info_outline, color: t.inkSecondary),
                  iconSize: 18,
                  tooltip: 'About the heat adjustment',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _showSheet(BuildContext context, List<String> paragraphs) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.screenGutter),
        child: Column(
          key: const ValueKey('weather-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'HEAT ADJUSTMENT',
              style: RunSoloType.title28.copyWith(color: t.inkPrimary),
            ),
            for (final p in paragraphs) ...[
              const SizedBox(height: Space.x12),
              Text(
                p,
                style: RunSoloType.body15.copyWith(
                  color: p == paragraphs.last ? t.inkSecondary : t.inkPrimary,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
