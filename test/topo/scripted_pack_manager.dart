import 'dart:io';

import 'package:run_solo/topo/pack_manager.dart';
import 'package:run_solo/topo/pack_models.dart';

PackRegion fixtureRegion(
  String id,
  String name,
  int bytes, {
  String version = '20261002',
}) => PackRegion(
  id: id,
  name: name,
  bbox: const [0, 0, 1, 1],
  version: version,
  files: [PackFileSpec(name: 'basemap.pmtiles', size: bytes, sha256: 'aa')],
  mapText: '© OpenStreetMap contributors | Protomaps | © Mapterhorn',
  credits: const [
    PackCredit(
      text: '© OpenStreetMap contributors',
      license: 'ODbL 1.0 (Produced Work)',
      url: 'https://www.openstreetmap.org/copyright',
    ),
    PackCredit(text: '© Mapterhorn', url: 'https://mapterhorn.com/attribution'),
  ],
);

/// A PackManager whose state is set by the test, so every Settings state can
/// be shown without a network or disk. Calls are recorded.
class ScriptedPackManager extends PackManager {
  ScriptedPackManager({
    this.scriptedRegions = const [],
    this.statuses = const {},
    this.used = 0,
    this.wifiProbe = true,
    super.capBytes,
  }) : super(root: Directory.systemTemp);

  List<PackRegion> scriptedRegions;
  Map<String, PackStatus> statuses;
  int used;
  bool wifiProbe;
  bool busy = false;
  final List<String> calls = [];

  @override
  List<PackRegion> get regions => scriptedRegions;

  @override
  List<InstalledPack> get installed => [
    for (final r in scriptedRegions)
      if (statuses[r.id]?.kind == PackStatusKind.installed ||
          statuses[r.id]?.kind == PackStatusKind.updateAvailable)
        InstalledPack(region: r, directory: '/x/${r.id}'),
  ];

  @override
  int get usedBytes => used;

  @override
  bool get refreshing => busy;

  @override
  bool get canEnforceWifiOnly => wifiProbe;

  bool wifiOn = true;

  @override
  bool get wifiOnly => wifiOn;

  @override
  Future<void> setWifiOnly(bool on) async {
    calls.add('wifi:$on');
    wifiOn = on;
    notifyListeners();
  }

  @override
  PackStatus statusOf(String id) =>
      statuses[id] ?? const PackStatus(PackStatusKind.notInstalled);

  @override
  int? shortfall(PackRegion region) {
    final after = used + region.totalBytes;
    return after > capBytes ? after - capBytes : null;
  }

  @override
  Future<void> refreshRegions() async => calls.add('refresh');

  @override
  Future<bool> download(String id) async {
    calls.add('download:$id');
    return true;
  }

  @override
  void cancel(String id) => calls.add('cancel:$id');

  @override
  Future<void> delete(String id) async {
    calls.add('delete:$id');
  }
}
