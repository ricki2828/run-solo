import 'package:flutter/material.dart';

import '../app/services.dart';
import '../theme/theme.dart';
import '../topo/pack_manager.dart';
import '../topo/pack_models.dart';
import '../widgets/chrome.dart';

const String kOfflineMapsIntro =
    'Download a region to use the Topo map with no signal. Packs come from '
    'our map host; the download reveals only which pack you chose and your '
    'IP address.';

/// "12 MB", "1.2 GB". Decimal units, like the phone's own storage page.
String formatPackBytes(int bytes) {
  if (bytes >= 1000 * 1000 * 1000) {
    return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  }
  if (bytes >= 10 * 1000 * 1000) return '${(bytes / 1e6).round()} MB';
  if (bytes >= 1000 * 1000) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
  if (bytes >= 1000) return '${(bytes / 1e3).round()} KB';
  return '$bytes B';
}

/// Settings > Offline maps: what is on the phone, what can be downloaded,
/// and how much room it takes. Every network call here starts from a tap.
class OfflineMapsScreen extends StatefulWidget {
  const OfflineMapsScreen({super.key});

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  /// Last refresh failure, shown above the list until the next try.
  String? _listError;
  String? _listDetail;

  Future<void> _refresh(PackManager m) async {
    setState(() {
      _listError = null;
      _listDetail = null;
    });
    try {
      await m.refreshRegions();
    } on PackException catch (e) {
      if (mounted) {
        setState(() {
          _listError = e.message;
          _listDetail = e.detail;
        });
      }
    }
  }

  Future<void> _download(PackManager m, PackRegion r) async {
    try {
      await m.download(r.id);
    } on PackException {
      // The row shows the reason from the manager's status.
    }
  }

  Future<void> _confirmDelete(PackManager m, PackRegion r) async {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sheet),
        ),
        title: Text(
          'DELETE ${r.name.toUpperCase()}?',
          style: RunSoloType.title28.copyWith(color: t.inkPrimary),
        ),
        content: Text(
          'This frees ${formatPackBytes(r.totalBytes)}. You can download it '
          'again any time.',
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'KEEP',
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
          ),
          TextButton(
            key: const ValueKey('confirm-delete'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'DELETE',
              style: RunSoloType.body15.copyWith(color: t.semDanger),
            ),
          ),
        ],
      ),
    );
    if (ok == true) await m.delete(r.id);
  }

  void _credits(PackRegion r) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sheet),
        ),
        title: Text(
          'MAP DATA',
          style: RunSoloType.title28.copyWith(color: t.inkPrimary),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in r.credits) ...[
                Text(
                  c.text,
                  style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                ),
                if (c.license != null)
                  Text(
                    'Licence: ${c.license}',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                if (c.url != null)
                  Text(
                    c.url!,
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                const SizedBox(height: Space.x12),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'CLOSE',
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final m = AppServices.of(context).topo;
    return Scaffold(
      appBar: AppBar(title: const Text('OFFLINE MAPS')),
      body: m == null
          ? const SizedBox.shrink()
          : ListenableBuilder(
              listenable: m,
              builder: (context, _) {
                final regions = m.regions;
                return ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.screenGutter,
                  ),
                  children: [
                    const SizedBox(height: Space.x12),
                    Text(
                      kOfflineMapsIntro,
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                    const SizedBox(height: Space.x16),
                    _StorageMeter(manager: m),
                    if (m.canEnforceWifiOnly) _WifiRow(manager: m),
                    const _Heading('Regions'),
                    if (regions.isEmpty)
                      _EmptyList(
                        busy: m.refreshing,
                        error: _listError,
                        errorDetail: _listDetail,
                        onGet: () => _refresh(m),
                      )
                    else ...[
                      for (final r in regions)
                        _RegionRow(
                          key: ValueKey('region-${r.id}'),
                          region: r,
                          manager: m,
                          onDownload: () => _download(m, r),
                          onDelete: () => _confirmDelete(m, r),
                          onCredits: () => _credits(r),
                        ),
                      const SizedBox(height: Space.x16),
                      if (_listError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.x8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _listError!,
                                key: const ValueKey('list-error'),
                                style: RunSoloType.label13.copyWith(
                                  color: t.semWarn,
                                ),
                              ),
                              if (_listDetail != null)
                                Text(
                                  _listDetail!,
                                  key: const ValueKey('list-error-detail'),
                                  style: RunSoloType.label13.copyWith(
                                    color: t.inkSecondary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      _OutlineAction(
                        key: const ValueKey('refresh-list'),
                        label: m.refreshing ? 'CHECKING' : 'CHECK FOR NEW MAPS',
                        onTap: m.refreshing ? null : () => _refresh(m),
                      ),
                    ],
                    const SizedBox(height: Space.x24),
                    // The credit once for the screen, not under every region.
                    for (final (i, text) in {
                      for (final r in regions)
                        if (r.mapText.isNotEmpty) r.mapText,
                    }.indexed)
                      Text(
                        text,
                        key: ValueKey('map-credit-$i'),
                        style: RunSoloType.micro11.copyWith(color: t.inkMuted),
                      ),
                    const SizedBox(height: Space.x32),
                  ],
                );
              },
            ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: Space.x24, bottom: Space.x8),
      child: Text(
        title.toUpperCase(),
        style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
      ),
    );
  }
}

class _StorageMeter extends StatelessWidget {
  const _StorageMeter({required this.manager});
  final PackManager manager;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final used = manager.usedBytes;
    final cap = manager.capBytes;
    final frac = cap == 0 ? 1.0 : (used / cap).clamp(0.0, 1.0);
    final nearFull = frac >= 0.9;
    return Semantics(
      label: 'Offline maps storage',
      value: '${formatPackBytes(used)} of ${formatPackBytes(cap)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Storage used',
                  style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                ),
              ),
              Text(
                '${formatPackBytes(used)} of ${formatPackBytes(cap)}',
                key: const ValueKey('storage-text'),
                style: RunSoloType.label13.copyWith(
                  color: nearFull ? t.semWarn : t.inkSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.x8),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.chip),
            child: LinearProgressIndicator(
              key: const ValueKey('storage-bar'),
              value: frac,
              minHeight: 8,
              backgroundColor: t.bgRaised,
              color: nearFull ? t.semWarn : t.inkPrimary,
            ),
          ),
          if (nearFull)
            Padding(
              padding: const EdgeInsets.only(top: Space.x8),
              child: Text(
                'Nearly full. Delete a map to make room for another.',
                key: const ValueKey('storage-warning'),
                style: RunSoloType.label13.copyWith(color: t.semWarn),
              ),
            ),
        ],
      ),
    );
  }
}

class _WifiRow extends StatelessWidget {
  const _WifiRow({required this.manager});
  final PackManager manager;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      margin: const EdgeInsets.only(top: Space.x12),
      constraints: const BoxConstraints(minHeight: 64),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: t.lineHair),
          bottom: BorderSide(color: t.lineHair),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Download on Wi-Fi only',
                  style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                ),
                Text(
                  'Maps are big. Mobile data stays untouched.',
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ],
            ),
          ),
          Semantics(
            label: 'Download on Wi-Fi only',
            child: Switch(
              key: const ValueKey('wifi-only'),
              value: manager.wifiOnly,
              onChanged: manager.setWifiOnly,
              activeThumbColor: t.bgBase,
              activeTrackColor: t.inkPrimary,
              inactiveThumbColor: t.inkSecondary,
              inactiveTrackColor: t.bgRaised,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({
    required this.busy,
    required this.error,
    required this.errorDetail,
    required this.onGet,
  });
  final bool busy;
  final String? error;
  final String? errorDetail;
  final VoidCallback onGet;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      key: const ValueKey('maps-empty'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          error ?? 'No maps listed yet. Get the list to see what is on offer.',
          style: RunSoloType.body15.copyWith(
            color: error == null ? t.inkSecondary : t.semWarn,
          ),
        ),
        if (error != null && errorDetail != null)
          Text(
            errorDetail!,
            key: const ValueKey('list-error-detail'),
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
        const SizedBox(height: Space.x16),
        _OutlineAction(
          key: const ValueKey('get-list'),
          label: busy
              ? 'GETTING THE LIST'
              : (error == null ? 'GET THE MAP LIST' : 'TRY AGAIN'),
          onTap: busy ? null : onGet,
        ),
      ],
    );
  }
}

class _RegionRow extends StatelessWidget {
  const _RegionRow({
    super.key,
    required this.region,
    required this.manager,
    required this.onDownload,
    required this.onDelete,
    required this.onCredits,
  });
  final PackRegion region;
  final PackManager manager;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onCredits;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final status = manager.statusOf(region.id);
    final size = formatPackBytes(region.totalBytes);
    final short = manager.shortfall(region);
    final kind = status.kind;
    final canGet =
        kind == PackStatusKind.notInstalled ||
        kind == PackStatusKind.updateAvailable ||
        kind == PackStatusKind.failed;
    final blocked = canGet && short != null;

    final (String sub, Color subColor) = switch (kind) {
      PackStatusKind.installed => ('Installed, $size', t.inkSecondary),
      PackStatusKind.updateAvailable => ('Update ready, $size', t.inkPrimary),
      PackStatusKind.downloading => (
        '${(status.progress * 100).floor()}% of $size',
        t.inkPrimary,
      ),
      PackStatusKind.failed => (
        [
          status.error?.message ?? 'The download failed.',
          if (status.error?.detail != null) status.error!.detail!,
        ].join('\n'),
        t.semWarn,
      ),
      PackStatusKind.notInstalled => (
        status.partialBytes > 0
            ? '$size, ${formatPackBytes(status.partialBytes)} already downloaded'
            : size,
        t.inkSecondary,
      ),
    };

    final actionLabel = switch (kind) {
      PackStatusKind.updateAvailable => 'UPDATE',
      PackStatusKind.failed => 'TRY AGAIN',
      PackStatusKind.notInstalled =>
        status.partialBytes > 0 ? 'RESUME' : 'DOWNLOAD',
      _ => null,
    };

    return Container(
      padding: const EdgeInsets.symmetric(vertical: Space.x12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineHair)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      region.name,
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      key: ValueKey('sub-${region.id}'),
                      style: RunSoloType.label13.copyWith(color: subColor),
                    ),
                  ],
                ),
              ),
              if (kind == PackStatusKind.installed)
                const StatusPill(label: 'ON PHONE', tone: PillTone.ok),
            ],
          ),
          if (kind == PackStatusKind.downloading) ...[
            const SizedBox(height: Space.x8),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.chip),
              child: LinearProgressIndicator(
                key: ValueKey('progress-${region.id}'),
                value: status.progress,
                minHeight: 6,
                backgroundColor: t.bgRaised,
                color: t.inkPrimary,
              ),
            ),
          ],
          if (blocked)
            Padding(
              padding: const EdgeInsets.only(top: Space.x8),
              child: Text(
                'Needs ${formatPackBytes(short)} more room. Delete a map to '
                'make space.',
                key: ValueKey('low-${region.id}'),
                style: RunSoloType.label13.copyWith(color: t.semWarn),
              ),
            ),
          const SizedBox(height: Space.x8),
          Wrap(
            spacing: Space.x8,
            runSpacing: Space.x8,
            children: [
              if (actionLabel != null)
                _OutlineAction(
                  key: ValueKey('get-${region.id}'),
                  label: actionLabel,
                  onTap: blocked ? null : onDownload,
                ),
              if (kind == PackStatusKind.downloading)
                _OutlineAction(
                  key: ValueKey('cancel-${region.id}'),
                  label: 'STOP',
                  onTap: () => manager.cancel(region.id),
                ),
              if (kind == PackStatusKind.installed ||
                  kind == PackStatusKind.updateAvailable)
                _OutlineAction(
                  key: ValueKey('delete-${region.id}'),
                  label: 'DELETE',
                  onTap: onDelete,
                ),
              if (region.credits.isNotEmpty)
                _OutlineAction(
                  key: ValueKey('credits-${region.id}'),
                  label: 'MAP DATA',
                  onTap: onCredits,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OutlineAction extends StatelessWidget {
  const _OutlineAction({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        foregroundColor: t.inkPrimary,
        disabledForegroundColor: t.inkMuted,
        side: BorderSide(color: t.lineHair),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.button),
        ),
      ),
      child: Text(label, style: RunSoloType.body15),
    );
  }
}
