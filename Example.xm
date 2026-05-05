#import "TouchSimulator.h"
#import <UIKit/UIKit.h>
#import <unistd.h>

// Demo: fire a slow visible swipe each time a UIKit scene becomes active.
// The original ctor-only demo fires before the user unlocks, so they miss it.
%ctor {
  NSLog(@"TouchSimulator-demo: ctor in pid %d", getpid());

  // Defer observer registration so UIApplication has a chance to come up.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    NSLog(@"TouchSimulator-demo: registering becomeActive observer");
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    NSLog(@"TouchSimulator-demo: scene became active, demo in 2s");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                   dispatch_get_main_queue(), ^{
                        NSLog(@"TouchSimulator-demo: down(150,300)");
                        simulateTouch(TOUCH_DOWN, 150, 300);
                        for (int i = 1; i <= 10; i++) {
                            usleep(30000);
                            float y = 300.0f + (float)i * 40.0f;
                            NSLog(@"TouchSimulator-demo: move(150,%.0f)", y);
                            simulateTouch(TOUCH_MOVE, 150, y);
                        }
                        NSLog(@"TouchSimulator-demo: up(150,700)");
                        simulateTouch(TOUCH_UP, 150, 700);
                        NSLog(@"TouchSimulator-demo: handReset");
                        simulateTouchHandReset();
                        NSLog(@"TouchSimulator-demo: done");
                    });
                }];
  });
}
