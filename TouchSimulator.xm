#import "TouchSimulator.h"
#import <UIKit/UIApplication.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

static void postEvent(IOHIDEventRef event);
static void execute();
static IOHIDEventRef parent = NULL;

void simulateTouch(int type, float x, float y) {
    if (parent == NULL) {
        parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, //allocator
                                                mach_absolute_time(), // timeStamp
                                                kIOHIDDigitizerTransducerTypeHand, //IOHIDDigitizerTransducerType
                                                0, // uint32_t index
                                                0, // uint32_t identity
                                                kIOHIDDigitizerEventTouch, // uint32_t eventMask
                                                0, // uint32_t buttonMask
                                                0.0, // IOHIDFloat x
                                                0.0, // IOHIDFloat y
                                                0.0, // IOHIDFloat z
                                                0.0, // IOHIDFloat tipPressure
                                                0.0, //IOHIDFloat barrelPressure
                                                0, // boolean range
                                                true, // boolean touch
                                                0// IOOptionBits options
                                                );
        IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    }

    uint32_t isTouch = type == TOUCH_UP ? 0 : 1;
    IOHIDDigitizerEventMask eventMask = 0;
    if (type != TOUCH_UP && type != TOUCH_DOWN) 
        eventMask |= kIOHIDDigitizerEventPosition;
    if (type == TOUCH_UP || type == TOUCH_DOWN)
        eventMask |= (kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange);

    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, mach_absolute_time(), 1, 3, eventMask, x, y, 0.0f, 0.0f, 0.0f, isTouch, isTouch, 0);
    IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMajorRadius, 0.04f);
    IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMinorRadius, 0.04f);
    IOHIDEventAppendEvent(parent, child);

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
    UIWindow *keyWindow = getKeyWindow();

#ifdef DEBUG
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIApplication *app = [UIApplication sharedApplication];
        BOOL hasEnqueue = [app respondsToSelector:@selector(_enqueueHIDEvent:)];
        BOOL hasContextId = keyWindow ? [keyWindow respondsToSelector:@selector(_contextId)] : NO;
        void *bsHandle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        BOOL hasBKS = bsHandle ? (dlsym(bsHandle, "BKSHIDEventSetDigitizerInfo") != NULL) : NO;
        NSLog(@"TouchSimulator-probe: _enqueueHIDEvent present=%d", (int)hasEnqueue);
        NSLog(@"TouchSimulator-probe: _contextId present=%d", (int)hasContextId);
        NSLog(@"TouchSimulator-probe: BKSHIDEventSetDigitizerInfo present=%d", (int)hasBKS);
    });
#endif

    if (ioSystemClient == NULL) {
        ioSystemClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }

    // UIKit enqueue path: delivers the touch to the target app's responder chain.
    // keyWindow nil means no UIKit scene is ready yet — skip this path safely.
    // execute() still calls CFRelease(parent) after returning, so no leak occurs here.
    if (event != NULL && keyWindow != nil) {
        uint32_t contextID = keyWindow._contextId;
        void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        if (handle) {
            typedef void (* BKSHIDEventSetDigitizerInfoType)(IOHIDEventRef,uint32_t,uint8_t,uint8_t,CFStringRef,CFTimeInterval,float);
            // BKSHIDEventSetDigitizerInfo 7-arg signature — pinned to WebKit main 2024 reference
            BKSHIDEventSetDigitizerInfoType digitizer = (BKSHIDEventSetDigitizerInfoType)dlsym(handle, "BKSHIDEventSetDigitizerInfo");
            if (digitizer) {
                digitizer(event, contextID, false, false, NULL, 0, 0);
            }
            [[UIApplication sharedApplication] _enqueueHIDEvent:event];
        }
    } else if (keyWindow == nil) {
        NSLog(@"TouchSimulator: no key window available, skipping UIKit enqueue path");
    }

    IOHIDEventSetSenderID(event, kIOHIDEventDigitizerSenderID);
    IOHIDEventSystemClientDispatchEvent(ioSystemClient, event);
}

static void execute() {
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerTiltX, kIOHIDDigitizerTransducerTypeHand);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerTiltY, 1);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerAltitude, 1);
    postEvent(parent);
    CFRelease(parent);
    parent = NULL;
}
