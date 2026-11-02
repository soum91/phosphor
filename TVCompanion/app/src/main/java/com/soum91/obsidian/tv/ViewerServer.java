package com.soum91.obsidian.tv;

import android.content.Context;

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
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
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
 * Deliberately no public internet listener, no privileged input injection.
 */
final class ViewerServer {
    private final AtomicReference<byte[]> latest;
    private final byte[] secret;
    private final ExecutorService clients = Executors.newFixedThreadPool(3);
    private final SecureRandom random = new SecureRandom();
    private ServerSocket listener;

    ViewerServer(Context context, AtomicReference<byte[]> latest) {
        this.latest = latest;
        this.secret = Base64.getUrlDecoder().decode(CompanionSecret.getOrCreate(context));
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
    }

    void stop() {
        try { if (listener != null) listener.close(); } catch (Exception ignored) { }
        clients.shutdownNow();
    }

    private void serve(Socket socket) {
        try (Socket connection = socket) {
            BufferedReader input = new BufferedReader(new InputStreamReader(connection.getInputStream(), StandardCharsets.US_ASCII));
            String request = input.readLine();
            if (request == null || request.length() > 1024) return;
            String[] parts = request.split(" ");
            if (parts.length != 3 || !parts[0].equals("GET") || !parts[1].equals("/frame")) {
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
            if (!authenticate(headers)) {
                respond(connection, 403, "text/plain", "Not authorized".getBytes(StandardCharsets.UTF_8));
                return;
            }
            byte[] jpeg = latest.get();
            if (jpeg == null) {
                respond(connection, 503, "text/plain", "Waiting for TV screen".getBytes(StandardCharsets.UTF_8));
                return;
            }
            byte[] nonce = new byte[12];
            random.nextBytes(nonce);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(secret, "AES"), new GCMParameterSpec(128, nonce));
            byte[] ciphertext = cipher.doFinal(jpeg);
            byte[] combined = new byte[nonce.length + ciphertext.length];
            System.arraycopy(nonce, 0, combined, 0, nonce.length);
            System.arraycopy(ciphertext, 0, combined, nonce.length, ciphertext.length);
            respond(connection, 200, "application/octet-stream", combined);
        } catch (Exception error) {
            android.util.Log.d("ObsidianLive", "Viewer disconnected: " + error.getClass().getSimpleName());
        }
    }

    private boolean authenticate(Map<String, String> headers) {
        try {
            String seconds = headers.get("x-obsidian-time");
            String nonce = headers.get("x-obsidian-nonce");
            String proof = headers.get("x-obsidian-mac");
            if (seconds == null || nonce == null || proof == null || nonce.length() > 64) return false;
            long stamp = Long.parseLong(seconds);
            if (Math.abs(System.currentTimeMillis() / 1000 - stamp) > 60) return false;
            String signed = "GET\n/frame\n" + seconds + "\n" + nonce;
            Mac hmac = Mac.getInstance("HmacSHA256");
            hmac.init(new SecretKeySpec(secret, "HmacSHA256"));
            byte[] expected = hmac.doFinal(signed.getBytes(StandardCharsets.UTF_8));
            byte[] supplied = Base64.getUrlDecoder().decode(proof);
            return MessageDigest.isEqual(expected, supplied);
        } catch (Exception ignored) { return false; }
    }

    private void respond(Socket socket, int code, String mime, byte[] bytes) throws Exception {
        String phrase = code == 200 ? "OK" : code == 503 ? "Service Unavailable" : code == 403 ? "Forbidden" : "Not Found";
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
