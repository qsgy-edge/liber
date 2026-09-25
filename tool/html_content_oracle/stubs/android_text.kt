// `android.text.TextUtils`, for the compile **and run** classpath.
//
// `AnalyzeRule.getString`/`getString`/`getElement` guard their rule text with
// `TextUtils.isEmpty` (`AnalyzeRule.kt:247,253,329`), so the call is on the
// deciding path of every corpus case, and the Android SDK's compile-only stub
// jar answers it with `RuntimeException("Stub!")`. The platform's own member is
// two lines and decides nothing about the frozen app, so it is supplied here
// with AOSP's implementation and this class is ordered ahead of `android.jar`
// on the run classpath.
//
// `android.jar` itself stays on both classpaths: the frozen `modules/rhino`
// reads `android.os.Build.VERSION.SDK_INT` for its class shutter, and the SDK
// jar's zero is what a desktop JVM answers for it.
package android.text

/** AOSP `android.text.TextUtils.isEmpty(CharSequence)`. */
object TextUtils {
    fun isEmpty(str: CharSequence?): Boolean = str == null || str.isEmpty()
}
