# Proguard rules for Cashew Pro (release build)
# flutter_local_notifications / Gson TypeToken preservation
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# Ensure AndroidX WorkManager worker reflection is preserved
-keep class * extends androidx.work.Worker { *; }
-keep class * extends androidx.work.ListenableWorker { *; }
