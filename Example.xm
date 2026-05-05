#import "TouchSimulator.h"
#import <UIKit/UIKit.h>

// Demo: fire a slow visible swipe each time a UIKit scene becomes active.
// Registration must happen on the main queue (UIKit notifications and the
// dispatch_after timeline below both target it). The %ctor hops to main
// asynchronously, registers the observer, and also fires once if the scene
// is already active at injection time -- otherwise the observer would only
// fire on the next activation.

static const float kDemoStartX = 150.0f;
static const float kDemoStartY = 300.0f;
static const float kDemoEndY   = 700.0f;
static const int   kDemoSteps  = 10;
static const NSTimeInterval kDemoStepInterval = 0.030; // 30 ms

static void runDemoSequence(void) {
    NSLog(@"TouchSimulator-demo: down(%.0f,%.0f)", kDemoStartX, kDemoStartY);
    simulateTouch(TOUCH_DOWN, kDemoStartX, kDemoStartY);

    // Schedule each move via dispatch_after so we never block the main queue.
    // Blocking would freeze any UIKit process the dylib injected into.
    for (int i = 1; i <= kDemoSteps; i++) {
        NSTimeInterval when = kDemoStepInterval * (NSTimeInterval)i;
        float y = kDemoStartY + (kDemoEndY - kDemoStartY) * (float)i / (float)kDemoSteps;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(when * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSLog(@"TouchSimulator-demo: move(%.0f,%.0f)", kDemoStartX, y);
            simulateTouch(TOUCH_MOVE, kDemoStartX, y);
        });
    }

    NSTimeInterval finishAt = kDemoStepInterval * (NSTimeInterval)(kDemoSteps + 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(finishAt * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSLog(@"TouchSimulator-demo: up(%.0f,%.0f)", kDemoStartX, kDemoEndY);
        simulateTouch(TOUCH_UP, kDemoStartX, kDemoEndY);
        NSLog(@"TouchSimulator-demo: handReset");
        simulateTouchHandReset();
        NSLog(@"TouchSimulator-demo: done");
    });
}

static void scheduleDemo(NSString *trigger) {
    NSLog(@"TouchSimulator-demo: trigger=%@; demo in 2s", trigger);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        runDemoSequence();
    });
}

%ctor {
    NSLog(@"TouchSimulator-demo: ctor in pid %d", getpid());

    // Hop to main queue so UIApplication accessors are safe (they require it
    // and may not be ready synchronously inside __attribute__((constructor))).
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"TouchSimulator-demo: registering becomeActive observer");
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        scheduleDemo(@"becomeActive");
                    }];

        // If the host process is already foreground-active at injection time
        // (e.g. dylib loaded into a foreground app via TweakInject without a
        // respring), the becomeActive notification has already fired and we'd
        // never see it again until the next activation. Fire once now.
        UIApplication *app = [UIApplication sharedApplication];
        if (app && app.applicationState == UIApplicationStateActive) {
            scheduleDemo(@"already-active-at-inject");
        }
    });
}
