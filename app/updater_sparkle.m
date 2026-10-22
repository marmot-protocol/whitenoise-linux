// Sparkle owns networking, authentication, scheduling and its standard progress UI.
// This bridge never calls back into Odin: tick transfers only a quit request.
#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>
#import <objc/runtime.h>
#include <stdbool.h>
#include <float.h>
#include <stdlib.h>
#include <string.h>

@interface WNSparkleDelegate : NSObject <SPUUpdaterDelegate, NSApplicationDelegate>
@property(nonatomic, strong) id originalDelegate;
@property(nonatomic, copy) NSString *dataHome;
@property(nonatomic, copy) void (^installHandler)(void);
@property(nonatomic) BOOL quitRequested;
@property(nonatomic) BOOL shuttingDown;
@property(nonatomic) BOOL terminationAcknowledged;
@property(nonatomic) BOOL installationFailed;
@end

static SPUStandardUpdaterController *controller;
static WNSparkleDelegate *updateDelegate;
static NSBundle *sparkleBundle;
static NSString *disabledReason;
static NSString *const relaunchHomeKey = @"WNSparkleRelaunchDataHome";

static void acknowledgeTermination(id application, SEL selector, id sender) {
    (void)application;
    (void)selector;
    (void)sender;
    // SDL3Application overrides terminate: without consulting its delegate.
    // During the post-cleanup handshake only, receive the installer's actual
    // termination request here instead of enqueueing into the stopped SDL.
    updateDelegate.terminationAcknowledged = YES;
    CFRunLoopStop(CFRunLoopGetMain());
}

static BOOL proxyConfigured(void) {
    const char *proxy = getenv("WN_SOCKS5_PROXY");
    return proxy != NULL && proxy[0] != '\0';
}

@implementation WNSparkleDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return
        [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    if ([self.originalDelegate respondsToSelector:selector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:selector];
}
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater {
    (void)updater;
    // Do not let a stale Sparkle defaults-domain override change architecture.
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"SUFeedURL"];
}
- (BOOL)updater:(SPUUpdater *)updater
    mayPerformUpdateCheck:(SPUUpdateCheck)check
                    error:(NSError *__autoreleasing *)error {
    (void)updater;
    (void)check;
    if (!self.shuttingDown && !proxyConfigured()) {
        return YES;
    }
    if (error != NULL) {
        *error = [NSError
            errorWithDomain:@"dev.ipf.whitenoise.updater"
                       code:1
                   userInfo:@{
                       NSLocalizedDescriptionKey :
                           @"Updates are disabled while a SOCKS5 proxy is configured. Sparkle "
                           @"cannot safely use the app's explicit proxy. Disable the proxy and "
                           @"restart to update, or install an authenticated release manually."
                   }];
    }
    return NO;
}
- (BOOL)updater:(SPUUpdater *)updater
    shouldPostponeRelaunchForUpdate:(SUAppcastItem *)item
                 untilInvokingBlock:(void (^)(void))installHandler {
    (void)updater;
    (void)item;
    // Retain Sparkle's continuation, not a callback into the reloadable module.
    self.installHandler = installHandler;
    self.quitRequested = YES;
    return YES;
}
- (void)updaterWillRelaunchApplication:(SPUUpdater *)updater {
    (void)updater;
    // Sparkle 2 has no public relaunch-arguments delegate. Hand off only the
    // resolved data root, never NSProcessInfo.arguments (possibly a deep link).
    [NSUserDefaults.standardUserDefaults setObject:self.dataHome forKey:relaunchHomeKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    self.quitRequested = YES;
    return NSTerminateLater;
}
- (void)updater:(SPUUpdater *)updater
    didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check
                                 error:(NSError *)error {
    (void)updater;
    (void)check;
    // Sparkle completes the failed cycle after its native error UI has been
    // acknowledged. A failed installer connection must not strand shutdown.
    if (self.shuttingDown && error != nil) {
        self.installationFailed = YES;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:relaunchHomeKey];
        CFRunLoopStop(CFRunLoopGetMain());
    }
}
@end

const char *wn_sparkle_relaunch_home(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *home = [defaults stringForKey:relaunchHomeKey];
        [defaults removeObjectForKey:relaunchHomeKey];
        // The Odin wrapper copies this before the next autorelease boundary.
        return home != nil ? strdup(home.UTF8String) : NULL;
    }
}

void wn_sparkle_start(const char *dataHome) {
    @autoreleasepool {
        if (![NSThread isMainThread] || controller != nil || updateDelegate != nil) {
            return;
        }
        NSBundle *app = NSBundle.mainBundle;
        if (![app.bundlePath.pathExtension isEqualToString:@"app"] || NSApp == nil) {
            return;
        }
        NSString *key = [app objectForInfoDictionaryKey:@"SUPublicEDKey"];
        NSString *feed = [app objectForInfoDictionaryKey:@"SUFeedURL"];
        NSData *keyData = [[NSData alloc] initWithBase64EncodedString:key ?: @"" options:0];
        if (keyData.length != 32 || ![feed hasPrefix:@"https://"] || dataHome == NULL ||
            dataHome[0] == '\0') {
            return;
        }
        if (proxyConfigured()) {
            disabledReason = @"Updates are disabled while a SOCKS5 proxy is configured. Sparkle "
                             @"cannot safely use the app's explicit proxy. Disable the proxy and "
                             @"restart to update, or install an authenticated release manually.";
            return;
        }
        NSString *path =
            [app.privateFrameworksPath stringByAppendingPathComponent:@"Sparkle.framework"];
        sparkleBundle = [NSBundle bundleWithPath:path];
        NSError *error = nil;
        if (![sparkleBundle loadAndReturnError:&error]) {
            disabledReason =
                error.localizedDescription ?: @"The bundled Sparkle updater could not be loaded.";
            return;
        }
        Class controllerClass = NSClassFromString(@"SPUStandardUpdaterController");
        if (controllerClass == Nil) {
            return;
        }
        updateDelegate = [[WNSparkleDelegate alloc] init];
        NSString *home = [NSString stringWithUTF8String:dataHome];
        if (!home.isAbsolutePath) {
            home = [NSFileManager.defaultManager.currentDirectoryPath
                stringByAppendingPathComponent:home];
        }
        updateDelegate.dataHome = home.stringByStandardizingPath;
        updateDelegate.originalDelegate = NSApp.delegate;
        NSApp.delegate = updateDelegate;
        controller = [[controllerClass alloc] initWithStartingUpdater:NO
                                                      updaterDelegate:updateDelegate
                                                   userDriverDelegate:nil];
        if (![controller.updater startUpdater:&error]) {
            disabledReason =
                error.localizedDescription ?: @"The bundled Sparkle updater is misconfigured.";
            NSApp.delegate = updateDelegate.originalDelegate;
            controller = nil;
            updateDelegate = nil;
        }
    }
}

bool wn_sparkle_available(void) {
    return controller != nil;
}
const char *wn_sparkle_status(void) {
    if (disabledReason != nil) {
        return disabledReason.UTF8String;
    }
    return controller != nil ? "" : "Automatic updates require the installed macOS app bundle.";
}
bool wn_sparkle_can_check(void) {
    return controller != nil && !proxyConfigured() && controller.updater.canCheckForUpdates;
}
bool wn_sparkle_auto(void) {
    return controller != nil && !proxyConfigured() &&
           controller.updater.automaticallyChecksForUpdates;
}
void wn_sparkle_set_auto(bool enabled) {
    if (controller != nil && !proxyConfigured()) {
        controller.updater.automaticallyChecksForUpdates = enabled;
    }
}
void wn_sparkle_check(void) {
    @autoreleasepool {
        if (proxyConfigured() || controller == nil) {
            return;
        }
        [controller checkForUpdates:nil];
    }
}
bool wn_sparkle_take_quit(void) {
    if (!updateDelegate.quitRequested) {
        return false;
    }
    updateDelegate.quitRequested = NO;
    return true;
}
void wn_sparkle_stop(void) {
    @autoreleasepool {
        if (updateDelegate == nil) {
            return;
        }
        // Caller has finished saving drafts and stopping its runtime. Sparkle's
        // external installer waits for this process to exit before replacement
        // and relaunch; the process-owned instance lock is gone by then.
        updateDelegate.shuttingDown = YES;
        void (^install)(void) = updateDelegate.installHandler;
        updateDelegate.installHandler = nil;
        if (install != nil) {
            id previousDelegate = NSApp.delegate;
            NSApp.delegate = updateDelegate;
            // Replacing NSApp's delegate cannot intercept SDL3Application's
            // terminate: override. Replace that exact runtime-class method
            // only while waiting, preserving/restoring its implementation.
            Class applicationClass = object_getClass(NSApp);
            SEL terminateSelector = @selector(terminate:);
            Method terminateMethod = class_getInstanceMethod(applicationClass, terminateSelector);
            IMP previousTerminate =
                class_getMethodImplementation(applicationClass, terminateSelector);
            const char *terminateTypes = method_getTypeEncoding(terminateMethod);
            class_replaceMethod(applicationClass, terminateSelector, (IMP)acknowledgeTermination,
                                terminateTypes);
            @try {
                [NSUserDefaults.standardUserDefaults setObject:updateDelegate.dataHome
                                                        forKey:relaunchHomeKey];
                [NSUserDefaults.standardUserDefaults synchronize];
                install();
                // The continuation only sends an asynchronous stage-two
                // message. Keep Cocoa responsive until the agent requests
                // termination or finishes an error cycle, not an arbitrary
                // delay. Odin's remaining defers then precede process exit.
                while (!updateDelegate.terminationAcknowledged &&
                       !updateDelegate.installationFailed) {
                    @autoreleasepool {
                        CFRunLoopRunInMode(kCFRunLoopDefaultMode, DBL_MAX, true);
                    }
                }
            } @finally {
                class_replaceMethod(applicationClass, terminateSelector, previousTerminate,
                                    terminateTypes);
                NSApp.delegate = previousDelegate;
            }
        }
        if (NSApp.delegate == updateDelegate) {
            NSApp.delegate = updateDelegate.originalDelegate;
        }
        controller = nil;
        updateDelegate = nil;
        // Do not unload Objective-C classes or Sparkle's pending native blocks.
        // This bridge is never linked into the reloadable development module.
    }
}
