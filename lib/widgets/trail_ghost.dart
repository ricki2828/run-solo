/// The known-trail readouts on the run screen: how far ahead of (or behind)
/// the best and the last run on this trail, the Off the trail state and the
/// big TURN AROUND card. All of it comes from `RecordingSnapshot.trail`.
library;

import 'package:flutter/material.dart';

import '../platform/platform_api.g.dart' show TrailProgress;
import '../theme/theme.dart';

/// "12 s", "1:05": the size of a gap, never signed.
String trailGap(int ms) {
  final s = (ms.abs() / 1000).round();
  if (s < 60) return '$s s';
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The gap as a signed figure, number first: "+12 s" ahead, "\u22128 s"
/// behind, "+1:05" / "\u22120:42" from a minute. Positive [ms] is ahead.
String trailGapFigure(int ms) {
  final g = trailGap(ms);
  if ((ms.abs() / 1000).round() < 1) return g;
  return '${ms > 0 ? '+' : '\u2212'}$g';
}

/// "12 s ahead of best", "8 s behind last", "Level with best": the spoken
/// form, for the screen reader.
String trailGapLine(int ms, String against) {
  if ((ms.abs() / 1000).round() < 1) return 'Level with $against';
  return '${trailGap(ms)} ${ms > 0 ? 'ahead of' : 'behind'} $against';
}

/// The gap to the run being raced, number first like DISTANCE and TIME: a
/// small "VS BEST" (or "VS LAST") label, the signed gap big, and the other
/// run's gap smaller underneath. Ahead is mint, behind is vermillion, on a
/// dark plate so both read on any zone flood (the plate's ground is the
/// app's near-black in both themes). [page2] is the one-figure form for the
/// top of the map page.
class TrailGhostReadout extends StatelessWidget {
  const TrailGhostReadout({
    super.key,
    required this.trail,
    this.compact = false,
    this.showLast = true,
    this.page2 = false,
    this.valueSize,
  });
  final TrailProgress trail;

  /// The figure's size on page 1: the same as TIME's, so the run screen hands
  /// over the trio's adaptive size. Null falls back to a fixed size.
  final double? valueSize;

  /// Short phone: one step smaller.
  final bool compact;

  /// Page 1 also says how the other run compares.
  final bool showLast;

  /// The map page's top slot: same figure, smaller, no second line.
  final bool page2;

  static const Color _ground = NightSession.bgBase;

  @override
  Widget build(BuildContext context) {
    final best = trail.aheadBestMs;
    final last = trail.aheadLastMs;
    // The run being raced leads: the best to start with, the last once the
    // runner has slipped clearly behind the best. When the last run IS the
    // best there is one gap and it is called the best.
    final racingLast =
        trail.racing == 'last' && !trail.lastIsBest && last != null;
    final lead = racingLast ? last : best;
    final leadName = racingLast ? 'LAST' : 'BEST';
    final other = racingLast ? best : (trail.lastIsBest ? null : last);
    final otherName = racingLast ? 'best' : 'last';
    if (!trail.off && lead == null) return const SizedBox.shrink();
    final size =
        valueSize ?? RunSoloType.runSize(page2 ? 44 : (compact ? 48 : 64));
    final tone = trail.off ? NightSession.inkPrimary : _tone(lead!);
    final label = [
      if (trail.off)
        'Off the trail'
      else
        trailGapLine(lead!, leadName.toLowerCase()),
      if (!trail.off && showLast && !page2 && other != null)
        trailGapLine(other, otherName),
    ].join('. ');
    return Semantics(
      liveRegion: true,
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('trail-ghost'),
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: Space.x8),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.x12,
            vertical: Space.x4,
          ),
          decoration: BoxDecoration(
            color: _ground,
            borderRadius: BorderRadius.circular(Radii.chip),
            border: Border.all(color: tone, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (trail.off)
                _figure(
                  'Off the trail',
                  size,
                  tone,
                  const ValueKey('trail-ghost-best'),
                )
              else ...[
                Text(
                  'VS $leadName',
                  key: const ValueKey('trail-ghost-label'),
                  style: RunLabelScope.style(
                    context,
                    NightSession.inkSecondary,
                  ),
                ),
                _figure(
                  trailGapFigure(lead!),
                  size,
                  tone,
                  const ValueKey('trail-ghost-best'),
                ),
                if (showLast && !page2 && other != null)
                  _figure(
                    'vs $otherName ${trailGapFigure(other)}',
                    RunSoloType.runSize(36),
                    _tone(other),
                    const ValueKey('trail-ghost-last'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Height of the page 1 readout at [size] (the run screen's plan fitting
  /// needs it before the widget exists): plate padding and border, the label,
  /// the figure and the second line when there is one.
  static double heightFor(TrailProgress trail, double size) {
    double text(double fs) {
      final p = TextPainter(
        text: TextSpan(
          text: '0',
          style: RunSoloType.display44.copyWith(
            fontSize: fs,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return p.height;
    }

    final label = TextPainter(
      text: TextSpan(text: '0', style: RunSoloType.runLabel),
      textDirection: TextDirection.ltr,
    )..layout();
    final racingLast =
        trail.racing == 'last' &&
        !trail.lastIsBest &&
        trail.aheadLastMs != null;
    final lead = racingLast ? trail.aheadLastMs : trail.aheadBestMs;
    final other = racingLast
        ? trail.aheadBestMs
        : (trail.lastIsBest ? null : trail.aheadLastMs);
    if (!trail.off && lead == null) return 0;
    // Plate: 4 + 4 padding, 2 + 2 border, 8 margin; 4 for the label scope.
    var h = Space.x4 * 2 + 4 + Space.x8 + text(size);
    if (!trail.off) {
      h += label.height + 4;
      if (other != null) h += text(RunSoloType.runSize(36));
    }
    return h;
  }

  static Widget _figure(String text, double size, Color color, Key key) =>
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          key: key,
          softWrap: false,
          style: RunSoloType.display44.copyWith(
            fontSize: size,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      );

  static Color _tone(int ms) => (ms.abs() / 1000).round() < 1
      ? NightSession.inkPrimary
      : (ms > 0 ? NightSession.semImproving : NightSession.semSlower);
}

/// TURN AROUND, in the end-of-route card's style: a Bone card with ink text.
class TrailTurnCard extends StatelessWidget {
  const TrailTurnCard({
    super.key,
    required this.fill,
    required this.ink,
    this.compact = false,
  });
  final Color fill;
  final Color ink;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = RunSoloType.runSize(compact ? 36 : 44);
    return Semantics(
      liveRegion: true,
      label: 'Turn around.',
      child: Container(
        key: const ValueKey('trail-turn-card'),
        margin: const EdgeInsets.only(top: Space.x8),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.x12,
          vertical: Space.x8,
        ),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        child: Row(
          children: [
            Icon(Icons.u_turn_left_rounded, size: size, color: ink),
            const SizedBox(width: Space.x12),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'TURN AROUND',
                  key: const ValueKey('trail-turn-text'),
                  softWrap: false,
                  style: RunSoloType.display44.copyWith(
                    fontSize: size,
                    color: ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
