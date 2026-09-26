import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
import '../platform/gateway.dart';
import '../state/settings.dart';
import '../theme/theme.dart';

/// The GOAL chip's subtitle: the picked goal ("10K", "30 min", "12.3 km",
/// "7.5 mi", the event's own name from `kEventNames`).
String goalLabel(AppSettings s) {
  final g = GoalChoice.byId(s.goalId);
  if (g == null) return 'Distance or time';
  if (g.id == GoalChoice.eventId) return kEventNames.parkrun;
  return s.goalName!;
}

/// "12.3" or "12,3" in the runner's units, to 0.1 km or 0.1 mi → whole
/// metres within the engine's limits; null when it is not a number or out
/// of range.
int? parseGoalDistance(String text, Units units) {
  final v = double.tryParse(text.trim().replaceAll(',', '.'));
  if (v == null || !v.isFinite) return null;
  final tenths = (v * 10).round() / 10;
  final m = units == Units.mi
      ? (tenths * GoalChoice.metresPerMile).round()
      : (tenths * 1000).round();
  if (m < engine.SessionSpec.goalMinMetres ||
      m > engine.SessionSpec.goalMaxMetres) {
    return null;
  }
  return m;
}

/// "45" (minutes) or "1:15" (h:mm) → seconds within the engine's limits;
/// null otherwise.
int? parseGoalMinutes(String text) {
  final t = text.trim();
  final hm = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(t);
  final int? minutes;
  if (hm != null) {
    final m = int.parse(hm.group(2)!);
    minutes = m < 60 ? int.parse(hm.group(1)!) * 60 + m : null;
  } else {
    minutes = int.tryParse(t);
  }
  if (minutes == null) return null;
  final s = minutes * 60;
  if (s < engine.SessionSpec.goalMinSeconds ||
      s > engine.SessionSpec.goalMaxSeconds) {
    return null;
  }
  return s;
}

/// GOAL (plan §G): Distance | Time, then the goal chips (G1's names and
/// specs), Custom last. Every chip is at least 56 dp tall and its text
/// 15 sp. A picked Custom shows its value on the chip.
class GoalPicker extends StatelessWidget {
  const GoalPicker({
    super.key,
    required this.settings,
    required this.onPick,
    required this.onCustom,
  });
  final AppSettings settings;
  final ValueChanged<String> onPick;

  /// A new custom value: metres for distance, seconds for time.
  final void Function({int? metres, int? seconds}) onCustom;

  @override
  Widget build(BuildContext context) {
    final goalId = settings.goalId;
    final picked = GoalChoice.byId(goalId);
    final byDistance = picked?.distance ?? true;
    final list = byDistance ? GoalChoice.distances : GoalChoice.times;
    Widget toggle(String label, bool on, List<GoalChoice> to) => Expanded(
      child: _Choice(
        key: ValueKey('goal-${label.toLowerCase()}'),
        label: label,
        selected: on,
        onTap: on ? null : () => onPick(to.first.id),
      ),
    );
    return Column(
      key: const ValueKey('goal-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            toggle('Distance', byDistance, GoalChoice.distances),
            const SizedBox(width: Space.x8),
            toggle('Time', !byDistance, GoalChoice.times),
          ],
        ),
        const SizedBox(height: Space.x12),
        Wrap(
          spacing: Space.x8,
          runSpacing: Space.x8,
          children: [
            for (final g in list)
              _Choice(
                key: ValueKey('goal-${g.id}'),
                // A picked Custom shows its value; tapping it again edits.
                label: g.id == GoalChoice.eventId
                    ? kEventNames.parkrun
                    : g.custom && g.id == goalId
                    ? goalLabel(settings)
                    : g.label,
                selected: g.id == goalId,
                semanticsLabel: g.custom && g.id == goalId
                    ? 'Custom, ${goalLabel(settings)}, tap to change'
                    : null,
                // Custom opens its entry at once (the last value stays
                // picked if the sheet is dismissed).
                onTap: () {
                  if (g.id != goalId) onPick(g.id);
                  if (g.custom) _editCustom(context, g.distance);
                },
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _editCustom(BuildContext context, bool distance) async {
    final v = await showCustomGoalSheet(
      context,
      distance: distance,
      units: settings.units,
      current: distance
          ? settings.goalCustomMetres
          : settings.goalCustomSeconds,
    );
    if (v == null) return;
    distance ? onCustom(metres: v) : onCustom(seconds: v);
  }
}

/// Custom goal entry: km or miles to one decimal (the runner's units), or
/// minutes ("45", "1:15"). Returns metres or seconds, null when dismissed.
Future<int?> showCustomGoalSheet(
  BuildContext context, {
  required bool distance,
  required int current,
  Units units = Units.km,
}) {
  final mi = units == Units.mi;
  final unit = mi ? 'mi' : 'km';
  final text = TextEditingController(
    text: distance
        ? (current / (mi ? GoalChoice.metresPerMile : 1000)).toStringAsFixed(1)
        : current % 3600 == 0 || current < 3600
        ? '${current ~/ 60}'
        : '${current ~/ 3600}:${(current % 3600 ~/ 60).toString().padLeft(2, '0')}',
  );
  String? error;
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        final t = Theme.of(context).extension<RunSoloTokens>()!;
        void save() {
          final v = distance
              ? parseGoalDistance(text.text, units)
              : parseGoalMinutes(text.text);
          if (v == null) {
            setSheet(
              () => error = distance
                  ? (mi ? 'Pick 0.1 to 62.1 mi.' : 'Pick 0.1 to 100 km.')
                  : 'Pick 1 minute to 24 hours, like 45 or 1:15.',
            );
            return;
          }
          Navigator.of(context).pop(v);
        }

        return Padding(
          padding: EdgeInsets.only(
            left: Space.screenGutter,
            right: Space.screenGutter,
            top: Space.x24,
            bottom: MediaQuery.of(context).viewInsets.bottom + Space.x24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                distance ? 'CUSTOM DISTANCE' : 'CUSTOM TIME',
                style: RunSoloType.title28,
              ),
              const SizedBox(height: Space.x8),
              Text(
                distance
                    ? 'In $unit, to one decimal. Each distance gets its own '
                          'board.'
                    : 'In minutes, or hours and minutes like 1:15. Each time '
                          'gets its own board.',
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x16),
              TextField(
                key: const ValueKey('goal-custom-field'),
                controller: text,
                autofocus: true,
                keyboardType: distance
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.datetime,
                style: RunSoloType.display44,
                decoration: InputDecoration(
                  suffixText: distance ? unit : 'min',
                  errorText: error,
                  errorMaxLines: 3,
                ),
                onSubmitted: (_) => save(),
              ),
              const SizedBox(height: Space.x16),
              FilledButton(
                key: const ValueKey('goal-custom-save'),
                onPressed: save,
                child: const Text('SAVE'),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.semanticsLabel,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56, minWidth: 72),
          padding: const EdgeInsets.symmetric(horizontal: Space.x16),
          decoration: BoxDecoration(
            color: selected ? t.inkPrimary : t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.button),
            border: Border.all(color: selected ? t.inkPrimary : t.lineHair),
          ),
          // Sized to its label (a Wrap chip), centred in the 56 dp height.
          child: Align(
            widthFactor: 1,
            child: Text(
              label,
              style: RunSoloType.body15.copyWith(
                color: selected ? t.bgBase : t.inkPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
