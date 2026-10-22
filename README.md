# Obsidian

An iOS remote for a Sony Bravia OLED (built against the A80L on Google TV). The repo is still called phosphor; the app is Obsidian. It talks to the TV straight over your Wi-Fi with Sony's IP control (the same API the Sony apps, Home Assistant and Afterglow use) and falls back to a Tuya IR blaster when the TV's network side is asleep or not answering. No Sony or Google account.

## Features

- **Wi-Fi first, IR as backup.** Every command tries Sony IP control, then the IR blaster (the same one [Redshift](https://github.com/soum91/redshift) and [Subwave](https://github.com/soum91/subwave) use). Settings › Send commands picks Wi-Fi then IR, Wi-Fi only or IR only. The status line shows which path the last command took.
- **Power that never toggles the wrong way.** Wi-Fi uses `setPowerStatus`; IR uses Sony's separate Power On and Power Off codes, so waking the TV from deep standby works even with Remote start off.
- **Volume, mute, inputs.** Exact volume slider over Wi-Fi (up to the TV's own max), hold-to-repeat +/-. If sound goes out to a sound bar over ARC, volume falls back to the remote's volume key, which the TV passes on over HDMI-CEC. Inputs come from the TV with their names and whether something's plugged in.
- **Apps.** Every app on the TV with its icon, tap to open (turns the TV on first if needed).
- **Sideloaded apps over ADB.** Sony's API only lists apps it knows. Obsidian speaks ADB (the same protocol as `adb connect <ip>:5555`) to list every third-party app the TV can open and launch it, from the app, widgets, Siri and Shortcuts. Turn on USB debugging in the TV's Developer options; the first time, the TV asks to allow debugging (tick Always allow). Long-press a tile to rename or hide it.
- **Mouse** (its own tab): a real mouse and keyboard as far as the TV knows. Over ADB, Android's built-in `hid` tool registers a virtual USB HID mouse (3 buttons, wheel, horizontal scroll) and keyboard, and Obsidian streams raw HID reports into it, so the TV shows its own pointer and handles clicks, wheel and drags natively, with no `input` commands and no lag. Trackpad with acceleration, tap to click, two-finger tap for right click (Back), two-finger scroll, tap-then-hold to drag; laptop-style left/right buttons that hold while pressed; a notched scroll wheel with haptics; air-mouse mode (point the phone, gyro); and a keyboard that types into any field.
- **iPhone volume buttons** turn the TV up and down while the app is open (Settings to turn off). When the TV is off they go back to controlling the phone.
- **Rearrange the remote.** Remote › ⋯ › Rearrange buttons: reorder the rows, d-pad and rockers, add or remove rows, and pick the buttons in each row (up to 5) from every button the TV has.
- **Screen off.** Picture off while it keeps playing, for music. Also in Control Center and Siri.
- **Typing.** Type into whatever search or text box is open on the TV, live as you type.
- **Picture, sound and speaker settings** read from the TV itself: picture mode, brightness, color, motion, sound mode, output, surround and whatever else your firmware exposes. Sliders, switches and pickers are built from what the TV reports.
- **Presets**: power on, then an input or app, a volume, screen off, and any buttons. Defaults: Netflix, YouTube, Music (screen off), Off.
- **Remote** laid out like the Bravia one (power, input, quick settings, Assistant, TV, d-pad ring, back/home/options, volume and channel rockers, transport, Netflix/YouTube/Google Play, color buttons), then every button on the remote and anything extra the TV reports, learn mode to record any button from your real remote, and import of Redshift's learned TV buttons.
- **Cast now playing.** When something is casting to the TV's built-in Chromecast: title, artwork, play/pause, skip, seek, stop.
- **Widgets**: small (volume, power, +/-, mute), medium (plus 4 presets), large (a full remote: d-pad, back, home, volume, mute, transport, screen off, presets), lock screen circular, rectangular and inline.
- **TV button widget**: a one-tap widget (home screen small or lock screen circular) you point at anything: any remote button, an app, an input, a preset, power, screen off, mute, volume. Long-press › Edit Widget to pick.
- **Control Center** (iOS 18): TV power, Mute and Screen toggles, Volume up / down, and a TV button you point at any action. They also work on the lock screen corner buttons and the Action button.
- **Siri** with no setup: "TV off in Obsidian", "Obsidian louder", "mute Obsidian", "open Netflix in Obsidian", "switch Obsidian to HDMI 2", "run Music in Obsidian", "screen off in Obsidian".
- **Shortcuts actions**: Set TV Power, Turn TV On/Off, Toggle, Volume Up/Down, Set Volume, Mute, Set Input, Open TV App, Run Preset, Press TV Button (any button, N times), Set/Toggle TV Screen, Type on TV, Is the TV On, Do TV Action.

## Setup

1. On the TV: Settings › Network & Internet › Home network › IP control › Authentication **Normal and Pre-Shared Key**, set a **Pre-Shared Key** (the same one Afterglow and Subwave use works). Turn **Remote start** on so Wi-Fi can wake it; without it, power-on goes over IR. Give the TV a fixed IP in your router.
2. Sideload the IPA from [Releases](https://github.com/soum91/phosphor/releases) (AltStore, SideStore, Sideloadly or FlareStore with the source below; keep app extensions on).
3. Set up › TV on Wi-Fi: Obsidian finds the TV through its Cast Bonjour service, or type its IP, plus the key.
4. Set up › Tuya IR blaster: sign in with your Smart Life user code once (only to fetch the blaster's local key), pick the blaster, Obsidian finds it on your Wi-Fi. Or type the device ID and local key from Redshift/Subwave.

Sideloading source: `https://raw.githubusercontent.com/soum91/phosphor/source/source.json`

## Build

Every push to `main` builds `Obsidian-<version>-build-<N>.ipa` on GitHub Actions and publishes it as release `build-N` with a changelog since the previous build. The app and widget are ad-hoc signed with the `group.com.soum91.phosphor` App Group.

Local: `brew install xcodegen && xcodegen generate`, open `Obsidian.xcodeproj`.

## How it talks to the TV

Sony IP control: JSON-RPC over HTTP on port 80 at `/sony/<service>` with the `X-Auth-PSK` header. `system` (getPowerStatus, setPowerStatus, getSystemInformation, getRemoteControllerInfo, setPowerSavingMode for screen off, requestReboot), `audio` (getVolumeInformation, setAudioVolume, setAudioMute, get/setSoundSettings, get/setSpeakerSettings), `avContent` (getCurrentExternalInputsStatus, getPlayingContentInfo, setPlayContent), `appControl` (getApplicationList, setActiveApp, setTextForm), `video` (get/setPictureQualitySettings).

Remote buttons: IRCC-IP, a SOAP `X_SendIRCC` to `/sony/IRCC` with the TV's own code for the button (from getRemoteControllerInfo).

IR: an IRCC code is the SIRC code in a wrapper (4 bytes length type, 4 bytes address, 4 bytes command), so every button the TV reports turns straight into SIRC (2.4 ms header, 600 µs units, sent three times 45 ms apart) for the Tuya blaster's raw pulse format, sent over Tuya's LAN protocol (3.3 / 3.4 / 3.5) with either the classic (DP 201/202) or newer (DP 1–13) command set, detected automatically. Learned codes win over built-in ones.

Google Cast: CASTV2 on port 8009 for what's casting.

Independent implementation, not affiliated with Sony, Google or Tuya.
