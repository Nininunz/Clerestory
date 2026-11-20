# Low Power Mode helper

The Battery module's leaf button toggles Low Power Mode for the active power source. Changing that system setting needs administrator rights, which the sandboxed app does not have, so it asks a small helper that runs as a system LaunchDaemon (`com.nininunz.Clerestory.LowPowerMode`).

The helper is optional and ships as its own installer package, `ClerestoryLowPowerMode.pkg`. Without it, or when the app's signature doesn't match the helper's, clicking the leaf shows a prompt in the Battery module:

- **Install Helper…** opens **Settings → Modules → Battery** in Clerestory. That page shows whether the helper is available and has buttons to download the installer and open Login Items & Extensions.
- **Use System Settings** turns on **Open System Settings instead of using the helper** and opens Battery in System Settings, where macOS has its own Low Power Mode control. From then on the leaf goes straight there and doesn't use the helper. Turn the setting off in Settings → Modules → Battery to use the helper again.
- **Not Now** closes the prompt. It appears again on the next click.

The rest of Clerestory works normally without the helper.

## How it works

- The app sends one XPC request, `toggle`, to the helper's Mach service. To show the helper's status, Settings sends a `status` request; the helper replies to any request but only acts on `toggle`, so this changes nothing.
- Each side checks the other's code signature. The app only talks to a helper signed as `com.nininunz.Clerestory.LowPowerMode` by the Clerestory Developer ID team. The helper only accepts requests from an app signed as `com.nininunz.Clerestory` by the same team.
- The helper runs as root and accepts no other requests. It reads the active power source, reads that profile's current mode with `pmset -g custom`, and flips only that profile with `/usr/bin/pmset`. It runs `pmset` with fixed arguments and a minimal environment, one request at a time.
- On Macs with High Power Mode, `pmset` reports `powermode` instead of `lowpowermode`. The helper handles both. Turning Low Power Mode off there returns to Automatic, not to High Power.
- The launchd plist names Clerestory in `AssociatedBundleIdentifiers`, so System Settings lists the helper under Clerestory in **General → Login Items & Extensions → Allow in the Background**.
- When macOS reports the change, the app's battery monitor posts a short "Low Power Mode enabled" or "disabled" notice in the notice pill. A low-battery status in the Notch stays while it shows.

## Build, sign, and notarize the package

From the repository root:

```sh
Scripts/build-low-power-mode-helper.sh \
  'Developer ID Application: …' export/helper 'Developer ID Installer: …'
Scripts/notarize.sh export/helper/ClerestoryLowPowerMode.pkg
```

- The application identity signs the helper binary.
- The installer identity signs the package, which notarization requires. Leave it off for an unsigned package for local testing only.
- The package version comes from `MARKETING_VERSION` in `Version.xcconfig`.
- The package installs the helper in `/Library/PrivilegedHelperTools` and its launchd plist in `/Library/LaunchDaemons`, then loads it. Reinstalling or upgrading replaces the running copy.

To publish it, attach `ClerestoryLowPowerMode.pkg` to every GitHub release next to the DMG. **Download Helper…** in Settings links to `releases/latest/download/ClerestoryLowPowerMode.pkg`, so a release without the package breaks that link. Sparkle updates only the app, so people who already installed the helper need to install the package again only when the helper changes.

## Install and test

Open the package and follow the installer. It asks for an administrator password once. For a local, unsigned build, install from Terminal:

```sh
sudo /usr/sbin/installer -pkg export/helper/ClerestoryLowPowerMode.pkg -target /
```

If the leaf still shows the prompt, or Settings still says **Not installed**, after installing, check that Clerestory is switched on under **System Settings → General → Login Items & Extensions → Allow in the Background**.

Run a Clerestory build signed by the same team (Developer ID, or Apple Development for local testing). Ad-hoc builds don't match the helper's requirement. In Battery, click the leaf to switch modes for the active power source, and click again to switch back. Each click should change the system mode without asking for a password, and show one notice.

## Uninstall

```sh
sudo /bin/launchctl bootout system/com.nininunz.Clerestory.LowPowerMode
sudo rm /Library/LaunchDaemons/com.nininunz.Clerestory.LowPowerMode.plist \
  /Library/PrivilegedHelperTools/com.nininunz.Clerestory.LowPowerMode
sudo /usr/sbin/pkgutil --forget com.nininunz.Clerestory.LowPowerMode
```

## Later

A future version could bundle the helper inside the app and register it with `SMAppService`, so it installs and updates with the app after one approval in System Settings. The helper and the app's request stay the same; only installation changes.
