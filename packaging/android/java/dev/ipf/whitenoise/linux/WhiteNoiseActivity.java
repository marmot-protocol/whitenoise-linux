package dev.ipf.whitenoise.linux;

import android.app.AlertDialog;
import android.content.pm.PackageInfo;
import android.graphics.Color;
import android.graphics.Insets;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

import org.libsdl.app.SDLActivity;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.concurrent.CountDownLatch;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/** SDL owns the surface, input, native thread and pause/resume lifecycle. */
public final class WhiteNoiseActivity extends SDLActivity {
    private static final String ASSET_ROOT = "assets/whitenoise/";
    private static final String TAG = "WhiteNoise";
    private final CountDownLatch startupDismissed = new CountDownLatch(1);
    private volatile boolean closing;
    private LinearLayout startupView;
    private TextView startupText;
    private ProgressBar startupProgress;
    private File dataHome;
    private long lastProgressTime;

    @Override
    protected String[] getLibraries() {
        return new String[] {"SDL3", "main"};
    }

    @Override
    protected String[] getArguments() {
        return new String[] {dataHome.getAbsolutePath()};
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (mBrokenLibraries) {
            return;
        }
        // Android 15+ forces edge-to-edge. Resize SDL inside the system bars
        // and keyboard so the composer stays visible with local coordinates.
        if (Build.VERSION.SDK_INT >= 35) {
            mLayout.setOnApplyWindowInsetsListener((view, insets) -> {
                Insets bars =
                    insets.getInsets(WindowInsets.Type.systemBars() |
                                     WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
                return insets;
            });
            mLayout.requestApplyInsets();
        }
        startupView = new LinearLayout(this);
        startupView.setOrientation(LinearLayout.VERTICAL);
        startupView.setGravity(Gravity.CENTER);
        startupView.setPadding(48, 48, 48, 48);
        startupView.setBackgroundColor(Color.rgb(24, 26, 29));
        startupText = new TextView(this);
        startupText.setTextColor(Color.WHITE);
        startupText.setTextSize(18);
        startupText.setGravity(Gravity.CENTER);
        startupText.setText(R.string.preparing_resources);
        startupView.addView(startupText,
                            new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                          ViewGroup.LayoutParams.WRAP_CONTENT));
        startupProgress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        startupProgress.setIndeterminate(true);
        startupProgress.setMax(1000);
        startupView.addView(startupProgress,
                            new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                          ViewGroup.LayoutParams.WRAP_CONTENT));
        addContentView(startupView,
                       new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                  ViewGroup.LayoutParams.MATCH_PARENT));
    }

    // SDL calls this on SDLThread, never the Android UI thread. Native main
    // starts only after ordinary files exist for Odin's file and mmap users.
    @Override
    protected void main() {
        try {
            File files = getFilesDir();
            File config = directory(new File(files, "config"));
            File data = directory(new File(files, "data"));
            File cache = getCacheDir();
            dataHome = directory(new File(data, "whitenoise"));
            directory(new File(config, "whitenoise"));
            File resources = stageResources();
            checkClosing();
            String nativeDir = getApplicationInfo().nativeLibraryDir;
            nativeSetenv("HOME", files.getAbsolutePath());
            nativeSetenv("XDG_CONFIG_HOME", config.getAbsolutePath());
            nativeSetenv("XDG_DATA_HOME", data.getAbsolutePath());
            nativeSetenv("XDG_CACHE_HOME", cache.getAbsolutePath());
            nativeSetenv("TMPDIR", cache.getAbsolutePath());
            nativeSetenv("LD_LIBRARY_PATH", nativeDir);
            nativeSetenv("WN_RESOURCE_DIR", resources.getAbsolutePath());
            nativeSetenv("WN_HELPER_DIR", nativeDir);
            nativeSetenv("FONTCONFIG_PATH", resources.getAbsolutePath());
            nativeSetenv("FONTCONFIG_FILE", new File(resources, "fonts.conf").getAbsolutePath());
            nativeSetenv("SSL_CERT_FILE", new File(resources, "cacert.pem").getAbsolutePath());
            nativeSetenv("CURL_CA_BUNDLE", new File(resources, "cacert.pem").getAbsolutePath());
            runOnUiThread(() -> startupView.setVisibility(View.GONE));
            super.main();
        } catch (Exception error) {
            if (closing) {
                return;
            }
            Log.e(TAG, "Cannot prepare application resources", error);
            runOnUiThread(() -> {
                if (!closing) {
                    startupProgress.setVisibility(View.GONE);
                    startupText.setText(R.string.resources_failed);
                    new AlertDialog.Builder(this)
                        .setTitle(R.string.start_failed)
                        .setMessage(error.getMessage())
                        .setCancelable(false)
                        .setPositiveButton(R.string.close,
                                           (dialog, which) -> startupDismissed.countDown())
                        .show();
                }
            });
            try {
                startupDismissed.await();
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
        }
    }

    @Override
    protected void onDestroy() {
        closing = true;
        startupDismissed.countDown();
        super.onDestroy();
    }

    private void checkClosing() throws IOException {
        if (closing) {
            throw new IOException("Application closed during resource preparation");
        }
    }

    private static File directory(File path) throws IOException {
        if (!path.isDirectory() && !path.mkdirs()) {
            throw new IOException("Cannot create " + path);
        }
        return path;
    }

    private File stageResources() throws Exception {
        PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
        String version = info.getLongVersionCode() + "-" + info.lastUpdateTime;
        File root = directory(new File(getFilesDir(), "resources"));
        File ready = new File(root, version);
        if (ready.isDirectory()) {
            return ready;
        }
        File staging = new File(root, version + ".partial");
        removeTree(staging);
        directory(staging);
        try (ZipFile apk = new ZipFile(getApplicationInfo().sourceDir)) {
            ArrayList<ZipEntry> assets = new ArrayList<>();
            long total = 0;
            Enumeration<? extends ZipEntry> entries = apk.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                if (!entry.isDirectory() && entry.getName().startsWith(ASSET_ROOT)) {
                    assets.add(entry);
                    total += entry.getSize();
                }
            }
            if (assets.isEmpty()) {
                throw new IOException("APK contains no White Noise resources");
            }
            byte[] buffer = new byte[128 * 1024];
            long copied = 0;
            for (ZipEntry entry : assets) {
                checkClosing();
                String relative = entry.getName().substring(ASSET_ROOT.length());
                File output = new File(staging, relative);
                if (!output.getCanonicalPath().startsWith(staging.getCanonicalPath() +
                                                          File.separator)) {
                    throw new IOException("Invalid resource path: " + relative);
                }
                directory(output.getParentFile());
                try (InputStream input = apk.getInputStream(entry);
                     FileOutputStream out = new FileOutputStream(output)) {
                    int count;
                    while ((count = input.read(buffer)) != -1) {
                        checkClosing();
                        out.write(buffer, 0, count);
                        copied += count;
                        showProgress(relative, copied, total);
                    }
                }
            }
        }
        checkClosing();
        if (!staging.renameTo(ready)) {
            throw new IOException("Cannot finish resource installation: " + ready);
        }
        File[] previous = root.listFiles();
        if (previous != null) {
            for (File old : previous) {
                if (!old.equals(ready)) {
                    removeTree(old);
                }
            }
        }
        return ready;
    }

    private void showProgress(String resource, long copied, long total) {
        long now = SystemClock.uptimeMillis();
        if (now - lastProgressTime < 100 && copied != total) {
            return;
        }
        lastProgressTime = now;
        int progress = total > 0 ? (int)(copied * 1000 / total) : 0;
        String detail = getString(R.string.preparing_resources) + "\n" + resource + "\n" +
                        copied / (1024 * 1024) + " / " + total / (1024 * 1024) + " MiB";
        runOnUiThread(() -> {
            if (!closing) {
                startupText.setText(detail);
                startupProgress.setIndeterminate(total <= 0);
                startupProgress.setProgress(progress);
            }
        });
    }

    private void removeTree(File path) throws IOException {
        checkClosing();
        if (!path.exists()) {
            return;
        }
        File[] children = path.listFiles();
        if (children != null) {
            for (File child : children) {
                removeTree(child);
            }
        }
        if (!path.delete()) {
            throw new IOException("Cannot remove old resource: " + path);
        }
    }
}
