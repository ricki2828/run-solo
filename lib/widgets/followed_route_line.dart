/// Run detail's summary of a run that followed a route (Follow a route):
/// "Followed: Hill loop, off route 2x for 1:40", or "stayed on route".
library;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../map/route_builder.dart' show GeoPoint;
import '../theme/theme.dart';

/// The one-line summary; the off-route figures come from the run file.
String followedRouteSummary(engine.FollowedRoute r) {
  final n = r.offRouteCount;
  if (n == 0) return 'Followed: ${r.name}, stayed on route';
  return 'Followed: ${r.name}, off route ${n}x for ${Fmt.clock(r.offRouteMs)}';
}

/// The planned line the map draws (muted Bone) as map points.
List<GeoPoint> followedPlanPoints(engine.FollowedRoute r) => [
  for (final p in r.points) GeoPoint(p.lat, p.lon),
];

class FollowedRouteLine extends StatelessWidget {
  const FollowedRouteLine({super.key, required this.route});
  final engine.FollowedRoute route;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: Space.x8),
          child: Icon(Icons.alt_route, size: 18, color: t.inkSecondary),
        ),
        Expanded(
          child: Text(
            followedRouteSummary(route),
            key: const ValueKey('followed-route-line'),
            style: RunSoloType.body15.copyWith(color: t.inkPrimary),
          ),
        ),
      ],
    );
  }
}
