# SoundKnobs

A tiny macOS menu-bar app, Rectangle-style dropdown: every app currently playing
audio gets its own row with an icon, a volume slider, and a mute button — and the
sliders genuinely change that app's volume.

Built on the public Core Audio **process tap** API (macOS 14.4+), so there is no
kernel driver, no system extension, and nothing to install system-wide. Works on
your macOS 15.7.4.

## Requirements

- macOS 14.4 or newer
- Xcode or the Xcode Command Line Tools (`xcode-select --install`)

## Build & run

```bash
cd SoundKnobs
chmod +x build.sh
./build.sh
open build/SoundKnobs.app
```

A slider icon appears in the menu bar. Click it to open the mixer.

## First run: one permission

The very first time you move a slider, macOS will ask for **System Audio
Recording** permission (that's the privacy gate for process taps — the app
"hears" the audio in order to re-emit it at your chosen volume; nothing is
recorded or stored). Approve it in the prompt, or in
System Settings → Privacy & Security → Screen & System Audio Recording,
then move the slider again.

If you rebuild after editing the code, macOS may re-ask, since the ad-hoc
signature changes.

## How it works

- `AudioProcessMonitor` reads `kAudioHardwarePropertyProcessObjectList` and each
  process's `kAudioProcessPropertyIsRunningOutput`, with property listeners so
  the list updates live as apps start/stop playing.
- Sliders are lazy: audio flows untouched until you actually adjust an app.
- On first adjustment, `ProcessTap` creates a process tap with
  `muteBehavior = .mutedWhenTapped` (silencing the app's direct output), wraps
  it in a private aggregate device together with your default output device,
  and runs an IO proc that multiplies the tapped samples by your gain and plays
  them out. Quitting SoundKnobs destroys the taps, which automatically restores
  every app's normal audio path.
- Helper processes (e.g. `com.google.Chrome.helper`) are grouped under their
  parent app, so Chrome shows up as one row even with several audio processes.
- If you switch output devices (speakers ↔ headphones), active taps are rebuilt
  onto the new default output automatically.

## Known limitations (v0.1)

- Volume settings aren't persisted across launches yet.
- A just-adjusted app that pauses its audio disappears from the list (its tap
  stays alive, so the setting still applies when it resumes).
- Per-app *output device routing* (Spotify → headphones, Zoom → speakers) is
  possible with the same architecture but not implemented.
- Apps that play through their own exotic audio paths (some pro-audio tools)
  may not be tappable.

## Project layout

```
Sources/SoundKnobs/
  SoundKnobsApp.swift      — @main MenuBarExtra entry point
  MixerView.swift          — the dropdown UI
  Mixer.swift              — view model: grouping, volumes, tap lifecycle
  ProcessTap.swift         — the engine: tap + aggregate device + gain IO proc
  AudioProcessMonitor.swift— who is playing audio right now
  CoreAudioSupport.swift   — small Core Audio property helpers
Resources/Info.plist       — LSUIElement + NSAudioCaptureUsageDescription
build.sh                   — compiles and assembles build/SoundKnobs.app
```
