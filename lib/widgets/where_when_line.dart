import 'package:flutter/material.dart';

import '../state/history_store.dart';

/// "Lakeside Dr, Albert Park · Thu 24 Sep · 6:00" on one line. A long street
/// or area ellipsizes; the day and time never do.
class WhereWhenLine extends StatelessWidget {
  const WhereWhenLine({
    super.key,
    required this.place,
    required this.street,
    required this.start,
    required this.utcOffsetMin,
    required this.style,
  });

  final String? place;
  final String? street;
  final DateTime start;
  final int? utcOffsetMin;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final where = whereOf(place, street);
    final when = whenOf(start, utcOffsetMin);
    return Semantics(
      label: whereWhen(
        place,
        start,
        utcOffsetMin: utcOffsetMin,
        street: street,
      ),
      excludeSemantics: true,
      child: where == null
          ? Text(when, maxLines: 1, style: style)
          : Row(
              children: [
                Flexible(
                  child: Text(
                    where,
                    key: const ValueKey('where-part'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                Text(' · $when', maxLines: 1, style: style),
              ],
            ),
    );
  }
}
