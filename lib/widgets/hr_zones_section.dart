import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../state/hr_zone_choice.dart';
import '../state/max_hr.dart';
import '../state/settings.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';

/// Settings → Heart rate zones: the method (share of max, heart-rate
/// reserve, custom), the resulting bpm ranges in zone colours, and the
/// inputs the method needs. The max HR itself is entered above it.
class HrZonesSection extends StatelessWidget {
  const HrZonesSection({
    super.key,
    required this.settings,
    required this.now,
    required this.onChange,
    this.restingSuggestion,
  });

  final AppSettings settings;
  final DateTime now;

  /// Applies an edit to the stored settings.
  final Future<void> Function(AppSettings Function(AppSettings)) onChange;

  /// The lowest resting-HR proxy from the runner's own runs, offered as a
  /// one-tap value for the reserve method (a rough estimate, never applied
  /// on its own). Null = none.
  final int? restingSuggestion;

  static String methodName(engine.HrZoneMethod m) => switch (m) {
    engine.HrZoneMethod.percentMax => '% of max HR',
    engine.HrZoneMethod.reserve => 'Heart rate reserve',
    engine.HrZoneMethod.custom => 'Custom',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = settings;
    final maxHr = MaxHr.resolve(s, now).maxHr;
    final zones = HrZoneChoice.resolve(s, now);
    final reserveMissing =
        s.hrZoneMethod == engine.HrZoneMethod.reserve &&
        zones.method != engine.HrZoneMethod.reserve;
    return Column(
      key: const ValueKey('hr-zones-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Space.x24, bottom: Space.x8),
          child: Text(
            'HEART RATE ZONES',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        ),
        RadioGroup<engine.HrZoneMethod>(
          groupValue: s.hrZoneMethod,
          onChanged: (m) {
            if (m == null) return;
            // Custom starts from what the runner has now, so the table is
            // never blank.
            onChange(
              (x) => m == engine.HrZoneMethod.custom && x.customZones == null
                  ? x.copyWith(hrZoneMethod: m, customZones: _bottoms(zones))
                  : x.copyWith(hrZoneMethod: m),
            );
          },
          child: Column(
            children: [
              for (final m in engine.HrZoneMethod.values)
                RadioListTile<engine.HrZoneMethod>(
                  key: ValueKey('hr-method-${m.name}'),
                  value: m,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    methodName(m),
                    style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                  ),
                ),
            ],
          ),
        ),
        if (s.hrZoneMethod == engine.HrZoneMethod.reserve)
          _RestingField(
            settings: s,
            suggestion: restingSuggestion,
            onChange: onChange,
          ),
        if (reserveMissing)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x8),
            child: Text(
              'Add your resting heart rate to use this. Until then zones '
              'follow % of max HR.',
              key: const ValueKey('hr-reserve-prompt'),
              style: RunSoloType.label13.copyWith(color: t.semWarn),
            ),
          ),
        const SizedBox(height: Space.x8),
        if (s.hrZoneMethod == engine.HrZoneMethod.custom)
          _CustomTable(
            key: const ValueKey('custom-table'),
            initial: s.customZones ?? _bottoms(zones),
            maxHr: maxHr,
            onChange: onChange,
          )
        else
          _Ranges(zones: zones, maxHr: maxHr),
        Padding(
          padding: const EdgeInsets.only(top: Space.x12),
          child: Text(
            '% of max ignores resting HR; reserve (used by Whoop, Garmin HRR) '
            'lifts every zone by your resting HR.',
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Space.x8),
          child: Text(
            'The 4x4 band stays 85 to 95 % of max whatever you pick here.',
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
        ),
      ],
    );
  }

  static List<int> _bottoms(engine.HrZones z) => [
    for (var k = 1; k <= 5; k++) z.bottom(k).ceil(),
  ];
}

Color _zoneColour(BuildContext context, int zone) =>
    HrZones.distribution(zone, Theme.of(context).brightness);

/// Read-only bpm ranges per zone, in zone colours.
class _Ranges extends StatelessWidget {
  const _Ranges({required this.zones, required this.maxHr});
  final engine.HrZones zones;
  final int maxHr;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var z = 1; z <= 5; z++)
          _ZoneRow(
            zone: z,
            child: Text(
              _range(zones, z, maxHr),
              key: ValueKey('hr-range-$z'),
              style: RunSoloType.body17.copyWith(
                color: _zoneColour(context, z),
              ),
            ),
          ),
      ],
    );
  }
}

String _range(engine.HrZones zones, int z, int maxHr) {
  final lo = zones.bottom(z).ceil();
  final hi = zones.top(z) ?? maxHr;
  return '$lo–$hi bpm';
}

class _ZoneRow extends StatelessWidget {
  const _ZoneRow({required this.zone, required this.child});
  final int zone;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: _zoneColour(context, zone),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: Space.x12),
          SizedBox(
            width: 104,
            child: Text(
              'Z$zone ${HrZones.name(zone)}',
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: child),
          ),
        ],
      ),
    );
  }
}

class _RestingField extends StatefulWidget {
  const _RestingField({
    required this.settings,
    required this.suggestion,
    required this.onChange,
  });
  final AppSettings settings;
  final int? suggestion;
  final Future<void> Function(AppSettings Function(AppSettings)) onChange;

  @override
  State<_RestingField> createState() => _RestingFieldState();
}

class _RestingFieldState extends State<_RestingField> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.settings.restingHr?.toString() ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _save(String text) {
    if (text.isEmpty) {
      setState(() => _error = null);
      widget.onChange((x) => x.copyWith(clearRestingHr: true));
      return;
    }
    final v = int.tryParse(text);
    if (v == null || !HrZoneRules.validResting(v)) {
      setState(
        () => _error =
            'Between ${HrZoneRules.minResting} and ${HrZoneRules.maxResting} bpm',
      );
      return;
    }
    setState(() => _error = null);
    widget.onChange((x) => x.copyWith(restingHr: v));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final sug = widget.suggestion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('hr-resting-field'),
          controller: _ctl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: RunSoloType.body17.copyWith(color: t.inkPrimary),
          decoration: InputDecoration(
            labelText: 'Resting heart rate (bpm)',
            errorText: _error,
          ),
          onChanged: _save,
        ),
        if (sug != null && widget.settings.restingHr != sug)
          TextButton(
            key: const ValueKey('hr-resting-suggest'),
            onPressed: () {
              _ctl.text = '$sug';
              _save('$sug');
            },
            child: Text('Use $sug from your runs (rough estimate)'),
          ),
      ],
    );
  }
}

/// Editable bottoms for Z1..Z5; each zone's top is the next bottom. A bad
/// table shows its error under the table and is not saved.
class _CustomTable extends StatefulWidget {
  const _CustomTable({
    super.key,
    required this.initial,
    required this.maxHr,
    required this.onChange,
  });
  final List<int> initial;
  final int maxHr;
  final Future<void> Function(AppSettings Function(AppSettings)) onChange;

  @override
  State<_CustomTable> createState() => _CustomTableState();
}

class _CustomTableState extends State<_CustomTable> {
  late final List<TextEditingController> _ctl = [
    for (final v in widget.initial) TextEditingController(text: '$v'),
  ];
  String? _error;

  @override
  void dispose() {
    for (final c in _ctl) {
      c.dispose();
    }
    super.dispose();
  }

  void _edited() {
    final v = [for (final c in _ctl) int.tryParse(c.text)];
    if (v.any((e) => e == null)) {
      setState(() => _error = 'Fill in every zone');
      return;
    }
    final bottoms = v.cast<int>();
    final err = engine.HrZones.validate(
      bottoms.sublist(1),
      z1Floor: bottoms[0],
    );
    setState(() => _error = err);
    if (err == null) {
      widget.onChange((x) => x.copyWith(customZones: bottoms));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    int? next(int i) => i + 1 < 5 ? int.tryParse(_ctl[i + 1].text) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 5; i++)
          _ZoneRow(
            zone: i + 1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 64,
                  child: TextField(
                    key: ValueKey('hr-custom-${i + 1}'),
                    controller: _ctl[i],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.end,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: RunSoloType.body17.copyWith(
                      color: _zoneColour(context, i + 1),
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'bpm',
                    ),
                    onChanged: (_) => _edited(),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text(
                    ' – ${i == 4 ? widget.maxHr : (next(i) == null ? '' : next(i)! - 1)}',
                    key: ValueKey('hr-custom-max-${i + 1}'),
                    style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                  ),
                ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.x4),
            child: Text(
              _error!,
              key: const ValueKey('hr-custom-error'),
              style: RunSoloType.label13.copyWith(color: t.semWarn),
            ),
          ),
      ],
    );
  }
}
