# Equivalent of AGP's proguard-android.txt defaults, written out because the
# build does not run AGP and cannot read the bundled file.
-dontobfuscate
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# Activities, services, receivers and providers are named in the manifest as
# strings, which nothing in the bytecode references.
-keep public class * extends android.app.Activity
-keep public class * extends android.app.Application
-keep public class * extends android.app.Service
-keep public class * extends android.content.BroadcastReceiver
-keep public class * extends android.content.ContentProvider

# Custom Views are inflated from layout XML by name.
-keep public class * extends android.view.View {
    public <init>(android.content.Context);
    public <init>(android.content.Context, android.util.AttributeSet);
    public <init>(android.content.Context, android.util.AttributeSet, int);
}

# Kotlin and the libraries Termux uses reach their entry points reflectively.
-keep class kotlin.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class androidx.window.** { *; }
-keep class org.lsposed.** { *; }
-keep class com.termux.** { *; }
-keep class com.google.common.** { *; }
-keep class org.commonmark.** { *; }
-keep class io.noties.** { *; }

# R classes for libraries are generated into the program, not shipped as
# library bytecode, so R8 treats them as unreachable and strips them. They are
# referenced only as `androidx.appcompat.R$style` type descriptors.
-keep class **.R { *; }
-keep class **.R$* { *; }
