package com.soum91.obsidian.tv;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.AudioManager;

import org.eclipse.paho.client.mqttv3.MqttCallback;
import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.LinkedHashSet;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicReference;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Local-network-only frame transport. No bearer tokens or raw frames travel in
 * plaintext: every request uses HMAC-SHA256, every JPEG uses AES-256-GCM.
 * No public internet listener. A separate outbound, end-to-end encrypted MQTT
 * connection supports low-rate remote preview only while screen sharing is on.
 */
final class ViewerServer {
    private static final String BROKER = "ssl://broker.emqx.io:8883";
    private final AtomicReference<byte[]> latest;
    private final byte[] secret;
    private final Context context;
    private final String relayTopic;
    private final ExecutorService clients = Executors.newFixedThreadPool(3);
    private final SecureRandom random = new SecureRandom();
    private final Set<String> seenRequests = new LinkedHashSet<>();
    private ServerSocket listener;
    private volatile boolean running;
    private volatile MqttClient relay;
    private Thread relayWorker;

    ViewerServer(Context context, AtomicReference<byte[]> latest) {
        this.context = context.getApplicationContext();
        this.latest = latest;
        this.secret = Base64.getUrlDecoder().decode(CompanionSecret.getOrCreate(context));
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(secret);
            StringBuilder id = new StringBuilder();
            for (int i = 0; i < 16; i++) id.append(String.format(Locale.ROOT, "%02x", hash[i] & 255));
            relayTopic = "obsidian/" + id;
        } catch (Exception e) {
            throw new IllegalStateException("Cannot derive relay device identity", e);
        }
    }

    void start() throws Exception {
        String address = MainActivity.localAddress();
        if (address == null) throw new IllegalStateException("No private LAN address");
        listener = new ServerSocket();
        listener.setReuseAddress(true);
        listener.bind(new InetSocketAddress(InetAddress.getByName(address), 8765));
        Thread accept = new Thread(() -> {
            while (!listener.isClosed()) {
                try {
                    Socket socket = listener.accept();
                    socket.setSoTimeout(2500);
                    clients.execute(() -> serve(socket));
                } catch (Exception e) {
                    if (!listener.isClosed()) android.util.Log.w("ObsidianLive", "Connection failed", e);
                }
            }
        }, "obsidian-local-viewer");
        accept.setDaemon(true);
        accept.start();
        running = true;
        relayWorker = new Thread(this::relayLoop, "obsidian-encrypted-relay");
        relayWorker.setDaemon(true);
        relayWorker.start();
    }

    void stop() {
        running = false;
        try { if (listener != null) listener.close(); } catch (Exception ignored) { }
        if (relayWorker != null) relayWorker.interrupt();
        MqttClient mq = relay;
        if (mq != null) {
            try { mq.disconnectForcibly(100, 100); } catch (Exception ignored) { }
            try { mq.close(); } catch (Exception ignored) { }
        }
        clients.shutdownNow();
    }

    /** An outgoing TLS connection. No TV port is exposed to the internet. */
    private void relayLoop() {
        try {
            MqttClient mq = new MqttClient(BROKER,
                    "obsidian-tv-" + relayTopic.substring("obsidian/".length()),
                    new MemoryPersistence());
            relay = mq;
            mq.setCallback(new MqttCallback() {
                @Override public void connectionLost(Throwable cause) {
                    android.util.Log.i("ObsidianLive", "Relay disconnected");
                }
                @Override public void deliveryComplete(org.eclipse.paho.client.mqttv3.IMqttDeliveryToken token) { }
                @Override public void messageArrived(String topic, MqttMessage message) {
                    if (message.getPayload().length > 2048 || !topic.equals(relayTopic + "/req")) return;
                    try {
                        clients.execute(() -> serveRelay(message.getPayload()));
                    } catch (java.util.concurrent.RejectedExecutionException ignored) { }
                }
            });
            MqttConnectOptions options = new MqttConnectOptions();
            options.setCleanSession(true);
            options.setKeepAliveInterval(45);
            options.setConnectionTimeout(7);
            while (running && !Thread.currentThread().isInterrupted()) {
                if (!mq.isConnected()) {
                    try {
                        mq.connect(options);
                        mq.subscribe(relayTopic + "/req", 0);
                    } catch (Exception e) {
                        android.util.Log.i("ObsidianLive", "Relay retrying: " + e.getClass().getSimpleName());
                    }
                }
                Thread.sleep(4000);
            }
        } catch (Exception e) {
            if (running) android.util.Log.w("ObsidianLive", "Relay stopped", e);
        }
    }

    /** The broker only sees ciphertext. IDs and timestamps prevent replayed commands. */
    private void serveRelay(byte[] payload) {
        try {
            byte[] clear = decrypt(Base64.getDecoder().decode(payload));
            JSONObject request = new JSONObject(new String(clear, StandardCharsets.UTF_8));
            String id = request.optString("i", "");
            long timestamp = request.optLong("t", 0);
            if (id.length() < 8 || id.length() > 64 ||
                    Math.abs(System.currentTimeMillis() / 1000 - timestamp) > 60) return;
            synchronized (seenRequests) {
                if (!seenRequests.add(id)) return;
                if (seenRequests.size() > 100) seenRequests.remove(seenRequests.iterator().next());
            }

            String action = request.optString("a", "");
            JSONObject response = new JSONObject();
            response.put("i", id);
            if ("frame".equals(action)) {
                byte[] preview = remotePreview();
                response.put("c", preview == null ? 503 : 200);
                if (preview != null) response.put("b", Base64.getEncoder().encodeToString(preview));
            } else if ("status".equals(action)) {
                response.put("c", 200);
                response.put("b", "Screen sharing approved on TV");
            } else if ("command".equals(action) || "tap".equals(action) || "swipe".equals(action)) {
                boolean accepted;
                if ("command".equals(action)) {
                    accepted = control(request.optString("k", ""));
                } else {
                    boolean swipe = "swipe".equals(action);
                    accepted = MainActivity.TVAccessibility.gesture(
                            request.optDouble("x", Double.NaN),
                            request.optDouble("y", Double.NaN),
                            swipe ? request.optDouble("x2", Double.NaN) : null,
                            swipe ? request.optDouble("y2", Double.NaN) : null,
                            request.optInt("ms", 300));
                }
                response.put("c", accepted ? 200 : (MainActivity.TVAccessibility.isActive() ? 422 : 409));
                response.put("b", controlMessage(accepted));
            } else {
                response.put("c", 400);
                response.put("b", "Unknown request");
            }
            MqttClient mq = relay;
            if (running && mq != null && mq.isConnected()) {
                byte[] encrypted = Base64.getEncoder().encode(encrypt(response.toString().getBytes(StandardCharsets.UTF_8)));
                if (encrypted.length < 110_000) {
                    MqttMessage reply = new MqttMessage(encrypted);
                    reply.setQos(0);
                    reply.setRetained(false);
                    mq.publish(relayTopic + "/res", reply);
                }
            }
        } catch (Exception e) {
            android.util.Log.d("ObsidianLive", "Ignored invalid relay request");
        }
    }

    private byte[] remotePreview() {
        byte[] bytes = latest.get();
        if (bytes == null) return null;
        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (bitmap == null) return null;
        try {
            // Keep encrypted MQTT responses below public-broker message limits.
            // Prefer a sharper preview when it still fits the fixed 48 KB budget.
            for (int width : new int[] { 640, 560, 480 }) {
                int scaledWidth = Math.min(width, bitmap.getWidth());
                int height = Math.max(2, bitmap.getHeight() * scaledWidth / bitmap.getWidth());
                Bitmap scaled = Bitmap.createScaledBitmap(bitmap, scaledWidth, height, true);
                try {
                    for (int quality : new int[] { 48, 35 }) {
                        ByteArrayOutputStream output = new ByteArrayOutputStream(49_000);
                        scaled.compress(Bitmap.CompressFormat.JPEG, quality, output);
                        if (output.size() <= 48_000) return output.toByteArray();
                    }
                } finally {
                    if (scaled != bitmap) scaled.recycle();
                }
            }
            return null;
        } finally {
            bitmap.recycle();
        }
    }

    private static String controlMessage(boolean accepted) {
        if (accepted) return "OK";
        return MainActivity.TVAccessibility.isActive()
                ? "The current TV screen cannot perform that control; try touch or Home/Back"
                : "Obsidian Accessibility service is not connected. Disable and re-enable it in TV Settings.";
    }

    private boolean control(String key) {
        AudioManager audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if ("volume_up".equals(key)) {
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, 0);
            return true;
        }
        if ("volume_down".equals(key)) {
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, 0);
            return true;
        }
        return MainActivity.TVAccessibility.execute(key);
    }

    private byte[] encrypt(byte[] clear) throws Exception {
        byte[] nonce = new byte[12];
        random.nextBytes(nonce);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(secret, "AES"), new GCMParameterSpec(128, nonce));
        byte[] ciphertext = cipher.doFinal(clear);
        byte[] combined = new byte[nonce.length + ciphertext.length];
        System.arraycopy(nonce, 0, combined, 0, nonce.length);
        System.arraycopy(ciphertext, 0, combined, nonce.length, ciphertext.length);
        return combined;
    }

    private byte[] decrypt(byte[] combined) throws Exception {
        if (combined.length < 29 || combined.length > 2048) throw new SecurityException("Bad relay request");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(secret, "AES"),
                new GCMParameterSpec(128, combined, 0, 12));
        return cipher.doFinal(combined, 12, combined.length - 12);
    }

    private void serve(Socket socket) {
        try (Socket connection = socket) {
            BufferedReader input = new BufferedReader(new InputStreamReader(connection.getInputStream(), StandardCharsets.US_ASCII));
            String request = input.readLine();
            if (request == null || request.length() > 1024) return;
            String[] parts = request.split(" ");
            if (parts.length != 3 || !parts[0].equals("GET")) {
                respond(connection, 404, "text/plain", "Not found".getBytes(StandardCharsets.UTF_8));
                return;
            }
            String path = parts[1];
            boolean frame = "/frame".equals(path);
            boolean command = path.startsWith("/control?");
            boolean touch = path.startsWith("/tap?") || path.startsWith("/swipe?");
            if (!frame && !command && !touch) {
                respond(connection, 404, "text/plain", "Not found".getBytes(StandardCharsets.UTF_8));
                return;
            }
            Map<String, String> headers = new HashMap<>();
            for (int i = 0; i < 32; i++) {
                String line = input.readLine();
                if (line == null || line.length() > 4096) return;
                if (line.isEmpty()) break;
                int colon = line.indexOf(':');
                if (colon > 0) headers.put(line.substring(0, colon).trim().toLowerCase(Locale.ROOT), line.substring(colon + 1).trim());
            }
            if (!authenticate(headers, path)) {
                respond(connection, 403, "text/plain", "Not authorized".getBytes(StandardCharsets.UTF_8));
                return;
            }
            if (!frame) {
                Map<String, String> params = parseQuery(path);
                boolean accepted;
                if (command) {
                    accepted = control(params.getOrDefault("k", ""));
                } else {
                    boolean swipe = path.startsWith("/swipe?");
                    accepted = MainActivity.TVAccessibility.gesture(
                            number(params.get("x")), number(params.get("y")),
                            swipe ? number(params.get("x2")) : null,
                            swipe ? number(params.get("y2")) : null,
                            300);
                }
                int code = accepted ? 200 : (MainActivity.TVAccessibility.isActive() ? 422 : 409);
                respond(connection, code, "text/plain",
                        controlMessage(accepted).getBytes(StandardCharsets.UTF_8));
                return;
            }
            byte[] jpeg = latest.get();
            if (jpeg == null) {
                respond(connection, 503, "text/plain", "Waiting for TV screen".getBytes(StandardCharsets.UTF_8));
                return;
            }
            respond(connection, 200, "application/octet-stream", encrypt(jpeg));
        } catch (Exception error) {
            android.util.Log.d("ObsidianLive", "Viewer disconnected: " + error.getClass().getSimpleName());
        }
    }

    private static Map<String, String> parseQuery(String path) {
        Map<String, String> result = new HashMap<>();
        int start = path.indexOf('?');
        if (start < 0) return result;
        for (String part : path.substring(start + 1).split("&")) {
            String[] pair = part.split("=", 2);
            if (pair.length == 2 && pair[0].matches("[a-z][a-z0-9]{0,2}") &&
                    pair[1].matches("[a-z0-9._-]{1,20}")) result.put(pair[0], pair[1]);
        }
        return result;
    }

    private static double number(String value) {
        try { return Double.parseDouble(value); }
        catch (Exception ignored) { return Double.NaN; }
    }

    private boolean authenticate(Map<String, String> headers, String path) {
        try {
            String seconds = headers.get("x-obsidian-time");
            String nonce = headers.get("x-obsidian-nonce");
            String proof = headers.get("x-obsidian-mac");
            if (seconds == null || nonce == null || proof == null || nonce.length() > 64) return false;
            long stamp = Long.parseLong(seconds);
            if (Math.abs(System.currentTimeMillis() / 1000 - stamp) > 60) return false;
            String signed = "GET\n" + path + "\n" + seconds + "\n" + nonce;
            Mac hmac = Mac.getInstance("HmacSHA256");
            hmac.init(new SecretKeySpec(secret, "HmacSHA256"));
            byte[] expected = hmac.doFinal(signed.getBytes(StandardCharsets.UTF_8));
            byte[] supplied = Base64.getUrlDecoder().decode(proof);
            if (!MessageDigest.isEqual(expected, supplied)) return false;
            synchronized (seenRequests) {
                if (!seenRequests.add("lan:" + nonce)) return false;
                if (seenRequests.size() > 100) seenRequests.remove(seenRequests.iterator().next());
            }
            return true;
        } catch (Exception ignored) { return false; }
    }

    private void respond(Socket socket, int code, String mime, byte[] bytes) throws Exception {
        String phrase = code == 200 ? "OK" : code == 503 ? "Service Unavailable" : code == 403 ? "Forbidden" : code == 409 ? "Conflict" : code == 422 ? "Unprocessable Entity" : "Not Found";
        String header = "HTTP/1.1 " + code + " " + phrase + "\r\n"
                + "Content-Type: " + mime + "\r\n"
                + "Content-Length: " + bytes.length + "\r\n"
                + "Cache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n";
        OutputStream out = socket.getOutputStream();
        out.write(header.getBytes(StandardCharsets.US_ASCII));
        out.write(bytes);
        out.flush();
    }
}
