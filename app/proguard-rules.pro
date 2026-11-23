# LSPosed loads this class by name from assets/xposed_init, so nothing in the
# code references it and R8 would otherwise strip it. Removing this rule makes
# the module build fine and do nothing at runtime.
-keep class com.xxxy.cctiles.Hook { *; }
-keepnames class com.xxxy.cctiles.Hook
