package com.soum91.obsidian.tv;

import android.app.Activity;
import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.accessibilityservice.GestureDescription;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Path;
import android.graphics.Point;
import android.hardware.display.DisplayManager;
import android.view.Display;
import android.media.projection.MediaProjectionManager;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.MultiFormatWriter;
import com.google.zxing.common.BitMatrix;

import java.net.Inet4Address;
import java.net.NetworkInterface;
import java.util.Collections;

/** The TV owner explicitly grants each screen-sharing session. No hidden capture. */
public final class MainActivity extends Activity {
    private static final int REQUEST_CAPTURE = 417;
    private TextView status;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String host = localAddress();
        String secret = CompanionSecret.getOrCreate(this);

        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setGravity(Gravity.CENTER);
        body.setPadding(48, 20, 48, 20);
        body.setBackgroundColor(Color.rgb(18, 14, 30));

        TextView title = text("Obsidian TV Companion", 28, Color.WHITE);
        body.addView(title);
        TextView instruction = text("Scan with your iPhone Camera to pair this TV with Obsidian.", 17, 0xFFB9AFC5);
        body.addView(instruction);

        if (host != null) {
            ImageView qr = new ImageView(this);
            qr.setImageBitmap(qr("phosphor://live?host=" + host + "&key=" + secret));
            LinearLayout.LayoutParams qrParams = new LinearLayout.LayoutParams(260, 260);
            qrParams.setMargins(0, 14, 0, 10);
            body.addView(qr, qrParams);
            body.addView(text(host + ":8765", 15, Color.WHITE));
        } else {
            body.addView(text("Connect this TV to your home Wi-Fi first.", 18, 0xFFFF9999));
        }

        status = text("Screen sharing is off until you approve it on this TV.", 16, 0xFFB9AFC5);
        body.addView(status);

        Button start = new Button(this);
        start.setText("Start Live View");
        start.setOnClickListener(v -> requestCapture());
        start.setEnabled(host != null);
        body.addView(start);

        Button stop = new Button(this);
        stop.setText("Stop screen sharing");
        stop.setOnClickListener(v -> {
            Intent intent = new Intent(this, CaptureService.class);
            intent.setAction(CaptureService.ACTION_STOP);
            startService(intent);
            status.setText("Screen sharing stopped.");
        });
        body.addView(stop);

        TextView remote = text("Internet preview uses an encrypted connection while sharing is active. Enable accessibility control to send Home, Back and navigation commands remotely.", 14, 0xFFB9AFC5);
        body.addView(remote);
        Button enableControl = new Button(this);
        enableControl.setText("Enable remote control in Accessibility");
        enableControl.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        body.addView(enableControl);

        setContentView(body);
    }

    @Override protected void onResume() {
        super.onResume();
        if (status != null) {
            String captureState = CaptureService.active ? "Live View is active." : "Screen sharing is off.";
            String controlState = TVAccessibility.isActive() ? " Remote control enabled." : " Enable Obsidian Remote Control in Accessibility for touch and navigation.";
            status.setText(captureState + controlState);
        }
    }

    private void requestCapture() {
        MediaProjectionManager manager = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
        startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CAPTURE);
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != REQUEST_CAPTURE || result != RESULT_OK || data == null) return;
        Intent service = new Intent(this, CaptureService.class);
        service.setAction(CaptureService.ACTION_START);
        service.putExtra(CaptureService.EXTRA_RESULT, result);
        service.putExtra(CaptureService.EXTRA_DATA, data);
        startForegroundService(service);
        status.setText("Starting screen sharing…");
    }

    private TextView text(String value, float size, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        view.setGravity(Gravity.CENTER);
        view.setPadding(0, 8, 0, 8);
        return view;
    }

    private Bitmap qr(String value) {
        try {
            BitMatrix bits = new MultiFormatWriter().encode(value, BarcodeFormat.QR_CODE, 260, 260);
            Bitmap image = Bitmap.createBitmap(260, 260, Bitmap.Config.ARGB_8888);
            for (int y = 0; y < 260; y++) {
                for (int x = 0; x < 260; x++) image.setPixel(x, y, bits.get(x, y) ? Color.BLACK : Color.WHITE);
            }
            return image;
        } catch (Exception ignored) {
            return Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888);
        }
    }

    /** Prefer a private Wi-Fi/LAN IPv4 address, not a VPN or loopback interface. */
    static String localAddress() {
        try {
            for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!network.isUp() || network.isLoopback() || network.isVirtual()) continue;
                String name = network.getName().toLowerCase();
                if (name.startsWith("tun") || name.startsWith("ppp") || name.startsWith("wg")) continue;
                for (java.net.InetAddress address : Collections.list(network.getInetAddresses())) {
                    if (address instanceof Inet4Address && address.isSiteLocalAddress()) return address.getHostAddress();
                }
            }
        } catch (Exception ignored) { }
        return null;
    }

    /** Opt-in Android Accessibility actions, usable only after owner enables the service. */
    public static final class TVAccessibility extends AccessibilityService {
        private static volatile TVAccessibility instance;

        static boolean isActive() { return instance != null; }

        @Override protected void onServiceConnected() {
            super.onServiceConnected();
            AccessibilityServiceInfo info = getServiceInfo();
            if (info != null) {
                info.eventTypes = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
                        | AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
                        | AccessibilityEvent.TYPE_VIEW_FOCUSED;
                info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC;
                info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
                info.notificationTimeout = 100;
                setServiceInfo(info);
            }
            instance = this;
            android.util.Log.i("ObsidianLive", "Accessibility remote connected");
        }

        @Override public boolean onUnbind(Intent intent) {
            if (instance == this) instance = null;
            return super.onUnbind(intent);
        }

        @Override public void onDestroy() {
            if (instance == this) instance = null;
            super.onDestroy();
        }

        @Override public void onAccessibilityEvent(AccessibilityEvent event) { }
        @Override public void onInterrupt() { }

        static boolean execute(String key) {
            TVAccessibility service = instance;
            if (service == null) return false;
            if ("home".equals(key)) return service.performGlobalAction(GLOBAL_ACTION_HOME);
            if ("back".equals(key)) return service.performGlobalAction(GLOBAL_ACTION_BACK);
            AccessibilityNodeInfo root = service.getRootInActiveWindow();
            if (root == null) return false;
            AccessibilityNodeInfo current = null;
            try {
                current = root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY);
                if (current == null) current = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
                if (current == null) current = root;
                if ("ok".equals(key)) {
                    if (current.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true;
                    AccessibilityNodeInfo parent = current.getParent();
                    for (int depth = 0; depth < 3 && parent != null; depth++) {
                        try {
                            if (parent.isClickable() &&
                                    parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true;
                            AccessibilityNodeInfo above = parent.getParent();
                            parent.recycle();
                            parent = above;
                        } catch (RuntimeException e) {
                            parent.recycle();
                            return false;
                        }
                    }
                    if (parent != null) parent.recycle();
                    return false;
                }
                int direction;
                switch (key) {
                    case "up": direction = View.FOCUS_UP; break;
                    case "down": direction = View.FOCUS_DOWN; break;
                    case "left": direction = View.FOCUS_LEFT; break;
                    case "right": direction = View.FOCUS_RIGHT; break;
                    default: return false;
                }
                AccessibilityNodeInfo next = current.focusSearch(direction);
                if (next == null) return false;
                try {
                    return next.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
                            || next.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
                } finally {
                    next.recycle();
                }
            } finally {
                if (current != null && current != root) current.recycle();
                root.recycle();
            }
        }

        /** Coordinates are fractions of the TV's actual screen, never raw remote pixels. */
        static boolean gesture(double x, double y, Double toX, Double toY, int durationMs) {
            TVAccessibility service = instance;
            if (service == null || !inside(x) || !inside(y) ||
                    (toX != null && !inside(toX)) || (toY != null && !inside(toY))) return false;
            try {
                DisplayManager manager =
                        (DisplayManager) service.getSystemService(Context.DISPLAY_SERVICE);
                Display screen = manager == null ? null : manager.getDisplay(Display.DEFAULT_DISPLAY);
                if (screen == null) return false;
                Point size = new Point();
                screen.getRealSize(size);
                if (size.x < 2 || size.y < 2) return false;

                Path path = new Path();
                path.moveTo((float) (x * (size.x - 1)), (float) (y * (size.y - 1)));
                boolean swipe = toX != null && toY != null;
                if (swipe) path.lineTo((float) (toX * (size.x - 1)),
                        (float) (toY * (size.y - 1)));
                GestureDescription gesture = new GestureDescription.Builder()
                        .addStroke(new GestureDescription.StrokeDescription(
                                path, 0, swipe ? Math.max(120, Math.min(1200, durationMs)) : 90))
                        .build();
                return service.dispatchGesture(gesture, null, null);
            } catch (RuntimeException e) {
                android.util.Log.w("ObsidianLive", "Touch gesture rejected", e);
                return false;
            }
        }

        private static boolean inside(double value) {
            return !Double.isNaN(value) && !Double.isInfinite(value)
                    && value >= 0 && value <= 1;
        }
    }
}
