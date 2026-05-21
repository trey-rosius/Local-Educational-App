# MediaPipe ProGuard rules
-keep class com.google.mediapipe.** { *; }
-keep interface com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**

# TensorFlow Lite ProGuard rules
-keep class org.tensorflow.lite.** { *; }
-keep interface org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

# ObjectBox ProGuard rules
-keep class io.objectbox.** { *; }
-keep enum io.objectbox.** { *; }
-dontwarn io.objectbox.**

# Rive ProGuard rules
-keep class app.rive.** { *; }
-keep class com.rive.** { *; }
-dontwarn app.rive.**
