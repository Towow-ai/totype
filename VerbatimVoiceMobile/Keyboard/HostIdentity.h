#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Which app the keyboard is typing into, so the main app can return there
/// after recording starts (README "自动返回原 App"). Private API, compiled
/// only with TOTYPE_PRIVATE_HOST_RETURN (Config/Shared.xcconfig); without it
/// every lookup returns nil. Verified on a device with iOS 26.6 beta
/// (2026-10-01):
///
/// 1. At image load, `+[_UIKeyboardArbiterClient enabled]` is swizzled to
///    return YES, which makes the arbiter client publish
///    `currentClientState` in this process.
/// 2. Every harvest adds the state's (pid -> bundle ID) pairs to an
///    in-process map.
/// 3. The host is `map[_hostProcessIdentifier]`. The arbiter's "current
///    source" is never used directly: it can lag behind (on device it showed the
///    previous app's state while the keyboard was already in WeChat).
///
/// Every step checks for nil and catches exceptions; any failure means
/// "unknown host", and the app keeps its return guide page.
@interface VVHostIdentity : NSObject

/// "installed" / "no-class" / "no-method" / "unexpected-signature", or
/// "disabled" in a build without the private API.
@property (class, nonatomic, readonly) NSString *swizzleOutcome;

/// Reads the arbiter state into the pid map, then looks up the controller's
/// host pid. Returns nil when the pid is unknown or maps to this app's own
/// bundles. Cheap (well under 10 ms on device); main thread only.
+ (nullable NSString *)resolveHostForController:(UIInputViewController *)controller
                                            pid:(int *)pidOut;

@end

NS_ASSUME_NONNULL_END
