#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
        L(@"swizzle skip: %@ -%@ encoding=%s argc=%u", NSStringFromClass(cls), NSStringFromSelector(sel), enc, argc);
        return NO;
    }
    *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    L(@"swizzle OK: %@ -%@", NSStringFromClass(cls), NSStringFromSelector(sel));
    return YES;
}

/* ---- يبحث داخل بروتوكول GADFullScreenContentDelegate عن دالة اسمها يحتوي "DidDismiss" ---- */
static SEL FindDismissSelector(void) {
    Protocol *p = NSProtocolFromString(@"GADFullScreenContentDelegate");
    if (!p) return NULL;
    unsigned int count = 0;
    struct objc_method_description *list = protocol_copyMethodDescriptionList(p, NO, YES, &count);
    SEL found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(list[i].name);
        if ([name rangeOfString:@"DidDismiss"].location != NSNotFound) { found = list[i].name; break; }
    }
    if (list) free(list);
    return found;
}

/* ---- الإعلان البيني العادي (GADInterstitialAd): يُمنع فعليًا هنا ---- */
static IMP gOrigPresent;
static void HookPresent(id self, SEL _cmd, UIViewController *vc) {
    L(@"EVENT interstitial BLOCKED (not calling original present)");
    id delegate = nil;
    if ([self respondsToSelector:@selector(fullScreenContentDelegate)]) {
        delegate = ((id(*)(id, SEL))objc_msgSend)(self, @selector(fullScreenContentDelegate));
    }
    SEL dismissSel = FindDismissSelector();
    if (delegate && dismissSel && [delegate respondsToSelector:dismissSel]) {
        L(@"notifying delegate %@ via %@", NSStringFromClass([delegate class]), NSStringFromSelector(dismissSel));
        ((void(*)(id, SEL, id))objc_msgSend)(delegate, dismissSel, self);
    } else {
        L(@"no delegate notified (delegate=%@ sel=%@)", delegate ? @"yes" : @"no",
          dismissSel ? NSStringFromSelector(dismissSel) : @"not found");
    }
    Persist(@"event", YES);
    /* لا نستدعي gOrigPresent عمدًا — هذا هو المنع الفعلي */
}

/* ---- البانر: مراقبة فقط، بدون منع حاليًا ---- */
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
        L(@"EVENT banner still showing (not blocked yet) class=%@", NSStringFromClass(self.class));
        Persist(@"event", YES);
    }
    ((void(*)(id,SEL))gOrigDidMoveToWindow)(self, _cmd);
}

__attribute__((constructor)) static void AdProbeInit(void) {
    gLog = [NSMutableString string];
    Dl_info info;
    if (dladdr((void *)&AdProbeInit, &info)) L(@"image=%s", info.dli_fname);
    L(@"constructor pid=%d bundle=%@ ios=%@", getpid(),
      NSBundle.mainBundle.bundleIdentifier, UIDevice.currentDevice.systemVersion);

    SafeSwizzle(NSClassFromString(@"GADInterstitialAd"), NSSelectorFromString(@"presentFromRootViewController:"),
                3, (IMP)HookPresent, &gOrigPresent);

    SafeSwizzle(UIView.class, @selector(didMoveToWindow),
                2, (IMP)HookDidMoveToWindow, &gOrigDidMoveToWindow);

    SEL dismissSel = FindDismissSelector();
    L(@"dismiss selector found: %@", dismissSel ? NSStringFromSelector(dismissSel) : @"NONE");

    Persist(@"constructor", YES);
}
