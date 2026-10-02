/// Follow a route, live: what is left of the route and what the next turn is.
/// Two shapes of the same figures: [RouteToGoRow] under the numbers on the
/// NUMBERS view, [RouteStrip] between the hero and the map on the MAP view.
/// Never the hero: both sit under it, and every figure keeps the record
/// screen's 36 sp floor (A8). The distance, the climb and the turn all come
/// from the recorder's own fixes, so they update with the screen off too.
library;

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';

/// "Left turn in 120 m" (miles users: "in 130 yd"), "Left turn now" under 15 m.
/// A "keep" is a nudge the voice says with no distance; the strip still shows how far.
String routeTurnText(RouteProgress r, Units units) {
  final label = r.turnLabel;
  final m = r.turnInM;
  if (label == null || m == null) return '';
  if (m < 15) return '$label now';
  final yd = units == Units.mi;
  final v = yd ? m * 1.09361 : m;
  return '$label in ${(v / 10).round() * 10} ${yd ? 'yd' : 'm'}';
}

const double _figureSize = 36;

TextStyle _figureStyle(Color color) => RunSoloType.display44.copyWith(
  fontSize: _figureSize,
  color: color,
  fontWeight: FontWeight.w600,
);

/// NUMBERS view: "ROUTE TO GO 3.40 km" and "CLIMB TO GO 120 m" side by side
/// (the climb only when the route has elevation), the next turn on a line of
/// its own, or OFF ROUTE in warn.
class RouteToGoRow extends StatelessWidget {
  const RouteToGoRow({
    super.key,
    required this.route,
    required this.units,
    required this.labelColor,
    required this.valueColor,
    required this.warnColor,
  });
  final RouteProgress route;
  final Units units;
  final Color labelColor;
  final Color valueColor;
  final Color warnColor;

  @override
  Widget build(BuildContext context) {
    final turn = routeTurnText(route, units);
    return Column(
      key: const ValueKey('route-to-go'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: _Figure(
                label: route.off ? 'OFF ROUTE' : 'ROUTE TO GO',
                labelColor: route.off ? warnColor : labelColor,
                value: Fmt.distance(route.toGoM, units),
                valueColor: valueColor,
                valueKey: const ValueKey('route-to-go-distance'),
              ),
            ),
            if (route.climbToGoM != null) ...[
              const SizedBox(width: Space.x16),
              Expanded(
                child: _Figure(
                  label: 'CLIMB TO GO',
                  labelColor: labelColor,
                  value: Fmt.elevation(route.climbToGoM, units),
                  valueColor: valueColor,
                  valueKey: const ValueKey('route-to-go-climb'),
                ),
              ),
            ],
          ],
        ),
        if (!route.off && turn.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.x4),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                turn,
                key: const ValueKey('route-turn'),
                softWrap: false,
                style: _figureStyle(valueColor),
              ),
            ),
          ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.labelColor,
    required this.value,
    required this.valueColor,
    required this.valueKey,
  });
  final String label;
  final Color labelColor;
  final String value;
  final Color valueColor;
  final Key valueKey;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: RunSoloType.micro11.copyWith(color: labelColor)),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          key: valueKey,
          softWrap: false,
          style: _figureStyle(valueColor),
        ),
      ),
    ],
  );
}

/// MAP view: one strip under the hero, "3.40 km to go · 120 m up" (or OFF
/// ROUTE, or the next turn when one is close), in the same 36 sp floor. One
/// line, so the map keeps its height.
class RouteStrip extends StatelessWidget {
  const RouteStrip({
    super.key,
    required this.route,
    required this.units,
    required this.valueColor,
    required this.warnColor,
  });
  final RouteProgress route;
  final Units units;
  final Color valueColor;
  final Color warnColor;

  /// What the strip says: off route first, then a turn that is close, else
  /// the distance and climb left.
  String get text {
    if (route.off) return 'OFF ROUTE · ${Fmt.distance(route.toGoM, units)}';
    final turn = routeTurnText(route, units);
    if (turn.isNotEmpty) return turn;
    final climb = route.climbToGoM;
    return climb == null
        ? '${Fmt.distance(route.toGoM, units)} to go'
        : '${Fmt.distance(route.toGoM, units)} to go · '
              '${Fmt.elevation(climb, units)} up';
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.x8),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        key: const ValueKey('route-strip'),
        softWrap: false,
        style: _figureStyle(route.off ? warnColor : valueColor),
      ),
    ),
  );
}
