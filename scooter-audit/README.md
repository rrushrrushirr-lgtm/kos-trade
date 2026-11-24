# SCOOTER AUDIT

Android BLE inspection app, package: `com.binbin.unlocker`.

## What it does
- Scans nearby BLE advertisements.
- Lets the operator select a device.
- Connects to the selected device and lists GATT service/characteristic UUIDs and advertised properties.
- Does not write characteristics or send unlock, replay, or control commands.

## Important limitation
A visible BLE device, a successful GATT connection, or a characteristic with WRITE properties does **not** prove that a scooter can be unlocked without authorization. This app is a preliminary read-only inventory tool, not a penetration-test verdict. Confirm security behavior with the scooter manufacturer and an authorized test environment.

## Build APK
The GitHub Actions workflow **Build Scooter Audit APK** builds a debug APK. Open the repository's Actions tab, select the workflow, and run it with **Run workflow**. Download the `scooter-audit-debug-apk` artifact from the completed run and install it on a test Android phone.
