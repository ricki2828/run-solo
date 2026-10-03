/// The record screen's MAP view (founder 2-Oct: "see the map during the
/// run, toggleable"). NUMBERS stays the default and the first-class screen;
/// MAP swaps the middle of it for the follow-the-runner map under a compact
/// hero strip. The header (phase, heart rate and zone, total), the LAP /
/// START REPS button and Pause / Stop are the record screen's own and do not
/// move. The map exists only while this widget is built and the app is in
/// the foreground; with the screen off nothing renders and no map is alive.
library;

import 'package:flutter/material.dart';

import '../map/map_surface.dart';
import '../map/route_builder.dart';
import '../platform/gateway.dart';
import '../state/live_route.dart';
import '../theme/theme.dart';
import '../widgets/compare_card.dart';
import '../widgets/route_to_go.dart';

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
  }) : assert(figures.length == 3 && valueKeys.length == 3);
  final List<LiveFigure> figures;
  final List<Key> valueKeys;
  final double cap;
  final Color labelColor;
  final Color valueColor;
  final double rowGap;

  static const double _gap = Space.x16;
  static const double floor = 36;

  static double _width(String text, TextStyle style) {
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return p.width;
  }

  /// The shared size for a column [maxWidth] wide.
  static double sizeFor(double maxWidth, double cap) {
    const ref = 100.0;
    final base = RunSoloType.display44.copyWith(
      fontSize: ref,
      fontWeight: FontWeight.w700,
    );
    final half = (maxWidth - _gap) / 2;
    final fit = [
      half / _width('8:88:88', base) * ref,
      maxWidth / _width('88.88 mi', base) * ref,
    ].reduce((a, b) => a < b ? a : b);
    return fit.clamp(floor, cap).floorToDouble();
  }

  Widget _one(int i, TextStyle style) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        figures[i].label,
        style: RunSoloType.micro11.copyWith(color: labelColor),
      ),
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
        fontSize: sizeFor(c.maxWidth, cap),
        fontWeight: FontWeight.w700,
        color: valueColor,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _one(0, style),
          SizedBox(height: rowGap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: _one(1, style)),
              const SizedBox(width: _gap),
              Expanded(child: _one(2, style)),
            ],
          ),
        ],
      );
    },
  );
}

class LiveMapView extends StatefulWidget {
  const LiveMapView({
    super.key,
    required this.maps,
    required this.track,
    required this.typeColor,
    required this.hero,
    required this.compact,
    required this.secondary,
    required this.paused,
    this.cardLink,
    this.route,
    this.plan,
    this.units = Units.km,
    this.terrain = false,
  });

  final MapSurfaceFactory maps;
  final LiveRouteTrack track;

  /// The run type's colour: the route so far.
  final Color typeColor;
  final LiveHero hero;
  final bool compact;

  /// Label colour that reads on the current zone background.
  final Color secondary;

  /// Paused: the numbers hide under the PAUSED card, the map too.
  final bool paused;

  /// The live compare card's slot (LV1/LV2): a zero-height anchor under the
  /// hero, so a card slides in over the top of the map, never the hero.
  final LayerLink? cardLink;

  /// Follow a route: the live figures (a strip line under the hero) and the
  /// planned line to draw under the track. Null = following nothing.
  final RouteProgress? route;
  final List<GeoPoint>? plan;
  final Units units;

  /// Free and Trail runs: Google's terrain map instead of the night style.
  final bool terrain;

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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final h = widget.hero;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The hero: biggest and brightest (founder readability rule), well
        // over the 36 sp floor, on the zone background.
        Visibility(
          visible: !widget.paused,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: h.figures.isNotEmpty
              // Free / Trail: distance, time and average pace at one size.
              ? EqualFigures(
                  figures: h.figures,
                  valueKeys: const [
                    ValueKey('map-hero'),
                    ValueKey('map-hero-time'),
                    ValueKey('map-hero-pace'),
                  ],
                  cap: widget.compact ? 40 : 44,
                  labelColor: widget.secondary,
                  valueColor: t.inkPrimary,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        h.text,
                        key: const ValueKey('map-hero'),
                        softWrap: false,
                        style: RunSoloType.display64
                            .copyWith(
                              color: t.inkPrimary,
                              fontSize: widget.compact ? 52 : 64,
                            )
                            .copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      h.label,
                      key: const ValueKey('map-hero-label'),
                      style: RunSoloType.label13.copyWith(
                        color: widget.secondary,
                      ),
                    ),
                  ],
                ),
        ),
        CompareSlot(
          link: widget.cardLink,
          child: const SizedBox(width: double.infinity, height: Space.x8),
        ),
        // The route's strip sits under the hero, never over it: distance and
        // climb to go, the next turn, or OFF ROUTE.
        if (widget.route != null)
          Visibility(
            visible: !widget.paused,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: RouteStrip(
              route: widget.route!,
              units: widget.units,
              // The hero stays the brightest number: the strip is the label tone.
              valueColor: widget.secondary,
              warnColor: t.semWarn,
            ),
          ),
        Expanded(
          child: _foreground
              ? widget.maps.buildLive(
                  context,
                  track: widget.track,
                  color: widget.typeColor,
                  plan: widget.plan,
                  terrain: widget.terrain,
                )
              : const SizedBox.shrink(key: ValueKey('map-off')),
        ),
      ],
    );
  }
}

/// The small NUMBERS / MAP switch in the header row: a 48 dp target that
/// never takes space from the LAP / START REPS button.
class LiveViewToggle extends StatelessWidget {
  const LiveViewToggle({
    super.key,
    required this.mapShown,
    required this.onTap,
  });
  final bool mapShown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: mapShown ? 'Show numbers' : 'Show map',
      excludeSemantics: true,
      child: InkResponse(
        key: const ValueKey('live-view-toggle'),
        onTap: onTap,
        radius: 24,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            mapShown ? Icons.speed : Icons.map_outlined,
            size: 28,
            color: t.inkPrimary,
          ),
        ),
      ),
    );
  }
}
