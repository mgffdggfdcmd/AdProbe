#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>

static NSMutableString *gLog;

static void L(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
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

static BOOL SafeSwizzle(Class cls, SEL sel, unsigned expectedArgCount, IMP newImp, IMP *outOrig) {
    if (!cls) { L(@"swizzle skip: class nil for %@", NSStringFromSelector(sel)); return NO; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { L(@"swizzle skip: %@ -%@ not found", NSStringFromClass(cls), NSStringFromSelector(sel)); return NO; }
    const char *enc = method_getTypeEncoding(m);
    unsigned argc = method_getNumberOfArguments(m);
    if (enc[0] != 'v' || argc != expectedArgCount) {
        L(@"swizzle skip: %@ -%@ encoding=%s argc=%u (expected void, argc=%u)",
          NSStringFromClass(cls), NSStringFromSelector(sel), enc, argc, expectedArgCount);
        return NO;
    }
    *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    L(@"swizzle OK: %@ -%@ encoding=%s", NSStringFromClass(cls), NSStringFromSelector(sel), enc);
    return YES;
}

static IMP gOrigPresent;
static void HookPresent(id self, SEL _cmd, UIViewController *vc) {
    L(@"EVENT GADInterstitialAd presentFromRootViewController: vc=%@", NSStringFromClass(vc.class));
    Persist(@"event", YES);
    ((void(*)(id,SEL,UIViewController*))gOrigPresent)(self, _cmd, vc);
}

static IMP gOrigShow1;
static void HookShow1(id self, SEL _cmd, NSString *placement) {
    L(@"EVENT MAInterstitialAd showAdForPlacement: placement=%@", placement);
    Persist(@"event", YES);
    ((void(*)(id,SEL,NSString*))gOrigShow1)(self, _cmd, placement);
}

static IMP gOrigShow2;
static void HookShow2(id self, SEL _cmd, NSString *placement, NSString *customData) {
    L(@"EVENT MAInterstitialAd showAdForPlacement:customData: placement=%@", placement);
    Persist(@"event", YES);
    ((void(*)(id,SEL,NSString*,NSString*))gOrigShow2)(self, _cmd, placement, customData);
}

static IMP gOrigShow3;
static void HookShow3(id self, SEL _cmd, NSString *placement, NSString *customData, UIViewController *vc) {
    L(@"EVENT MAInterstitialAd showAdForPlacement:customData:viewController: placement=%@", placement);
    Persist(@"event", YES);
    ((void(*)(id,SEL,NSString*,NSString*,UIViewController*))gOrigShow3)(self, _cmd, placement, customData, vc);
}

static IMP gOrigDidMoveToWindow;
static void HookDidMoveToWindow(UIView *self, SEL _cmd) {
    static Class bannerCls, maxAdViewCls, maxNativeCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bannerCls = NSClassFromString(@"GADBannerView");
        maxAdViewCls = NSClassFromString(@"AppLovinMAXAdView");
        maxNativeCls = NSClassFromString(@"AppLovinMAXNativeAdView");
    });
    if ((bannerCls && [self isKindOfClass:bannerCls]) ||
        (maxAdViewCls && [self isKindOfClass:maxAdViewCls]) ||
        (maxNativeCls && [self isKindOfClass:maxNativeCls])) {
        L(@"EVENT banner didMoveToWindow class=%@ window=%@", NSStringFromClass(self.class),
          self.window ? @"attached" : @"detached");
        Persist(@"event", YES);
    }
    ((void(*)(id,SEL))gOrigDidMoveToWindow)(self, _cmd);
}

/* ---- جديد: مسح كل الفئات المحمَّلة لإيجاد من يطبّق بروتوكول تبليغ إغلاق الإعلان ---- */
static void ScanDelegateClasses(void) {
    Protocol *fscd = NSProtocolFromString(@"GADFullScreenContentDelegate");
    if (!fscd) { L(@"scan: protocol missing"); Persist(@"scan", YES); return; }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *matches = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        if (class_conformsToProtocol(classes[i], fscd)) {
            [matches addObject:NSStringFromClass(classes[i])];
        }
    }
    free(classes);
    L(@"scan: classes conforming to GADFullScreenContentDelegate = %lu", (unsigned long)matches.count);
    for (NSString *n in matches) L(@"  - %@", n);
    Persist(@"scan", YES);
}

__attribute__((constructor)) static void AdProbeInit(void) {
    gLog = [NSMutableString string];
    Dl_info info;
    if (dladdr((void *)&AdProbeInit, &info)) L(@"image=%s", info.dli_fname);
    L(@"constructor pid=%d bundle=%@ ios=%@", getpid(),
      NSBundle.mainBundle.bundleIdentifier, UIDevice.currentDevice.systemVersion);

    SafeSwizzle(NSClassFromString(@"GADInterstitialAd"), NSSelectorFromString(@"presentFromRootViewController:"),
                3, (IMP)HookPresent, &gOrigPresent);

    SafeSwizzle(NSClassFromString(@"MAInterstitialAd"), NSSelectorFromString(@"showAdForPlacement:"),
                3, (IMP)HookShow1, &gOrigShow1);

    SafeSwizzle(NSClassFromString(@"MAInterstitialAd"), NSSelectorFromString(@"showAdForPlacement:customData:"),
                4, (IMP)HookShow2, &gOrigShow2);

    SafeSwizzle(NSClassFromString(@"MAInterstitialAd"), NSSelectorFromString(@"showAdForPlacement:customData:viewController:"),
                5, (IMP)HookShow3, &gOrigShow3);

    SafeSwizzle(UIView.class, @selector(didMoveToWindow),
                2, (IMP)HookDidMoveToWindow, &gOrigDidMoveToWindow);

    Protocol *fscd = NSProtocolFromString(@"GADFullScreenContentDelegate");
    L(@"protocol GADFullScreenContentDelegate: %@", fscd ? @"found" : @"missing");

    Persist(@"constructor", YES);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ ScanDelegateClasses(); });
}
