import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// The one container for a screen section: white surface, a hairline border,
/// radius 14, 16 dp padding and a very faint shadow. Pass [accent] for a hero
/// card: that colour as a ~7% wash with a 4 dp bar down the left edge.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.accent,
    this.padding = const EdgeInsets.all(Space.x16),
  });

  final Widget child;
  final Color? accent;
  final EdgeInsetsGeometry padding;

  static const double radius = 14;
  static const double accentWidth = 4;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final a = accent;
    final body = Padding(padding: padding, child: child);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: a == null
            ? t.bgRaised
            : Color.alphaBlend(a.withValues(alpha: 0.07), t.bgRaised),
        border: Border.all(color: t.lineHair),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            offset: Offset(0, 1),
            blurRadius: 3,
          ),
        ],
      ),
      child: a == null
          ? body
          : ClipRRect(
              borderRadius: BorderRadius.circular(radius - 1),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      key: const ValueKey('section-card-accent'),
                      width: accentWidth,
                      color: a,
                    ),
                    Expanded(child: body),
                  ],
                ),
              ),
            ),
    );
  }
}
