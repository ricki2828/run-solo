import '../model/run_file.dart';
import 'format.dart';

/// Which way the card's detail line points (A10.1): ▲ ahead, ▼ behind,
/// no glyph when level.
enum LiveCardDirection { ahead, behind, level }

/// The live overlay card's three lines (Phase 4 §3.2, design brief A10.1),
/// from a native `CompareEvent`'s figures. The engine owns the wording; the
/// app only lays it out. Plain, casual, no em dashes; a VO2 figure says
/// "est." and a predicted time says "(predicted)".
class LiveCard {
  const LiveCard({
    required this.rank,
    required this.eyebrow,
    required this.detail,
    required this.direction,
  });

  /// The big line (Barlow 44 / 36 sp): "#2 OF 7", "12 s BEHIND".
  final String rank;

  /// Archivo 13, uppercase, up to two lines: "ON PACE FOR · 5Ks".
  final String eyebrow;

  /// Archivo 17, one line, without the glyph: "6 s behind your best".
  final String detail;
  final LiveCardDirection direction;

  /// TalkBack label: every line, with the glyph said as a word.
  String get semantics => '$rank. $eyebrow. $detail.';

  /// The card for one compare. [kind] is `CompareEvent.kind` (`distance`,
  /// `intervals`, `cooper` or `target`); [index] the km, rep or minute;
  /// [rank] this run's place among [of] (itself included). [targetM] is the
  /// target distance for a `target` compare (the timed 5 km's 5000), to say
  /// the projected finish. Null for an unknown kind or a missing figure.
  static LiveCard? of({
    required String kind,
    required String boardLabel,
    required int index,
    required int rank,
    required int of,
    int? deltaMs,
    double? deltaSecPerKm,
    double? deltaVo2,
    double? value,
    double? targetM,
    Units units = Units.km,
  }) {
    final many = of > 2;
    final label = boardLabel.toUpperCase();
    switch (kind) {
      case 'distance':
        if (deltaMs == null) return null;
        final s = _seconds(deltaMs);
        final dir = _dir(s == 0 ? 0 : deltaMs);
        if (many) {
          return LiveCard(
            rank: '#$rank OF $of',
            eyebrow: 'ON PACE FOR · ${_plural(label)}',
            detail: switch (dir) {
              LiveCardDirection.level => 'Level with your best',
              LiveCardDirection.ahead => '$s s ahead of your best',
              LiveCardDirection.behind => '$s s behind your best',
            },
            direction: dir,
          );
        }
        return LiveCard(
          rank: _gap(s, dir),
          eyebrow: 'VS YOUR ONLY OTHER $label',
          detail: 'at $index km',
          direction: dir,
        );
      case 'intervals':
        if (deltaSecPerKm == null) return null;
        final per = PaceFormat.toUnit(deltaSecPerKm, units).round();
        final unit = PaceFormat.unitLabel(units);
        final dir = _dir(per.toDouble());
        final reps = index == 1 ? '1 REP' : '$index REPS';
        final gap = per.abs();
        return LiveCard(
          rank: many ? '#$rank OF $of' : _gap(gap, dir),
          eyebrow: many ? 'AFTER $reps · $label' : 'AFTER $reps · VS YOUR LAST',
          detail: switch (dir) {
            LiveCardDirection.level => 'Level with your best so far',
            LiveCardDirection.ahead => '$gap s/$unit up on your best',
            LiveCardDirection.behind => '$gap s/$unit off your best',
          },
          direction: dir,
        );
      case 'cooper':
        if (value == null) return null;
        final vo2 = value.round();
        final gap = (deltaVo2 ?? 0).round();
        final dir = _dir(-gap.toDouble());
        return LiveCard(
          rank: many
              ? '#$rank OF $of'
              : switch (dir) {
                  LiveCardDirection.level => 'LEVEL',
                  LiveCardDirection.ahead => 'UP ${gap.abs()}',
                  LiveCardDirection.behind => 'DOWN ${gap.abs()}',
                },
          eyebrow: many ? 'HEADING FOR · 12-MIN TESTS' : 'VS YOUR LAST TEST',
          detail: 'VO2 est. $vo2',
          direction: many ? LiveCardDirection.level : dir,
        );
      case 'distanceInTime':
        // A time goal (§G) races its time board by distance: [value] is the
        // projected distance at the goal time (m), [index] the minute.
        if (value == null) return null;
        final dist = units == Units.mi
            ? '${(value / PaceFormat.metresPerMile).toStringAsFixed(1)} mi'
            : '${(value / 1000).toStringAsFixed(1)} km';
        return LiveCard(
          rank: '#$rank OF $of',
          eyebrow: 'ON PACE FOR · $label',
          detail: 'About $dist at the finish',
          direction: LiveCardDirection.level,
        );
      case 'target':
        if (deltaMs == null || value == null) return null;
        final s = _seconds(deltaMs);
        final dir = _dir(s == 0 ? 0 : deltaMs);
        final predicted = boardLabel == 'predicted';
        final target = PaceFormat.mmss(value / 1000);
        final m = targetM;
        final projected = m == null || index <= 0
            ? null
            : value + deltaMs * m / (index * 1000);
        return LiveCard(
          rank: _gap(s, dir),
          eyebrow: predicted
              ? 'VS PREDICTED $target'
              : 'VS YOUR TARGET $target',
          detail: projected == null
              ? 'at $index km'
              : 'On pace for ${PaceFormat.mmss(projected / 1000)}'
                    '${predicted ? ' (predicted)' : ''}',
          direction: dir,
        );
    }
    return null;
  }

  /// Whole seconds of a ms delta, as the voice rounds them.
  static int _seconds(num ms) => (ms.abs() / 1000).round();

  /// Negative = ahead (time or pace below the best).
  static LiveCardDirection _dir(num delta) => delta == 0
      ? LiveCardDirection.level
      : delta < 0
      ? LiveCardDirection.ahead
      : LiveCardDirection.behind;

  /// "5Ks" (the design's spelling) but "HILL PARKRUNS".
  static String _plural(String label) => label == 'HALF'
      ? 'HALF MARATHONS'
      : RegExp(r'\dK$').hasMatch(label)
      ? '${label}s'
      : '${label}S';

  static String _gap(int s, LiveCardDirection dir) => switch (dir) {
    LiveCardDirection.level => 'LEVEL',
    LiveCardDirection.ahead => '$s s AHEAD',
    LiveCardDirection.behind => '$s s BEHIND',
  };
}
