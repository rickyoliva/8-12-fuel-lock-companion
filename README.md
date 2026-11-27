# 8/12 - Fuel Lock Companion

An iOS 26.4+ / iOS 27 companion app for 7-Eleven Fuel Lock, built for sideloading (free Apple ID / SideStore / AltStore / LiveContainer / Sideloadly).

## Features

- **Live Cheapest Fuel Prices (Project Zero Three)**:
  - Fetches `https://projectzerothree.info/api.php?format=json` with redirect handling, a clean `User-Agent`, and local caching keyed by the `updated` timestamp + refresh cooldown to avoid Cloudflare rate-limiting.
  - Default **Fuel Type** (`E10`, `U91`, `U95`, `U98`, `Diesel`, `LPG`) and **Region** (`All`, `VIC`, `NSW`, `QLD`, `WA`) pickers showing the top 1–3 stations (`-2` / `-3` runners-up).
  - Displays station name, price (`c/L`), suburb/state/postcode, and a one-tap **Spoof Here** button.
- **On-Device GPS Spoofing & Background Keep-Alive**:
  - Mirrors [SideInstaller](https://github.com/FrizzleM/SideInstaller)'s `LocationView` / `DeviceConnection` / `KeepAlive` architecture using `IDevice.xcframework` (`jkcoxson/idevice`).
  - Connects over **LocalDevVPN** (`10.7.0.1:49152` by default) using an imported **Remote Pairing** file (`idevice_pair`, iLoader, or SideInstaller).
  - Downloads and installs `doronz88/DeveloperDiskImage` as a **Cryptex** on iOS 26.4+ (with Personalized DDI fallback).
  - Refreshes the simulated coordinate every 4 seconds and runs silent `AVAudioEngine` background keep-alive (including iOS 27 session notifications) so spoofing survives switching to the 7-Eleven app.
- **Self-Explanatory 4-Step Fuel Lock Guide**:
  1. **Run Spoof** — Tap *Spoof Here* on a cheap station.
  2. **Start Fuel Lock & Wait for Price** — Open the 7-Eleven app and wait for the spoofed price.
  3. **Turn Off Spoof** — Return to 8/12 and tap *Stop Spoof*.
  4. **Return & Claim** — Switch back to 7-Eleven and claim.

## Building & Testing

### Prerequisites
- macOS with Xcode 27+ (iOS 26.4+ / 27 SDK)
- [`xcodegen`](https://github.com/yonaskolbe/XcodeGen) (`brew install xcodegen`)

### Run Simulator Build & Unit Tests
```bash
./scripts/check-ios.sh
```
This downloads `IDevice.xcframework` (if not already present), generates `FuelLockCompanion.xcodeproj` from `project.yml`, builds for the iOS Simulator, and runs `FuelLockCompanionTests`.

### Build Sideloadable `.ipa`
```bash
./scripts/build-ipa.sh
```
Outputs an unsigned, sideload-ready `build/FuelLockCompanion.ipa` (compatible with SideStore, AltStore, LiveContainer, Sideloadly, or signing with your own free Apple ID team in Xcode).
