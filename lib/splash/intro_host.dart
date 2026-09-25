/// Puts the Lap Draw intro over the app for one cold start (plan §4). The
/// app underneath builds and starts up at the same time; when the intro
/// fades out, Home is already there.
library;

import 'package:flutter/material.dart';

import '../app/services.dart';
import '../app/version.dart';
import 'intro_gate.dart';
import 'lap_draw_intro.dart';

class IntroHost extends StatefulWidget {
  const IntroHost({super.key, required this.kind, required this.child});

  final IntroKind kind;
  final Widget child;

  @override
  State<IntroHost> createState() => _IntroHostState();
}

class _IntroHostState extends State<IntroHost> {
  late bool _showing = widget.kind != IntroKind.none;
  bool _marked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The full intro plays once per version: mark it as seen when it starts,
    // so a skip or a kill mid-intro still counts.
    if (!_marked && widget.kind == IntroKind.full) {
      _marked = true;
      final settings = AppServices.of(context).settings;
      // After the first frame: saving notifies the app's settings listener,
      // which must not fire mid-build.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) =>
            settings.update((s) => s.copyWith(introSeenVersion: kAppVersion)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_showing) return widget.child;
    final reduced =
        AppServices.of(context).settings.settings.reducedMotion ||
        MediaQuery.of(context).disableAnimations;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        LapDrawIntro(
          kind: widget.kind,
          reducedMotion: reduced,
          onDone: () {
            if (mounted) setState(() => _showing = false);
          },
        ),
      ],
    );
  }
}
