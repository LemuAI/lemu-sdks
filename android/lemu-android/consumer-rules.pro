# Lemu analytics consumer rules, applied to apps that use the SDK.

# Public API (also called from Java and other languages).
-keep class com.lemuai.analytics.Lemu { public *; }
-keep class com.lemuai.analytics.LemuOptions { public *; }
-keep class com.lemuai.analytics.LemuOptions$Builder { public *; }
-keep class com.lemuai.analytics.LemuEvent { public *; }
-keep class com.lemuai.analytics.LemuContent { public *; }
-keep class com.lemuai.analytics.LemuActivityScreenTracker { public *; }

# The Play Install Referrer library is optional; it is looked up by name at runtime.
-dontwarn com.android.installreferrer.**
-keep class com.android.installreferrer.api.InstallReferrerClient { *; }
