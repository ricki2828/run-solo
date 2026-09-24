import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Phase 0 placeholder in the Night Session style. Real Start / Today screens
/// arrive with Phase 1 (run-app-fable); this only proves theme + fonts.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: Space.x24),
              Text('RUN SOLO', style: text.headlineMedium),
              const SizedBox(height: Space.x8),
              Text('4X4 INTERVAL RUN', style: text.labelSmall),
              const Spacer(),
              Text('BASELINE', style: text.displayLarge),
              const SizedBox(height: Space.x12),
              Text(
                'Your first 4x4 sets the baseline.',
                style: text.bodyLarge?.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x32),
              Divider(height: 2, thickness: 2, color: t.lineHair),
              const SizedBox(height: Space.x32),
              FilledButton(
                onPressed: null,
                child: const Text('START'),
              ),
              const SizedBox(height: Space.x12),
              Text(
                'Recording arrives in Phase 1.',
                style: text.labelSmall?.copyWith(color: t.inkMuted),
              ),
              const SizedBox(height: Space.x24),
            ],
          ),
        ),
      ),
    );
  }
}
