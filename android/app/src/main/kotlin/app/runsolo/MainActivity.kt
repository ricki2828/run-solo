package app.runsolo

import app.runsolo.platform.BleApi
import app.runsolo.platform.BleApiStub
import app.runsolo.platform.RecorderApi
import app.runsolo.platform.RecorderApiStub
import app.runsolo.platform.RecorderEventsStreamHandler
import app.runsolo.platform.RecorderEventsStub
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Phase 0: stub implementations so the channel contract compiles end to end.
        // run-native-fable replaces these with the RecorderService-backed implementations.
        RecorderApi.setUp(flutterEngine.dartExecutor.binaryMessenger, RecorderApiStub())
        BleApi.setUp(flutterEngine.dartExecutor.binaryMessenger, BleApiStub())
        RecorderEventsStreamHandler.register(flutterEngine.dartExecutor.binaryMessenger, RecorderEventsStub())
    }
}
