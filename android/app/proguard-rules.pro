# R8 rules for release/dogfood builds. Flutter and play-services ship their own consumer
# rules; the Pigeon-generated channel classes are referenced directly, not reflectively.
# Keep the debug-intent entry points readable in stack traces.
-keepattributes SourceFile,LineNumberTable

# google_maps_flutter / play-services-maps ship consumer R8 rules (the map renderer itself
# lives in Play services, no bundled .so); the release AAB build in CI exercises them and
# the 16 KB gate covers anything they add. Nothing extra is needed here.
