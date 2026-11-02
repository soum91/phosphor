# Obsidian TV Companion (early Live View prototype)

This Android TV app adds **opt-in screen viewing** to Obsidian for iOS.
It runs on generic Android/Google TV devices such as TCL and Sony A80L.

## How to test

1. Install the companion APK on the television, ideally through EmberTV.
2. In Obsidian on the iPhone, add/select the same TV and keep both devices on the same LAN.
3. Open **Obsidian TV Companion** on the television. Scan its QR with the iPhone's built-in Camera app. Accept the `phosphor://` link to Obsidian.
4. On the television, choose **Start Live View** and explicitly approve Android's screen-sharing dialog.
5. The **Live** tab on the iPhone displays the TV screen and basic remote buttons.
6. With screen sharing still active, switch the iPhone to cellular to test the *encrypted internet preview* fallback. This is deliberately reduced to roughly one still frame every 1.5 to 3 seconds, not fluid video.
7. For experimental remote Home/Back/navigation, enable Obsidian's accessibility service in the TV's Accessibility settings if it appears. Volume commands work without accessibility. Some Android TV apps do not expose accessible focus for directional controls.
8. Choose **Stop screen sharing** on the TV to end both LAN and remote preview sessions.

## Security and limits

- Local listening socket binds only to the TV's private LAN address, port 8765. No UPnP or port forwarding. During an approved capture session, the TV also opens an **outbound** MQTT/TLS connection to `broker.emqx.io:8883`, with the iPhone using WSS on port 8084.
- Pairing uses a randomly generated 256-bit secret displayed as a QR. The iPhone stores it in Keychain. Local requests are signed with HMAC-SHA256, and local JPEG frames are AES-256-GCM encrypted. MQTT requests and responses use separate AES-256-GCM encrypted envelopes and device-specific topics derived from the secret; the broker doesn't receive raw screenshots or control messages.
- EMQX's **public broker is a testing service**, not production infrastructure. The remote preview has a strict resolution, quality and message-size cap. Do not treat it as a reliable private video relay.
- Android MediaProjection requires explicit approval on the TV per session on modern Android. A foreground notification remains visible during capture.
- DRM-protected surfaces, secure windows, and external HDMI video may be blank or unavailable. This app does not bypass protected capture.
- Local preview is up to about six JPEG frames per second. Internet preview is much slower. WebRTC video, TURN fallback and reliable full remote input remain future work. This is not AnyDesk-class low-latency streaming.
- Existing Sony/Android remote protocols in Obsidian are unchanged. The Live tab uses existing controls locally and the companion's experimental commands while connected through the relay.

## Building

Requires JDK 17, Android SDK 35 and Gradle 8.10.2 (the GitHub workflow installs these).

```sh
gradle -p TVCompanion :app:assembleDebug
```

The debug APK is a **test artifact**. A stable release keystore must be configured securely before publishing install-over updates through EmberTV. Never commit the signing key or TV's private QR secret.
