import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// Treadmill distance markers: a horizontal strip of big chips, 0.5 km apart
/// (0.25 mi for miles users). DOUBLE-TAP a chip to say you have just passed
/// that distance; the strip then centres the next one. Swipe to reach a later
/// chip when a marker was missed (skipping is fine). Marks are native's; this
/// only shows them and asks for the next.
class TreadmillMarkerStrip extends StatefulWidget {
  const TreadmillMarkerStrip({
    super.key,
    required this.marks,
    required this.units,
    required this.onMark,
    this.height = 84,
  });

  final List<engine.TreadmillMark> marks;
  final Units units;

  /// Called with the chip's distance (metres) on a double-tap.
  final void Function(double distanceM) onMark;
  final double height;

  /// Metres between chips.
  static double spacingM(Units units) => units == Units.mi
      ? engine.TreadmillSplits.miSpacingM
      : engine.TreadmillSplits.kmSpacingM;

  /// Chip count: 100 km / 62 mi is far past any treadmill session.
  static const int chipCount = 200;

  /// "0.5", "1.0", "1.5" in km; "0.25", "0.50" in miles.
  static String chipLabel(int index, Units units) => units == Units.mi
      ? ((index + 1) * 0.25).toStringAsFixed(2)
      : ((index + 1) * 0.5).toStringAsFixed(1);

  /// The chip a mark belongs to (marks are only ever made on chips).
  static int chipIndexOf(double distanceM, Units units) =>
      (distanceM / spacingM(units)).round() - 1;

  /// The first chip not yet marked: the one the strip centres.
  static int nextIndex(List<engine.TreadmillMark> marks, Units units) =>
      marks.isEmpty ? 0 : chipIndexOf(marks.last.distanceM, units) + 1;

  @override
  State<TreadmillMarkerStrip> createState() => _TreadmillMarkerStripState();
}

class _TreadmillMarkerStripState extends State<TreadmillMarkerStrip> {
  late final PageController _page;

  @override
  void initState() {
    super.initState();
    _page = PageController(
      viewportFraction: 0.4,
      initialPage: TreadmillMarkerStrip.nextIndex(widget.marks, widget.units),
    );
  }

  @override
  void didUpdateWidget(TreadmillMarkerStrip old) {
    super.didUpdateWidget(old);
    if (old.marks.length != widget.marks.length && _page.hasClients) {
      _page.animateToPage(
        TreadmillMarkerStrip.nextIndex(widget.marks, widget.units),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final spacing = TreadmillMarkerStrip.spacingM(widget.units);
    final lastIndex = widget.marks.isEmpty
        ? -1
        : TreadmillMarkerStrip.chipIndexOf(
            widget.marks.last.distanceM,
            widget.units,
          );
    return SizedBox(
      key: const ValueKey('treadmill-strip'),
      height: widget.height,
      child: PageView.builder(
        controller: _page,
        itemCount: TreadmillMarkerStrip.chipCount,
        padEnds: true,
        itemBuilder: (context, i) {
          final marked = i <= lastIndex;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              key: ValueKey('marker-chip-$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _page.animateToPage(
                i,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              ),
              onDoubleTap: marked
                  ? null
                  : () => widget.onMark((i + 1) * spacing),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: marked ? t.inkPrimary : Colors.transparent,
                  border: Border.all(color: t.inkSecondary, width: 2),
                  borderRadius: BorderRadius.circular(Radii.chip * 2),
                ),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      TreadmillMarkerStrip.chipLabel(i, widget.units),
                      style: RunSoloType.display44.copyWith(
                        color: marked ? t.bgBase : t.inkPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
