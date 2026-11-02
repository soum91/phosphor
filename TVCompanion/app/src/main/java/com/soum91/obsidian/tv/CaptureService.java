package com.soum91.obsidian.tv;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.SystemClock;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicReference;

/** User-approved Android MediaProjection + hardware-backed virtual display. */
public final class CaptureService extends Service {
    public static final String ACTION_START = "com.soum91.obsidian.live.START";
    public static final String ACTION_STOP = "com.soum91.obsidian.live.STOP";
    public static final String EXTRA_RESULT = "capture_result";
    public static final String EXTRA_DATA = "capture_data";
    public static volatile boolean active;

    private MediaProjection projection;
    private VirtualDisplay display;
    private ImageReader reader;
    private HandlerThread encoderThread;
    private ViewerServer server;
    private final AtomicReference<byte[]> latestJPEG = new AtomicReference<>();
    private long lastFrame;

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || ACTION_STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (!ACTION_START.equals(intent.getAction()) || active) return START_NOT_STICKY;
        NotificationManager notifications = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        notifications.createNotificationChannel(new NotificationChannel("obsidian-live", "Obsidian Live View", NotificationManager.IMPORTANCE_LOW));
        Notification notification = new Notification.Builder(this, "obsidian-live")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setContentTitle("Obsidian Live View")
                .setContentText("Your TV screen is being shared. Open the companion to stop.")
                .setOngoing(true)
                .build();
        startForeground(9, notification);

        int resultCode = intent.getIntExtra(EXTRA_RESULT, 0);
        Intent captureIntent = Build.VERSION.SDK_INT >= 33
                ? intent.getParcelableExtra(EXTRA_DATA, Intent.class)
                : (Intent) intent.getParcelableExtra(EXTRA_DATA);
        if (resultCode == 0 || captureIntent == null) { stopSelf(); return START_NOT_STICKY; }

        try {
            MediaProjectionManager manager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            projection = manager.getMediaProjection(resultCode, captureIntent);
            encoderThread = new HandlerThread("obsidian-frame-encoder");
            encoderThread.start();
            Handler encoder = new Handler(encoderThread.getLooper());
            projection.registerCallback(new MediaProjection.Callback() {
                @Override public void onStop() { stopSelf(); }
            }, encoder);

            android.util.DisplayMetrics metrics = getResources().getDisplayMetrics();
            int sourceWidth = metrics.widthPixels;
            int sourceHeight = metrics.heightPixels;
            int captureWidth = Math.max(2, ((Math.min(sourceWidth, 960) + 1) / 2) * 2);
            int captureHeight = Math.max(2, ((int) Math.round((double) sourceHeight * captureWidth / sourceWidth) / 2) * 2);
            reader = ImageReader.newInstance(captureWidth, captureHeight, PixelFormat.RGBA_8888, 2);
            reader.setOnImageAvailableListener(this::encodeLatestImage, encoder);
            display = projection.createVirtualDisplay("Obsidian Live View", captureWidth, captureHeight,
                    metrics.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    reader.getSurface(), null, encoder);
            server = new ViewerServer(this, latestJPEG);
            server.start();
            active = true;
        } catch (Exception failure) {
            android.util.Log.e("ObsidianLive", "Could not start screen projection", failure);
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    private void encodeLatestImage(ImageReader source) {
        Image image = source.acquireLatestImage();
        if (image == null) return;
        try {
            long now = SystemClock.elapsedRealtime();
            if (now - lastFrame < 160) return; // ~6 fps ceiling; stable on entry-level TVs.
            lastFrame = now;

            Image.Plane plane = image.getPlanes()[0];
            int rowPadding = plane.getRowStride() - plane.getPixelStride() * image.getWidth();
            int paddedWidth = image.getWidth() + rowPadding / plane.getPixelStride();
            Bitmap padded = Bitmap.createBitmap(paddedWidth, image.getHeight(), Bitmap.Config.ARGB_8888);
            ByteBuffer pixels = plane.getBuffer();
            pixels.rewind();
            padded.copyPixelsFromBuffer(pixels);
            Bitmap cropped = Bitmap.createBitmap(padded, 0, 0, image.getWidth(), image.getHeight());
            ByteArrayOutputStream output = new ByteArrayOutputStream(140_000);
            cropped.compress(Bitmap.CompressFormat.JPEG, 67, output);
            latestJPEG.set(output.toByteArray());
            cropped.recycle();
            padded.recycle();
        } catch (RuntimeException error) {
            android.util.Log.w("ObsidianLive", "Skipping unreadable frame", error);
        } finally {
            image.close();
        }
    }

    @Override public void onDestroy() {
        active = false;
        if (server != null) server.stop();
        if (display != null) display.release();
        if (reader != null) reader.close();
        if (projection != null) projection.stop();
        if (encoderThread != null) encoderThread.quitSafely();
        super.onDestroy();
    }
}
