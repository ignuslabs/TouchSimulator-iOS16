# TouchSimulator-iOS16 — Demo & On-Device Verification

This runbook reproduces the on-device touch synthesis demo and re-runs the iOS 16 verification path that validated the XXTouch-equivalent hardening introduced in commit `13ba794`.

## Verified target

| | |
|---|---|
| Device | iPhone X (iPhone10,3) |
| iOS | 16.7.12, build 20H364 |
| Jailbreak | palera1n **rootful** (no `/var/jb`, `dpkg` at `/usr/bin`) |
| Tweak loader | TweakInject (palera1n's substrate-alternative) |

Rootless palera1n / Dopamine on iOS 15+ should also work — install the `_iphoneos-arm64.deb` instead. Not personally re-verified for the hardening release.

## Build

```sh
cd TouchSimulator-iOS16
./build.sh
```

Produces both flavors under `packages/`:

- `com.ignuslabs.touchsimulator_<version>_iphoneos-arm.deb`  — rootful (legacy + palera1n rootful)
- `com.ignuslabs.touchsimulator_<version>_iphoneos-arm64.deb` — rootless (`/var/jb/`)

The build is fat (arm64 + arm64e). `ld: warning: -multiply_defined is obsolete` is a benign linker note and can be ignored.

### Optional debug build

The hardening adds `respondsToSelector:` probes for `_enqueueHIDEvent:`, `_contextId`, and `BKSHIDEventSetDigitizerInfo` — gated on `#ifdef DEBUG`. To make them fire, append `-DDEBUG=1` to `TouchSimulator_CFLAGS` in `Makefile` for the build, then revert. They emit four `TouchSimulator-probe:` lines on the first call to `postEvent` per process.

## Connect to the device

SSH credentials live outside the repo (see `../deviceinfo.md` in this checkout's parent). For automation:

```sh
sshpass -p "$DEVICE_PW" ssh -o StrictHostKeyChecking=no mobile@<device-ip>
```

The default `mobile` user has `sudo` access to `dpkg`.

## Install

```sh
sshpass -p "$DEVICE_PW" scp packages/com.ignuslabs.touchsimulator_*_iphoneos-arm.deb \
    mobile@<device-ip>:/tmp/ts.deb

sshpass -p "$DEVICE_PW" ssh -o StrictHostKeyChecking=no mobile@<device-ip> \
    "echo \"$DEVICE_PW\" | sudo -S dpkg -i /tmp/ts.deb"
```

### Why we ship 0.1.2 and not 0.1.1 — the dpkg-vs-TweakInject path detail

palera1n rootful uses **TweakInject** (a substrate-alternative) to inject dylibs. TweakInject scans `/usr/lib/TweakInject/` and decides at process spawn whether to load each `.dylib`. The `.deb` produced by theos installs into `/Library/MobileSubstrate/DynamicLibraries/`. A trigger or symlink on a palera1n rootful system mirrors entries from the Substrate path into `/usr/lib/TweakInject/` so both loaders see the file. **`lsof` on a running SpringBoard confirms the loaded path is `/usr/lib/TweakInject/TouchSimulator.dylib`**, not the Substrate path.

This means:

- A **same-version** `dpkg -i` (e.g. `0.1.1` over `0.1.1`) replaces the file on disk, but TweakInject's per-tweak load cache may still treat the dylib as already-evaluated for some processes — observed first-hand: SpringBoard PID 10788 had zero Choicy decisions for TouchSimulator after a same-version replace, while assistivetouchd, PosterBoard, and wallpaper extensions all picked up the new dylib.
- A **version bump** (`0.1.1` → `0.1.2`) reliably forces a fresh injection across all UIKit processes.

Practical guidance: when iterating on the dylib, bump the `Version:` field in `control` for every redeploy you actually want to verify on-device. Don't try to push two builds at the same version expecting `dpkg -i` to fully refresh injection.

## Respring (reloads the tweak into all UIKit processes)

```sh
sshpass -p "$DEVICE_PW" ssh -o StrictHostKeyChecking=no mobile@<device-ip> \
    "echo \"$DEVICE_PW\" | sudo -S killall -9 SpringBoard"
```

`SpringBoard` relaunches in ~5 s. The dylib also injects into every other UIKit-bundled process the next time it starts (filter is `com.apple.UIKit`).

## Trigger the demo (after unlock)

`Example.xm` registers a `UIApplicationDidBecomeActiveNotification` observer at injection time. **The demo fires whenever any UIKit scene becomes active** — most reliably when the user opens an app such as Photos or Calculator. If injection happens while the host process is already foreground-active, the observer fires immediately (so the demo also runs on first injection without waiting for a future activation).

Each fire produces a smooth **downward swipe** from `(150, 300)` to `(150, 700)` over ~330 ms (10 incremental move events spaced 30 ms apart, scheduled via `dispatch_after` so the main queue is never blocked), followed by a `simulateTouchHandReset()` to flush the kernel touch tracker.

To watch it happen: respring, unlock the phone, then open Photos (or any UIKit app). You'll see a phantom finger drag down the middle of the screen ~2 seconds after the app becomes active.

## Capture log evidence

From the Mac, with `libimobiledevice` installed (`brew install libimobiledevice`):

```sh
UDID=$(idevice_id -n | head -1)
idevicesyslog -n -u "$UDID" > syslog.log &
SYSLOG_PID=$!
# ... respring + unlock + open an app ...
kill -INT $SYSLOG_PID
```

Note: `idevicesyslog`'s lockdownd connection often **drops during respring**. If your capture file stops growing, restart `idevicesyslog` AFTER the respring is complete and trigger the demo again by opening an app.

Filter for the demo:

```sh
grep -E 'TouchSimulator-(demo|probe)' syslog.log
```

### Expected lines on a successful run

In any UIKit-injected process (DEBUG build):

```
TouchSimulator-demo: ctor in pid <PID>
TouchSimulator-demo: registering becomeActive observer
TouchSimulator-probe: _enqueueHIDEvent present=1
TouchSimulator-probe: _contextId present=1               # 0 in PosterBoard / wallpaper procs (no UIWindow)
TouchSimulator-probe: BKSHIDEventSetDigitizerInfo present=1
TouchSimulator-probe: senderID=0x200000000000060         # IORegistry value on iPhone X iOS 16.7.12
TouchSimulator-demo: trigger=becomeActive; demo in 2s
TouchSimulator-demo: down(150,300)
TouchSimulator-demo: move(150,340)
TouchSimulator-demo: move(150,380)
...
TouchSimulator-demo: move(150,700)
TouchSimulator-demo: up(150,700)
TouchSimulator-demo: handReset
TouchSimulator-demo: done
```

`TouchSimulator: no key window available, skipping UIKit enqueue path` is **expected** in poster/widget extensions — those processes have no `UIWindow`, so the dylib correctly takes the safe path and only dispatches via `IOHIDEventSystemClient`.

## senderID policy: when the IORegistry path fails

`discoverSenderID()` reads `Multitouch ID` from `AppleMultitouchDevice` in IORegistry. On the verified target it returns `0x200000000000060`. **Sandboxed processes** (PosterBoard, PhotosPosterProvider, wallpaper extensions, etc.) cannot reach that service through the sandbox profile and silently fall back to the placeholder `0xDEFACEDBEEFFECE5` — the upstream tweak's original constant.

That fallback is intentional and not an error:

- The upstream tweak shipped that constant for years and produced working touches on iOS 14.
- Sandboxed processes never have a `UIWindow` anyway. The hardened path detects that (`getKeyWindow() == nil`) and skips the UIKit-side `_enqueueHIDEvent:` route entirely. The remaining dispatch is via `IOHIDEventSystemClientDispatchEvent`, which is system-wide and not gated on senderID matching the digitizer service for the no-window case.
- Refusing to dispatch when the service is unreachable would silently break injection into every wallpaper extension on the device for no functional gain.

If you want to confirm the lookup succeeded for a particular process, build with `-DDEBUG=1` and grep the syslog for `TouchSimulator-probe: senderID=` — anything other than `0xDEFACEDBEEFFECE5` is the IORegistry-read value.

## Evidence captured during initial verification

Captured during the iPhone X / iOS 16.7.12 verification run that produced commit `13ba794`. Excerpts (full logs in `verification/`).

DEBUG probes confirmed the private API surface is alive on iOS 16.7.12:

```
SpringBoard(TouchSimulator.dylib)[10707] <Notice>: TouchSimulator-probe: _enqueueHIDEvent present=1
SpringBoard(TouchSimulator.dylib)[10707] <Notice>: TouchSimulator-probe: _contextId present=1
SpringBoard(TouchSimulator.dylib)[10707] <Notice>: TouchSimulator-probe: BKSHIDEventSetDigitizerInfo present=1
SpringBoard(TouchSimulator.dylib)[10707] <Notice>: TouchSimulator-probe: senderID=0x200000000000060
```

Hardened code observed loading into multiple UIKit processes (Choicy gate):

```
assistivetouchd(   Choicy.dylib)[10708] <Debug>: TouchSimulator.dylib ✅ (allowed)
PosterBoard(   Choicy.dylib)[10713] <Debug>: TouchSimulator.dylib ✅ (allowed)
SpringBoard(   Choicy.dylib)[10788] <Debug>: TouchSimulator.dylib ✅ (allowed)
```

No-key-window safe path verified (the new nil guard in `postEvent`):

```
PosterBoard(TouchSimulator.dylib)[10713] <Notice>: TouchSimulator-probe: _contextId present=0
PosterBoard(TouchSimulator.dylib)[10713] <Notice>: TouchSimulator-probe: senderID=0xDEFACEDBEEFFECE5
PosterBoard(TouchSimulator.dylib)[10713] <Notice>: TouchSimulator: no key window available, skipping UIKit enqueue path
```

User-confirmed visible touch on-device (Photos app on the verified target).

See `verification/progress.txt` for the full iteration narrative including diagnostic dead-ends (the original 4-second-after-ctor demo fired during lock-screen launch and was invisible to the user; replaced by the activation-driven trigger).

## Notes on the hardening

The 7 changes that bring this tweak's touch synthesis in line with WebKit's HIDEventGenerator and XXTouch's STHIDEventGenerator are documented inline in `TouchSimulator.xm`. Of note:

- `discoverSenderID()` reads `Multitouch ID` from the IORegistry `AppleMultitouchDevice` service. On iPhone X iOS 16.7.12 it returns `0x200000000000060`. See the senderID policy section above for the fallback semantics.
- The HID client is now `IOHIDEventSystemClientScheduleWithRunLoop`-scheduled on the main run loop. iOS 15+ silently drops events from unscheduled clients, so this was a hard requirement, not a polish.
- The contact radius is `5.0f` mm. Anything sub-millimeter (the previous `0.04f`) can be classified as noise by Core Touch.
