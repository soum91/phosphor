# Obsidian TV Companion (early local Live View prototype)

This Android TV app adds **opt-in local-network screen viewing** to Obsidian for iOS.
It runs on generic Android/Google TV devices such as TCL and Sony A80L.

## How to test

1. Install the companion APK on the television, ideally through EmberTV.
2. In Obsidian on the iPhone, add/select the same TV and keep both devices on the same LAN.
3. Open **Obsidian TV Companion** on the television. Scan its QR with the iPhone's built-in Camera app. Accept the `phosphor://` link to Obsidian.
4. On the television, choose **Start Live View** and explicitly approve Android's screen-sharing dialog.
5. The **Live** tab on the iPhone displays the TV screen and basic remote buttons. Choose **Stop screen sharing** on the TV to end the session.

## Security and limits

- Listening socket binds only to the TV's private LAN address, port 8765. No UPnP, port forwarding, or internet endpoint is enabled.
- Pairing uses a randomly generated 256-bit secret displayed as a QR. The iPhone stores it in Keychain. Requests are signed with HMAC-SHA256 and all JPEG frames are encrypted and authenticated with AES-256-GCM. No secret or raw frame bytes are sent in plaintext.
- Android MediaProjection requires explicit approval on the TV per session on modern Android. A foreground notification remains visible during capture.
- DRM-protected surfaces, secure windows, and external HDMI video may be blank or unavailable. This app does not bypass protected capture.
- This is a **first local-viewing prototype** at up to about six JPEG frames per second. It is not yet an AnyDesk-class low-latency video stream. WebRTC video, public internet traversal, remote input relay and unattended session handling remain separate work.
- Existing Sony/Android remote protocols in Obsidian are unchanged. Remote buttons in the Live tab use Obsidian's existing LAN control path.

## Building

Requires JDK 17, Android SDK 35 and Gradle 8.10.2 (the GitHub workflow installs these).

```sh
gradle -p TVCompanion :app:assembleDebug
```

The debug APK is a **test artifact**. A stable release keystore must be configured securely before publishing install-over updates through EmberTV. Never commit the signing key or TV's private QR secret.
