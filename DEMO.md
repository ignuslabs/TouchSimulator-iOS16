# TouchSimulator-iOS16 — Demo & On-Device Verification

This runbook reproduces the on-device touch synthesis demo and re-runs the iOS 16 verification path that was used to validate the XXTouch-equivalent hardening landed in commit `<hardening-commit>`.

## Verified target

| | |
|---|---|
| Device | iPhone X (iPhone10,3) |
| iOS | 16.7.12, build 20H364 |
| Jailbreak | palera1n **rootful** (no `/var/jb`, `dpkg` at `/usr/bin`) |
| Tweak loader | mobilesubstrate (rootful) |

Rootless palera1n / Dopamine on iOS 15+ should also work — install the `_iphoneos-arm64.deb` instead. Not personally re-verified for the hardening release.

## Build

```sh
cd TouchSimulator-iOS16
./build.sh
```

Produces both flavors under `packages/`:

- `com.ignuslabs.touchsimulator_<version>_iphoneos-arm.deb`  — rootful (legacy + palera1n rootful)
- `com.ignuslabs.touchsimulator_<version>_iphoneos-arm64.deb` — rootless (`/var/jb/`)

The build is fat (arm64 + arm64e). `ld: warning: -multiply_defined is obsolete` from the linker is benign and can be ignored.

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

Replacement over an existing version is safe — `dpkg -i` handles `over` cleanly.

## Respring (triggers the demo)

```sh
sshpass -p "$DEVICE_PW" ssh -o StrictHostKeyChecking=no mobile@<device-ip> \
    "echo \"$DEVICE_PW\" | sudo -S killall -9 SpringBoard"
```

`SpringBoard` relaunches in ~5s. `Example.xm`'s constructor schedules a 4-second-delayed touch sequence in **every** UIKit-bundled process (filter is `com.apple.UIKit`):

1. `simulateTouch(TOUCH_DOWN, 100, 100)`
2. `simulateTouch(TOUCH_MOVE, 100, 300)`
3. `simulateTouch(TOUCH_UP,   100, 300)`
4. `simulateTouchHandReset()` — flushes any stale finger state from the kernel tracker.

On `SpringBoard`, you'll see a phantom finger drag down the home screen (100,100 → 100,300). Open Calculator (or any UIKit app) to trigger it there too.

## Capture log evidence

From the Mac, with `libimobiledevice` installed (`brew install libimobiledevice`):

```sh
UDID=$(sshpass -p "$DEVICE_PW" ssh mobile@<device-ip> \
       "cat /var/wireless/Library/Preferences/SystemConfiguration/com.apple.* 2>/dev/null" \
       || idevice_id -n)

idevicesyslog -n -u "$UDID" > syslog.log &
SYSLOG_PID=$!
# ... respring + wait 30s ...
kill -INT $SYSLOG_PID
```

Filter for the demo:

```sh
grep -E 'TouchSimulator(-demo|-probe| )' syslog.log
```

Expected lines per process (in DEBUG builds):

```
TouchSimulator-probe: _enqueueHIDEvent present=1
TouchSimulator-probe: _contextId present=1                  # 0 in PosterBoard / wallpaper procs (no UIWindow)
TouchSimulator-probe: BKSHIDEventSetDigitizerInfo present=1
TouchSimulator-probe: senderID=0x200000000000060            # IORegistry value on iPhone X iOS 16.7.12; placeholder 0xDEFACEDBEEFFECE5 in sandboxed procs
TouchSimulator-demo: down(100,100)
TouchSimulator-demo: move(100,300)
TouchSimulator-demo: up(100,300)
TouchSimulator-demo: handReset begin
TouchSimulator-demo: handReset end
```

`TouchSimulator: no key window available, skipping UIKit enqueue path` is **expected** in poster/widget extensions — those processes have no `UIWindow`, so the dylib correctly takes the safe path and only dispatches via `IOHIDEventSystemClient`.

## Notes on the hardening

The 7 changes that bring this tweak's touch synthesis in line with WebKit's HIDEventGenerator and XXTouch's STHIDEventGenerator are documented inline in `TouchSimulator.xm`. Of note:

- `discoverSenderID()` reads `Multitouch ID` from the IORegistry `AppleMultitouchDevice` service. On iPhone X iOS 16.7.12 it returns `0x200000000000060`. Sandboxed processes (PosterBoard et al.) cannot reach that service and gracefully fall back to the placeholder `0xDEFACEDBEEFFECE5` — touch synthesis still works because the placeholder is the original sender ID the upstream tweak shipped with.
- The HID client is now `IOHIDEventSystemClientScheduleWithRunLoop`-scheduled on the main run loop. iOS 15+ silently drops events from unscheduled clients, so this was a hard requirement, not a polish.
- The contact radius is `5.0f` mm. Anything sub-millimeter (the previous `0.04f`) can be classified as noise by Core Touch.
