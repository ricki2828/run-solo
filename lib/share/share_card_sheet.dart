import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

import '../app/services.dart';
import '../map/route_builder.dart';
import '../theme/theme.dart';
import 'share_card.dart';

/// Shows the card and a SHARE button. [route] is offered as a "Show map"
/// switch (off by default) only for a run that has one. Nothing leaves the
/// phone except through the system share sheet, and only when the runner
/// taps SHARE.
Future<void> showShareCardSheet(
  BuildContext context, {
  required ShareCardData data,
  List<GeoPoint> route = const [],
  Future<Directory> Function()? tempDir,
}) {
  final t = Theme.of(context).extension<RunSoloTokens>()!;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: t.bgBase,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
    ),
    builder: (_) => ShareCardSheet(data: data, route: route, tempDir: tempDir),
  );
}

class ShareCardSheet extends StatefulWidget {
  const ShareCardSheet({
    super.key,
    required this.data,
    this.route = const [],
    this.tempDir,
  });

  final ShareCardData data;
  final List<GeoPoint> route;
  final Future<Directory> Function()? tempDir;

  @override
  State<ShareCardSheet> createState() => _ShareCardSheetState();
}

class _ShareCardSheetState extends State<ShareCardSheet> {
  final _boundary = GlobalKey();
  bool _showMap = false;
  bool _busy = false;
  String? _error;

  ShareCardData get _data {
    final d = widget.data;
    return d is RunCardData && _showMap ? d.withRoute(widget.route) : d;
  }

  /// The card as a 1080 x 1350 PNG.
  Future<File> _render() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: kShareCardPixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('no image');
    final dir = await (widget.tempDir ?? getTemporaryDirectory)();
    // One fixed name: each share replaces the last, so nothing piles up.
    final file = File('${dir.path}/run-supreme-card.png');
    return file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  }

  Future<void> _share() async {
    final transfer = AppServices.of(context).transfer;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await _render();
      await transfer.shareFiles(
        [file.path],
        subject: 'Run Supreme',
        mimeType: 'image/png',
      );
    } on Object {
      if (mounted) setState(() => _error = 'Could not make the image.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final canMap = widget.data is RunCardData && widget.route.length >= 2;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Space.screenGutter,
          0,
          Space.screenGutter,
          Space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.card),
                  child: FittedBox(
                    child: RepaintBoundary(
                      key: _boundary,
                      child: ShareCard(data: _data),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.x12),
            if (canMap)
              SwitchListTile(
                key: const ValueKey('share-show-map'),
                contentPadding: EdgeInsets.zero,
                value: _showMap,
                onChanged: (v) => setState(() => _showMap = v),
                title: Text(
                  'Show map',
                  style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                ),
                subtitle: Text(
                  'Adds the shape of your route. Off keeps where you ran private.',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ),
            Text(
              'Made on your phone. Nothing is uploaded.',
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.x8),
              Text(
                _error!,
                style: RunSoloType.body15.copyWith(color: t.semDanger),
              ),
            ],
            const SizedBox(height: Space.x16),
            FilledButton(
              key: const ValueKey('share-card-go'),
              onPressed: _busy ? null : _share,
              child: Text(_busy ? 'MAKING IT...' : 'SHARE'),
            ),
          ],
        ),
      ),
    );
  }
}
