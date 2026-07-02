# Project-specific ProGuard/R8 rules.
# Keep Flutter plugin registrant and BLE plugin classes reachable in release builds.
-keep class io.flutter.plugins.** { *; }
-keep class com.lib.flutter_blue_plus.** { *; }
-keep class com.baseflow.permissionhandler.** { *; }
-dontwarn com.lib.flutter_blue_plus.**
-dontwarn com.baseflow.permissionhandler.**
