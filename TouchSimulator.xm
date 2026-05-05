#import "TouchSimulator.h"
#import <UIKit/UIApplication.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <IOKit/IOKitLib.h>

static void postEvent(IOHIDEventRef event);
static void execute();
static IOHIDEventRef parent = NULL;
static uint64_t gSenderID = 0;

// Read real Multitouch ID from IORegistry so the kernel accepts the event as
// coming from the actual digitizer hardware. Falls back to the placeholder
// 0xDEFACEDBEEFFECE5 (the upstream tweak's original constant) if the service
// is unreachable -- sandboxed processes such as PosterBoard and wallpaper
// extensions are denied by sandbox; simulator and very early boot also miss
// it. The placeholder is preserved instead of refusing to dispatch because
// (1) the upstream tweak shipped that value for years and worked, and
// (2) sandboxed processes have no UIWindow, so the dispatch path falls
// through `getKeyWindow() == nil` and only fires the system-wide
// IOHIDEventSystemClient send -- where the kernel does not gate on senderID
// matching the digitizer service. The DEBUG probe in postEvent logs the
// resolved senderID once per process so the IORegistry-vs-fallback outcome
// is visible in syslog.
static uint64_t discoverSenderID(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
        IOServiceMatching("AppleMultitouchDevice"));
    if (!service) return 0xDEFACEDBEEFFECE5ULL;
    CFNumberRef num = (CFNumberRef)IORegistryEntryCreateCFProperty(service,
        CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (!num) return 0xDEFACEDBEEFFECE5ULL;
    uint64_t senderID = 0;
    CFNumberGetValue(num, kCFNumberSInt64Type, &senderID);
    CFRelease(num);
    return senderID ? senderID : 0xDEFACEDBEEFFECE5ULL;
}

// Send a zero-contact hand-reset event to flush stale finger state from the
// kernel's touch tracker. Call after any interrupted gesture sequence.
void simulateTouchHandReset(void) {
    IOHIDEventRef reset = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        kIOHIDDigitizerTransducerTypeHand,
        0, 0,
        kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange,
        0,
        0.0, 0.0, 0.0, 0.0, 0.0,
        0, 0, 0);
    if (!reset) return;
    IOHIDEventSetIntegerValue(reset, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    postEvent(reset);
    CFRelease(reset);
}

void simulateTouch(int type, float x, float y) {
    if (parent == NULL) {
        // Include Range + Position + Identity alongside Touch so the kernel sees
        // a complete state picture on every event, matching XXTouch's STHIDEventGenerator.
        uint32_t parentMask = kIOHIDDigitizerEventRange
                            | kIOHIDDigitizerEventTouch
                            | kIOHIDDigitizerEventPosition
                            | kIOHIDDigitizerEventIdentity;
        parent = IOHIDEventCreateDigitizerEvent(
            kCFAllocatorDefault, mach_absolute_time(),
            kIOHIDDigitizerTransducerTypeHand,
            0, 0,
            parentMask,
            0,
            0.0, 0.0, 0.0, 0.0, 0.0,
            0, (type != TOUCH_UP), 0);
        IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    }

    uint32_t isTouch = (type != TOUCH_UP) ? 1 : 0;

    // Identity must always be set so the system can track finger across events.
    IOHIDDigitizerEventMask childMask = kIOHIDDigitizerEventIdentity;
    if (type == TOUCH_UP || type == TOUCH_DOWN)
        childMask |= (kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange);
    if (type == TOUCH_MOVE)
        childMask |= kIOHIDDigitizerEventPosition;

    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, mach_absolute_time(),
        1, 3,
        childMask,
        x, y, 0.0f, 0.0f, 0.0f,
        isTouch, isTouch, 0);
    // 5.0mm matches real hardware contact area; 0.04 is sub-threshold and
    // can cause the OS to classify the event as noise.
    IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMajorRadius, 5.0f);
    IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMinorRadius, 5.0f);
    IOHIDEventAppendEvent(parent, child);
    CFRelease(child);

    execute();
}

static UIWindow *getKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
        if (ws.windows.count > 0) return ws.windows.firstObject;
    }
    return nil;
}

static void postEvent(IOHIDEventRef event) {
    static IOHIDEventSystemClientRef ioSystemClient = nil;
    static dispatch_once_t clientOnce;
    dispatch_once(&clientOnce, ^{
        ioSystemClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (ioSystemClient) {
            // Must schedule on the run loop — without this the Mach port source
            // is never registered and IOHIDEventSystemClientDispatchEvent silently
            // fails to deliver events on iOS 15+.
            IOHIDEventSystemClientScheduleWithRunLoop(
                ioSystemClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        }
    });

    UIWindow *keyWindow = getKeyWindow();

#ifdef DEBUG
    static dispatch_once_t probeOnce;
    dispatch_once(&probeOnce, ^{
        UIApplication *app = [UIApplication sharedApplication];
        BOOL hasEnqueue = [app respondsToSelector:@selector(_enqueueHIDEvent:)];
        BOOL hasContextId = keyWindow ? [keyWindow respondsToSelector:@selector(_contextId)] : NO;
        void *bsHandle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        BOOL hasBKS = bsHandle ? (dlsym(bsHandle, "BKSHIDEventSetDigitizerInfo") != NULL) : NO;
        NSLog(@"TouchSimulator-probe: _enqueueHIDEvent present=%d", (int)hasEnqueue);
        NSLog(@"TouchSimulator-probe: _contextId present=%d", (int)hasContextId);
        NSLog(@"TouchSimulator-probe: BKSHIDEventSetDigitizerInfo present=%d", (int)hasBKS);
        NSLog(@"TouchSimulator-probe: senderID=0x%llX", gSenderID);
    });
#endif

    // UIKit enqueue path: routes the touch into the target app's responder chain
    // via the window's contextId. Skip when no scene is active yet.
    if (event != NULL && keyWindow != nil) {
        uint32_t contextID = keyWindow._contextId;
        void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        if (handle) {
            typedef void (*BKSHIDEventSetDigitizerInfoType)(IOHIDEventRef, uint32_t, uint8_t, uint8_t, CFStringRef, CFTimeInterval, float);
            BKSHIDEventSetDigitizerInfoType digitizer = (BKSHIDEventSetDigitizerInfoType)dlsym(handle, "BKSHIDEventSetDigitizerInfo");
            if (digitizer) {
                digitizer(event, contextID, false, false, NULL, 0, 0);
            }
            [[UIApplication sharedApplication] _enqueueHIDEvent:event];
        }
    } else if (keyWindow == nil) {
        NSLog(@"TouchSimulator: no key window available, skipping UIKit enqueue path");
    }

    IOHIDEventSetSenderID(event, gSenderID);
    if (ioSystemClient) {
        IOHIDEventSystemClientDispatchEvent(ioSystemClient, event);
    }
}

static void execute() {
    postEvent(parent);
    CFRelease(parent);
    parent = NULL;
}

__attribute__((constructor))
static void TouchSimulatorInit(void) {
    gSenderID = discoverSenderID();
}
