import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'boards_overview.dart';
import 'trend_screen.dart';

/// The PROGRESS tab (LB3c, mockup frame 1): the boards overview by default,
/// the trends behind the second segment. The tab keeps both alive, so a
/// switch back and forth loses nothing.
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PROGRESS')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.screenGutter,
                Space.x8,
                Space.screenGutter,
                Space.x8,
              ),
              child: _Segmented(
                selected: _tab,
                onSelect: (i) => setState(() => _tab = i),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [BoardsOverview(), TrendScreen()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// BOARDS · TRENDS, the mockup's pill bar: the picked segment is raised,
/// the other quiet.
class _Segmented extends StatelessWidget {
  const _Segmented({required this.selected, required this.onSelect});
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      height: 44,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.bgRaised,
        borderRadius: BorderRadius.circular(Radii.button),
      ),
      child: Row(
        children: [
          for (final (i, label, key) in const [
            (0, 'BOARDS', 'progress-seg-boards'),
            (1, 'TRENDS', 'progress-seg-trends'),
          ]) ...[
            Expanded(
              child: Semantics(
                button: true,
                selected: selected == i,
                child: InkWell(
                  key: ValueKey(key),
                  borderRadius: BorderRadius.circular(Radii.button),
                  onTap: () => onSelect(i),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected == i ? t.bgSunken : null,
                      borderRadius: BorderRadius.circular(Radii.button),
                    ),
                    child: Text(
                      label,
                      style: RunSoloType.label13.copyWith(
                        color: selected == i ? t.inkPrimary : t.inkSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
