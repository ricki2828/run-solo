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
    this.enabled = true,
    this.height = 84,
  });

  final List<engine.TreadmillMark> marks;
  final Units units;

  /// Called with the chip's distance (metres) on a double-tap.
  final void Function(double distanceM) onMark;

  /// False while paused: dimmed, and a double-tap marks nothing (a paused
  /// mark would carry the last mark's moving time).
  final bool enabled;
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
      viewportFraction:
          1 /
          3, // three whole chips: the next one centred, a neighbour each side
      initialPage: TreadmillMarkerStrip.nextIndex(widget.marks, widget.units),
    );
  }

  @override
  void didUpdateWidget(TreadmillMarkerStrip old) {
    super.didUpdateWidget(old);
    if (old.marks.length != widget.marks.length) {
      // After this frame, so the strip has laid out with the new marks first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_page.hasClients) return;
        _page.animateToPage(
          TreadmillMarkerStrip.nextIndex(widget.marks, widget.units),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      });
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
    return Opacity(
      opacity: widget.enabled ? 1 : 0.4,
      child: SizedBox(
        key: const ValueKey('treadmill-strip'),
        height: widget.height,
        child: PageView.builder(
          controller: _page,
          itemCount: TreadmillMarkerStrip.chipCount,
          padEnds: true,
          itemBuilder: (context, i) {
            final marked = i <= lastIndex;
            final next = i == lastIndex + 1;
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
                onDoubleTap: marked || !widget.enabled
                    ? null
                    : () {
                        // Not mid-swipe or mid-glide: the chip under the finger
                        // may be a neighbour sliding past.
                        if (_page.hasClients &&
                            _page.position.isScrollingNotifier.value) {
                          return;
                        }
                        widget.onMark((i + 1) * spacing);
                      },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: marked ? t.inkPrimary : Colors.transparent,
                    border: Border.all(
                      color: next || marked ? t.inkPrimary : t.inkSecondary,
                      width: next ? 5 : 2,
                    ),
                    borderRadius: BorderRadius.circular(Radii.chip * 2),
                  ),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (marked) ...[
                            Icon(
                              Icons.check_rounded,
                              key: ValueKey('marker-tick-$i'),
                              size: 32,
                              color: t.bgBase,
                            ),
                            const SizedBox(width: 2),
                          ],
                          Text(
                            TreadmillMarkerStrip.chipLabel(i, widget.units),
                            style: RunSoloType.display44.copyWith(
                              color: marked ? t.bgBase : t.inkPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
