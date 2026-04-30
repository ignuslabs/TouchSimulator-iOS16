# TouchSimulator-iOS16

Synthesize touch events on iOS 14–16 from inside an injected tweak dylib.

Fork of [Ryu0118/TouchSimulator-iOS14](https://github.com/Ryu0118/TouchSimulator-iOS14) updated for iOS 15/16 rootless jailbreaks (palera1n, Dopamine) while keeping rootful (checkra1n, unc0ver) support.

The public C API (`simulateTouch`) is stable and unchanged from the original.

## Build

Install [theos](https://theos.dev) first.

```bash
# Build both rootful and rootless .deb artifacts
./build.sh
```

Or build individually:

```bash
# Rootful (iphoneos-arm, iOS 14+)
make clean && make package FINALPACKAGE=1

# Rootless (iphoneos-arm64, iOS 15+)
unset THEOS_PACKAGE_SCHEME
export THEOS_PACKAGE_SCHEME=rootless
make clean && make package FINALPACKAGE=1
```

Built packages land in `packages/`:
- `*_iphoneos-arm.deb` — rootful build
- `*_iphoneos-arm64.deb` — rootless build

## Install

**Recommended:** Add the repo to Sileo or Zebra — they auto-select the correct `.deb` by `Architecture`.

**Side-loading with `dpkg -i`:** You must pick the `.deb` that matches your jailbreak. Run `dpkg --print-architecture` on device first:
- `iphoneos-arm` → use the `*_iphoneos-arm.deb` (rootful)
- `iphoneos-arm64` → use the `*_iphoneos-arm64.deb` (rootless)

Installing the wrong `.deb` silently puts files in the wrong prefix — the `postinst` script will detect this and abort.

## Usage

Copy `TouchSimulator.xm`, `TouchSimulator.h`, and `headers/` to your project.

```logos
#import "TouchSimulator.h"

%ctor {
  simulateTouch(TOUCH_DOWN, 100, 100);
  simulateTouch(TOUCH_MOVE, 100, 300);
  simulateTouch(TOUCH_UP, 100, 300);
}
```

### Tap

```logos
simulateTouch(TOUCH_DOWN, 100, 100);
simulateTouch(TOUCH_UP, 100, 100);
```

### Drag

```logos
simulateTouch(TOUCH_DOWN, 100, 100);
simulateTouch(TOUCH_MOVE, 100, 300);
simulateTouch(TOUCH_UP, 100, 300);
```

Only works on jailbroken devices. Does not support keyboard touch injection.
