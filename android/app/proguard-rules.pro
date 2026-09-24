# R8 rules for release/dogfood builds. Flutter and play-services ship their own consumer
# rules; the Pigeon-generated channel classes are referenced directly, not reflectively.
# Keep the debug-intent entry points readable in stack traces.
-keepattributes SourceFile,LineNumberTable
