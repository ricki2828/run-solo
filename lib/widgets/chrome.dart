import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../brand/lap_line_paths.dart';
import '../theme/lanes.dart' show readableOn;
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
      PillTone.danger => (readableOn(t.semDanger), t.semDanger),
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
    this.labelColor,
    this.size = 44,
    this.align = CrossAxisAlignment.start,
  });
  final String label;
  final String value;
  final Color? valueColor;
  final Color? labelColor;
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
          style: RunSoloType.micro11.copyWith(
            color: labelColor ?? t.inkSecondary,
          ),
        ),
      ],
    );
  }
}

/// The Lap Line R (brand mark, `lib/brand/lap_line_paths.dart`) in Bone.
class LapLineMark extends StatelessWidget {
  const LapLineMark({super.key, this.height = 48});
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = height / LapLineGeometry.cap;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(
          (LapLineGeometry.rRight - LapLineGeometry.rLeft) * s,
          height,
        ),
        painter: _LapLineMarkPainter(t.inkPrimary),
      ),
    );
  }
}

class _LapLineMarkPainter extends CustomPainter {
  _LapLineMarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.height / LapLineGeometry.cap;
    canvas.translate(-LapLineGeometry.rLeft * s, 0);
    canvas.scale(s);
    canvas.drawPath(lapLineR(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LapLineMarkPainter old) => old.color != color;
}

/// The whole Lap Line mark: the R cut at the lap line, with the Arc line
/// running out of the leg (final frame of the Lap Draw intro).
class LapLineFullMark extends StatelessWidget {
  const LapLineFullMark({super.key, this.height = 48});
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = height / LapLineGeometry.cap;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(
          (LapLineGeometry.markTailEndX - LapLineGeometry.rLeft) * s,
          height,
        ),
        painter: _LapLineFullPainter(t.inkPrimary, t.accentArc),
      ),
    );
  }
}

class _LapLineFullPainter extends CustomPainter {
  _LapLineFullPainter(this.bone, this.arc);
  final Color bone;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.height / LapLineGeometry.cap;
    canvas.translate(-LapLineGeometry.rLeft * s, 0);
    canvas.scale(s);
    final cut = Path()
      ..addRect(
        Rect.fromLTRB(
          0,
          LapLineGeometry.cutY - LapLineGeometry.cutThickness / 2,
          LapLineGeometry.markTailEndX + 10,
          LapLineGeometry.cutY + LapLineGeometry.cutThickness / 2,
        ),
      );
    canvas.drawPath(
      Path.combine(PathOperation.difference, lapLineR(), cut),
      Paint()..color = bone,
    );
    final t = LapLineGeometry.lineThickness;
    final r = Radius.circular(t / 2);
    canvas.drawRRect(
      RRect.fromLTRBAndCorners(
        LapLineGeometry.legEntryX,
        LapLineGeometry.cutY - t / 2,
        LapLineGeometry.markTailEndX,
        LapLineGeometry.cutY + t / 2,
        topRight: r,
        bottomRight: r,
      ),
      Paint()..color = arc,
    );
  }

  @override
  bool shouldRepaint(_LapLineFullPainter old) =>
      old.bone != bone || old.arc != arc;
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
              'PROGRESS',
              Icons.emoji_events_outlined,
              Icons.emoji_events,
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
/// scrolls and the button stays on screen, never "BOTTOM OVERFLOWED". While
/// there is more below, the list fades out over its last 32 px so clipped
/// text reads as "more below", not as a cut line; content that fits, or a
/// list scrolled to its end, is never faded.
class PinnedFooterLayout extends StatefulWidget {
  const PinnedFooterLayout({
    super.key,
    required this.content,
    required this.footer,
  });
  final List<Widget> content;
  final List<Widget> footer;

  @override
  State<PinnedFooterLayout> createState() => _PinnedFooterLayoutState();
}

class _PinnedFooterLayoutState extends State<PinnedFooterLayout> {
  bool _moreBelow = false;

  bool _onMetrics(ScrollMetrics m) {
    final more = m.extentAfter > 0.5;
    if (more == _moreBelow) return false;
    // The first metrics of a list that overflows arrive during layout, where
    // setState is an error ("Build scheduled during frame"): wait one frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && more != _moreBelow) setState(() => _moreBelow = more);
      });
    } else {
      setState(() => _moreBelow = more);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final list = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _onMetrics(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _onMetrics(n.metrics),
        child: ListView(children: widget.content),
      ),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              // One tree either way: remounting the list would reset its
              // scroll position, so only the gradient changes.
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        NightSession.inkPrimary,
                        NightSession.inkPrimary,
                        _moreBelow
                            ? Colors.transparent
                            : NightSession.inkPrimary,
                      ],
                      stops: [0, 1 - (32 / rect.height).clamp(0.0, 1.0), 1],
                    ).createShader(rect),
                    child: list,
                  ),
                  if (_moreBelow)
                    const SizedBox.shrink(key: ValueKey('more-below-fade')),
                ],
              ),
            ),
            const SizedBox(height: Space.x12),
            ...widget.footer,
          ],
        ),
      ),
    );
  }
}

/// The one app bar every pushed and tabbed screen uses: same height, same
/// title style (display, uppercase), a back arrow when the route can pop,
/// and at most one trailing action. Arrow and action are 48 dp minimum.
class RunAppBar extends StatelessWidget implements PreferredSizeWidget {
  const RunAppBar({
    super.key,
    this.title,
    this.titleWidget,
    this.trailing,
    this.showBack,
  }) : assert(title != null || titleWidget != null);

  final String? title;

  /// Replaces [title] (Home's brand mark); same slot, same height.
  final Widget? titleWidget;
  final Widget? trailing;

  /// null = a back arrow when the route can pop.
  final bool? showBack;

  static const double height = 64;
  static const double minTarget = 48;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final back = showBack ?? (ModalRoute.canPopOf(context) ?? false);
    // Light bar: ground fill, ink title in the display face, hairline under it.
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineHair)),
      ),
      child: AppBar(
        toolbarHeight: height,
        automaticallyImplyLeading: false,
        leadingWidth: back ? 64 : 0,
        leading: back
            ? Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back',
                  constraints: const BoxConstraints(
                    minWidth: minTarget,
                    minHeight: minTarget,
                  ),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              )
            : null,
        titleSpacing: back ? 0 : Space.screenGutter,
        centerTitle: false,
        title:
            titleWidget ??
            Text(
              title!.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RunSoloType.appBarTitle.copyWith(color: t.inkPrimary),
            ),
        actions: [
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(right: Space.screenGutter),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: minTarget,
                  minHeight: minTarget,
                ),
                child: Center(child: trailing),
              ),
            ),
        ],
      ),
    );
  }
}

/// The header of a bottom sheet: the app bar's title style and 48 dp back
/// arrow (when [onBack] is given), minus the bar itself.
class RunSheetHeader extends StatelessWidget {
  const RunSheetHeader({
    super.key,
    required this.title,
    this.onBack,
    this.backTooltip = 'Back',
  });
  final String title;
  final VoidCallback? onBack;
  final String backTooltip;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: RunAppBar.minTarget),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              tooltip: backTooltip,
              constraints: const BoxConstraints(
                minWidth: RunAppBar.minTarget,
                minHeight: RunAppBar.minTarget,
              ),
              icon: Icon(Icons.arrow_back, color: t.inkPrimary),
              onPressed: onBack,
            ),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: RunSoloType.appBarTitle.copyWith(color: t.inkPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
