/// Run Solo analysis engine.
///
/// Pure Dart: no Flutter, no platform channels, no I/O. The only place verdict
/// logic lives (plan §2 rule 1).
library;

export 'src/engine/analysis.dart';
export 'src/engine/best_efforts.dart';
export 'src/engine/constants.dart';
export 'src/engine/fix_laps.dart';
export 'src/engine/format.dart';
export 'src/engine/hr_zone.dart';
export 'src/engine/max_hr.dart';
export 'src/engine/metrics.dart';
export 'src/engine/predictor.dart';
export 'src/engine/rep_detector.dart';
export 'src/engine/trace.dart';
export 'src/engine/verdict_builder.dart';
export 'src/engine_version.dart';
export 'src/import/gpx_importer.dart';
export 'src/import/import_dedupe.dart';
export 'src/import/import_util.dart';
export 'src/import/run_bundle.dart';
export 'src/import/tcx_exporter.dart';
export 'src/import/tcx_importer.dart';
export 'src/model/run_file.dart';
export 'src/model/session_catalogue.dart';
export 'src/model/session_spec.dart';
export 'src/model/sidecar.dart';
export 'src/model/verdict.dart';
export 'src/run_mode.dart';
