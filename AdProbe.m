#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <unistd.h>

static NSMutableString *gLog;

static void L(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void L(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AdProbe] %@", m);
    @synchronized (gLog) { [gLog appendFormat:@"%@\n", m]; }
}

static void Persist(NSString *stage, BOOL pasteboard) {
    NSString *report;
    @synchronized (gLog) {
        report = [NSString stringWithFormat:@"ADPROBE [%@]\n%@", stage, gLog];
    }
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs) {
        [report writeToFile:[docs stringByAppendingPathComponent:@"adprobe.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    if (pasteboard) UIPasteboard.generalPasteboard.string = report;
}

static NSArray<UIWindow *> *AllWindows(void) {
    NSMutableArray<UIWindow *> *r = [NSMutableArray array];
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *sc in app.connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class])
            [r addObjectsFromArray:((UIWindowScene *)sc).windows];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in app.windows) if (![r containsObject:w]) [r addObject:w];
#pragma clang diagnostic pop
    return r;
}

static void Phase2(NSString *why) {
    static BOOL done;
    if (done) return;
    done = YES;
    UIApplication *app = UIApplication.sharedApplication;
    NSArray<UIWindow *> *ws = AllWindows();
    L(@"phase2 trigger=%@ appState=%ld scenes=%lu windows=%lu", why,
      (long)app.applicationState, (unsigned long)app.connectedScenes.count,
      (unsigned long)ws.count);
    UIViewController *top = nil;
    for (UIWindow *w in ws) {
        L(@"window %@ key=%d root=%@", NSStringFromClass(w.class), w.isKeyWindow,
          w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"nil");
        if (w.rootViewController && (w.isKeyWindow || !top)) top = w.rootViewController;
    }
    while (top.presentedViewController) top = top.presentedViewController;
    L(@"alert will be presented: %@", top ? @"yes" : @"no (no rootVC)");
    Persist(@"phase2", YES);
    if (!top) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"AdProbe loaded"
        message:@"constructor + phase2 ran" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor)) static void AdProbeInit(void) {
    gLog = [NSMutableString string];
    Dl_info info;
    if (dladdr((void *)&AdProbeInit, &info)) L(@"image=%s", info.dli_fname);
    L(@"constructor pid=%d bundle=%@ ios=%@", getpid(),
      NSBundle.mainBundle.bundleIdentifier, UIDevice.currentDevice.systemVersion);
    NSArray *names = @[@"FLTBannerAd", @"FLTInterstitialAd", @"FLTRewardedAd",
                       @"AppLovinMAX", @"MAInterstitialAd", @"GADBannerView", @"GADInterstitialAd"];
    for (NSString *n in names) L(@"%@: %@", n, NSClassFromString(n) ? @"found" : @"missing");
    Persist(@"constructor", NO);

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ Phase2(@"didBecomeActive"); });
        }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ Phase2(@"fallback12s"); });
}
