package com.soum91.obsidian.tv;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.media.projection.MediaProjectionManager;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
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

        setContentView(body);
    }

    @Override protected void onResume() {
        super.onResume();
        if (status != null && CaptureService.active) status.setText("Live View is active on your local network.");
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
}
