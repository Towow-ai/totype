#import "HostIdentity.h"

#if TOTYPE_PRIVATE_HOST_RETURN
#import <objc/runtime.h>
#import <objc/message.h>

// Swizzled from a constructor: installing it from viewWillAppear only worked
// once on device. No logging or I/O here; the outcome is read later.
// Nothing in this file touches textDocumentProxy.
static NSString *gSwizzleOutcome = @"not-attempted";

__attribute__((constructor))
static void VVActivateKeyboardArbiterAtLoad(void) {
    Class cls = NSClassFromString(@"_UIKeyboardArbiterClient");
    if (!cls) { gSwizzleOutcome = @"no-class"; return; }
    Method m = class_getClassMethod(cls, NSSelectorFromString(@"enabled"));
    if (!m) { gSwizzleOutcome = @"no-method"; return; }
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] != 'B') { gSwizzleOutcome = @"unexpected-signature"; return; }
    method_setImplementation(m, imp_implementationWithBlock(^BOOL(id _self) { return YES; }));
    gSwizzleOutcome = @"installed";
}

/// The main app's bundle ID (Info.plist `TotypeAppBundleID`): the app and its
/// extensions all start with it and are never a host to return to.
static NSString *SelfPrefix(void) {
    static NSString *prefix;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id value = NSBundle.mainBundle.infoDictionary[@"TotypeAppBundleID"];
        prefix = ([value isKindOfClass:NSString.class] && [value length] > 0) ? value : NSBundle.mainBundle.bundleIdentifier;
    });
    return prefix;
}

/// pid (as string) -> bundle ID, for this keyboard process only; never persisted.
static NSMutableDictionary<NSString *, NSString *> *gPidMap;

static id SafeGet(id obj, NSString *key) {
    if (!obj || ![obj respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static int IntOf(id v) { return [v respondsToSelector:@selector(intValue)] ? [v intValue] : 0; }

static BOOL IsUsableBundle(id v) {
    NSString *prefix = SelfPrefix();
    return [v isKindOfClass:NSString.class] && [v length] > 0 && !(prefix.length > 0 && [v hasPrefix:prefix]);
}

static void Remember(id bundle, id pid) {
    int p = IntOf(pid);
    if (!IsUsableBundle(bundle) || p <= 0) return;
    gPidMap[[NSString stringWithFormat:@"%d", p]] = bundle;
}

@implementation VVHostIdentity

+ (NSString *)swizzleOutcome { return gSwizzleOutcome; }

+ (void)harvest {
    if (!gPidMap) gPidMap = [NSMutableDictionary dictionary];
    Class ac = NSClassFromString(@"_UIKeyboardArbiterClient");
    SEL shared = NSSelectorFromString(@"automaticSharedArbiterClient");
    if (!ac || ![ac respondsToSelector:shared]) return;
    @try {
        id (*f)(id, SEL) = (void *)objc_msgSend;
        id client = f(ac, shared);
        id state = SafeGet(client, @"currentClientState");
        if (!state) return;
        Remember(SafeGet(state, @"sourceBundleIdentifier"), SafeGet(state, @"processIdentifier"));
        Remember(SafeGet(state, @"hostBundleIdentifier"), SafeGet(state, @"hostProcessIdentifier"));
    } @catch (NSException *e) {
    }
}

+ (NSString *)resolveHostForController:(UIInputViewController *)controller pid:(int *)pidOut {
    [self harvest];
    int pid = IntOf(SafeGet(controller, @"_hostProcessIdentifier"));
    if (pidOut) *pidOut = pid;
    if (pid <= 0 || pid == NSProcessInfo.processInfo.processIdentifier) return nil;
    NSString *bundle = gPidMap[[NSString stringWithFormat:@"%d", pid]];
    return IsUsableBundle(bundle) ? bundle : nil;
}

@end

#else

// Built without TOTYPE_PRIVATE_HOST_RETURN: none of the private calls above
// are in the binary. The host is always unknown, so the app shows its return
// guide page.
@implementation VVHostIdentity

+ (NSString *)swizzleOutcome { return @"disabled"; }

+ (NSString *)resolveHostForController:(UIInputViewController *)controller pid:(int *)pidOut {
    if (pidOut) *pidOut = 0;
    return nil;
}

@end

#endif
