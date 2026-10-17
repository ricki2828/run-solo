/// The record screen's MAP view (founder 2-Oct: "see the map during the
/// run, toggleable"). NUMBERS stays the default and the first-class screen;
/// MAP swaps the middle of it for the follow-the-runner map under a compact
/// hero strip. The header (phase, heart rate and zone, total), the LAP /
/// BEGIN REPS button and Pause / Stop are the record screen's own and do not
/// move. The map exists only while this widget is built and the app is in
/// the foreground; with the screen off nothing renders and no map is alive.
library;

import 'package:flutter/material.dart';

import '../map/map_surface.dart';
import '../map/retrace_tracker.dart' show RetraceInput;
import '../map/route_builder.dart';
import '../state/live_route.dart';
import '../theme/theme.dart';

/// The biggest number for the phase, as the NUMBERS layout would show it.
///
/// Free and Trail have no single biggest number (founder 3-Oct): distance,
/// time and average pace are [figures], equal in size, distance first. [text]
/// and [label] then carry the lead figure (distance).
class LiveHero {
  const LiveHero({
    required this.text,
    required this.label,
    this.figures = const [],
  });
  final String text;
  final String label;
  final List<LiveFigure> figures;
}

/// One of an equal-size set of figures: a small label over a value.
class LiveFigure {
  const LiveFigure({required this.label, required this.value});
  final String label;
  final String value;
}

/// Distance on its own row, time and average pace side by side under it, all
/// at ONE size: the largest that fits the worst-case strings (an hour-plus
/// clock in a half-width column, a double-digit distance), never under the
/// 36 sp floor and never over [cap]. The size comes from the worst case, not
/// the live text, so it does not jump when the clock rolls past an hour.
/// [figures] is distance, time, pace; [valueKeys] the same order.
class EqualFigures extends StatelessWidget {
  const EqualFigures({
    super.key,
    required this.figures,
    required this.valueKeys,
    required this.cap,
    required this.labelColor,
    required this.valueColor,
    this.rowGap = Space.x4,
    this.distanceTrailing,
    this.stacked = false,
    this.odometer,
  }) : assert(figures.length == 3 && valueKeys.length == 3);
  final List<LiveFigure> figures;
  final List<Key> valueKeys;
  final double cap;
  final Color labelColor;
  final Color valueColor;
  final double rowGap;

  /// Sits in the free right half of the DISTANCE row (the map view's VS
  /// START), so it costs no height.
  final Widget? distanceTrailing;

  /// Distance, time and pace each on a full-width row (page 1 of the record
  /// screen, where there is room now the route readouts moved to the map).
  final bool stacked;

  /// Builds the distance value as an odometer (the golden-only variant).
  final Widget Function(TextStyle style)? odometer;

  static const double _gap = Space.x16;
  static final double floor = RunSoloType.runSize(36);

  static double _width(String text, TextStyle style) {
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return p.width;
  }

  /// The shared size for a column [maxWidth] wide.
  static double sizeFor(double maxWidth, double cap, {bool stacked = false}) {
    const ref = 100.0;
    final base = RunSoloType.display44.copyWith(
      fontSize: ref,
      fontWeight: FontWeight.w700,
    );
    final half = (maxWidth - _gap) / 2;
    final fit = [
      (stacked ? maxWidth : half) / _width('8:88:88', base) * ref,
      maxWidth / _width('88.88 mi', base) * ref,
    ].reduce((a, b) => a < b ? a : b);
    return fit.clamp(floor, cap).floorToDouble();
  }

  Widget _one(BuildContext context, int i, TextStyle style) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(figures[i].label, style: RunLabelScope.style(context, labelColor)),
      if (i == 0 && odometer != null)
        KeyedSubtree(key: valueKeys[i], child: odometer!(style))
      else
        Text(
          figures[i].value,
          key: valueKeys[i],
          softWrap: false,
          maxLines: 1,
          overflow: TextOverflow.visible,
          style: style,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final style = RunSoloType.display44.copyWith(
        fontSize: sizeFor(c.maxWidth, cap, stacked: stacked),
        fontWeight: FontWeight.w700,
        color: valueColor,
      );
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(height: rowGap),
              _one(context, i, style),
            ],
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (distanceTrailing == null)
            _one(context, 0, style)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(child: _one(context, 0, style)),
                const SizedBox(width: _gap),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: distanceTrailing,
                    ),
                  ),
                ),
              ],
            ),
          SizedBox(height: rowGap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: _one(context, 1, style)),
              const SizedBox(width: _gap),
              Expanded(child: _one(context, 2, style)),
            ],
          ),
        ],
      );
    },
  );
}

/// Page 2 of the record screen: the map and every route readout (distance
/// back to start, height vs start, climb, follow-route turn hints). The run
/// numbers live on page 1; nothing here repeats them. The map exists only
/// while this widget is built and the app is in the foreground; with the
/// screen off nothing renders and no map is alive.
class LiveMapView extends StatefulWidget {
  const LiveMapView({
    super.key,
    required this.maps,
    required this.track,
    required this.typeColor,
    required this.readouts,
    this.plan,
    this.terrain = false,
    this.retrace,
    this.mapBoxKey,
    this.numbers,
  });

  /// Keys the map's box (tests and layout checks find it by this).
  final GlobalKey? mapBoxKey;

  /// The run numbers (distance, time, pace) above the map, big. They take the
  /// room the map does not: the map is capped at [mapFraction] of the height.
  final Widget? numbers;

  /// The most of the page's height the map may take when [numbers] is set.
  static const double mapFraction = 0.4;

  final MapSurfaceFactory maps;
  final LiveRouteTrack track;

  /// The run type's colour: the route so far.
  final Color typeColor;

  /// The route readouts above the map, already styled by the record screen.
  final List<Widget> readouts;

  /// The planned line being followed, drawn under the track.
  final List<GeoPoint>? plan;

  /// Free and Trail runs: Google's terrain map instead of the night style.
  final bool terrain;

  /// The recorder's retrace state, for the map to draw (null: none).
  final RetraceInput? retrace;

  @override
  State<LiveMapView> createState() => _LiveMapViewState();
}

class _LiveMapViewState extends State<LiveMapView> with WidgetsBindingObserver {
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Screen off or app in the background: drop the map entirely (the
  /// platform view, its tiles and its camera timers go with it). It is
  /// rebuilt from the recorder's route when the screen comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg != _foreground) setState(() => _foreground = fg);
  }

  Widget _map(BuildContext context) => _foreground
      ? widget.maps.buildLive(
          context,
          track: widget.track,
          color: widget.typeColor,
          plan: widget.plan,
          terrain: widget.terrain,
          retrace: widget.retrace,
        )
      : const SizedBox.shrink(key: ValueKey('map-off'));

  // The map is display-only: it follows the runner and recentres itself. It
  // must not take touches, or its platform view eats the horizontal drags the
  // page swiper needs (17-Oct: swipe still unreliable over the map).
  Widget _mapBox(BuildContext context) => SizedBox(
    key: widget.mapBoxKey ?? const ValueKey('map-page-map'),
    child: IgnorePointer(
      key: const ValueKey('map-ignore-touches'),
      child: _map(context),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final numbers = widget.numbers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in widget.readouts) ...[
          r,
          const SizedBox(height: Space.x8),
        ],
        if (numbers == null)
          Expanded(child: _mapBox(context))
        else
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: SizedBox(width: c.maxWidth, child: numbers),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.x8),
                  SizedBox(
                    height: c.maxHeight * LiveMapView.mapFraction,
                    child: _mapBox(context),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
