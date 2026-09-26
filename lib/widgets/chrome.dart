import 'package:flutter/material.dart';

import '../theme/theme.dart';

enum PillTone { ok, warn, danger, muted }

/// Status pill: warn / ok / danger (design brief §5).
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.tone});
  final String label;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final (Color fg, Color bg) = switch (tone) {
      PillTone.ok => (t.inkPrimary, t.bgRaised),
      PillTone.warn => (t.bgBase, t.semWarn),
      PillTone.danger => (t.inkPrimary, t.semDanger),
      PillTone.muted => (t.inkMuted, t.bgRaised),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label, style: RunSoloType.micro11.copyWith(color: fg)),
    );
  }
}

/// Micro label + display44 tabular number.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.size = 44,
    this.align = CrossAxisAlignment.start,
  });
  final String label;
  final String value;
  final Color? valueColor;
  final double size;
  final CrossAxisAlignment align;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: align == CrossAxisAlignment.end
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Text(
            value,
            softWrap: false,
            style: RunSoloType.display44.copyWith(
              fontSize: size,
              color: valueColor ?? t.inkPrimary,
            ),
          ),
        ),
        const SizedBox(height: Space.x4),
        Text(
          label.toUpperCase(),
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

/// The Tally: four bars, the fourth Arc and taller (design brief §2.2).
class TallyMark extends StatelessWidget {
  const TallyMark({super.key, this.height = 32, this.earned = true});
  final double height;

  /// Cyan is earned; the empty state draws all four in Bone.
  final bool earned;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final barW = height * 12 / 54;
    final gap = height * 8 / 54;
    return SizedBox(
      height: height * 1.08,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Container(
              width: barW,
              height: i == 3 ? height * 1.08 : height,
              margin: EdgeInsets.only(top: i == 3 ? 0 : height * 0.08),
              decoration: BoxDecoration(
                color: i == 3 && earned ? t.accentArc : t.inkPrimary,
                borderRadius: BorderRadius.circular(barW * 0.12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Full-bleed 2 px Bone rule with a 24 px gap (design brief §2.2).
class LapLineDivider extends StatelessWidget {
  const LapLineDivider({super.key, this.gapAt = 0.5});
  final double gapAt;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return SizedBox(
      height: 2,
      child: CustomPaint(painter: _LapLinePainter(t.inkPrimary, gapAt)),
    );
  }
}

class _LapLinePainter extends CustomPainter {
  _LapLinePainter(this.color, this.gapAt);
  final Color color;
  final double gapAt;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2;
    final gx = size.width * gapAt;
    canvas.drawLine(Offset(0, 1), Offset(gx - 12, 1), p);
    canvas.drawLine(Offset(gx + 12, 1), Offset(size.width, 1), p);
  }

  @override
  bool shouldRepaint(_LapLinePainter old) =>
      old.color != color || old.gapAt != gapAt;
}

enum AppTab { home, history, trend, settings }

/// 4 tabs, filled icon on active, 64 dp (design brief §5).
class BottomNav extends StatelessWidget {
  const BottomNav({super.key, required this.current, required this.onSelect});
  final AppTab current;
  final ValueChanged<AppTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    Widget tab(AppTab tab, String label, IconData icon, IconData active) {
      final on = tab == current;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          label: label,
          child: InkWell(
            onTap: () => onSelect(tab),
            child: SizedBox(
              height: 64,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    on ? active : icon,
                    size: 24,
                    color: on ? t.inkPrimary : t.inkSecondary,
                  ),
                  const SizedBox(height: Space.x4),
                  Text(
                    label,
                    style: RunSoloType.micro11.copyWith(
                      color: on ? t.inkPrimary : t.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: t.bgBase,
        border: Border(top: BorderSide(color: t.lineHair, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            tab(AppTab.home, 'HOME', Icons.home_outlined, Icons.home),
            tab(
              AppTab.history,
              'HISTORY',
              Icons.list_alt_outlined,
              Icons.list_alt,
            ),
            tab(
              AppTab.trend,
              'TREND',
              Icons.show_chart_outlined,
              Icons.show_chart,
            ),
            tab(
              AppTab.settings,
              'SETTINGS',
              Icons.settings_outlined,
              Icons.settings,
            ),
          ],
        ),
      ),
    );
  }
}

/// A page body that scrolls above a pinned footer (the CONTINUE button): on
/// a short phone, at a large text size or with the keyboard up the content
/// scrolls and the button stays on screen, never "BOTTOM OVERFLOWED".
class PinnedFooterLayout extends StatelessWidget {
  const PinnedFooterLayout({
    super.key,
    required this.children,
    required this.footer,
  });
  final List<Widget> children;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: ListView(children: children)),
            ...footer,
          ],
        ),
      ),
    );
  }
}
