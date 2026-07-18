package dev.wighawag.wezig;

import android.app.Activity;
import android.os.Bundle;
import android.webkit.WebView;

/**
 * The wezig Android shell (toolchain proof): loads the wezig JNI shared object
 * (which links the Zig static core), calls into the Zig C-ABI to prove linkage,
 * and shows one WebView whose HTML embeds the Zig-provided greeting.
 *
 * This is NOT a full app — no chrome, no navigation UI yet (those arrive with
 * the downstream mobile renderer/embedding tasks). It is the narrowest real
 * case: one WebView launched from a Zig-hosted APK.
 */
public class MainActivity extends Activity {

    static {
        // Loads libwezigshell.so (the JNI shim + the linked Zig static core).
        System.loadLibrary("wezigshell");
    }

    /** Implemented in wezig_jni.c; calls the Zig core and returns its greeting. */
    private native String nativeGreeting();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        String greeting = nativeGreeting();

        WebView webView = new WebView(this);
        String html =
            "<!doctype html><html><head><meta name=\"viewport\" "
            + "content=\"width=device-width, initial-scale=1\"></head>"
            + "<body style=\"font-family:sans-serif;padding:2rem\">"
            + "<h1>wezig Android shell</h1>"
            + "<p>Zig core linked</p>"
            + "<p>" + greeting + "</p>"
            + "</body></html>";
        webView.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);

        setContentView(webView);
    }
}
