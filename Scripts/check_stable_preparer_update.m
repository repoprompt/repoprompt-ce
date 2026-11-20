// Discovery-only integration probe. Links the actual published Stable Sparkle.
// No app launch, standard UI, download, installation, or credential access.
#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>
#import <objc/runtime.h>

static NSString *hostID, *preferenceDomain, *feed;
static NSDictionary *expectedItem;
static void cleanupPreferences(void) {
    @autoreleasepool {
        if ([preferenceDomain hasPrefix:@"com.repoprompt.updater-probe."])
            [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:preferenceDomain];
    }
}

// SUHost uses initWithSuiteName: for an external host bundle. Redirect only
// this process's host suite to a unique probe domain: never read/write the
// installed application's preferences (HOME alone does not isolate cfprefsd).
@interface NSUserDefaults (ProbeIsolation)
- (id)probe_initWithSuiteName:(NSString *)name;
@end
@implementation NSUserDefaults (ProbeIsolation)
- (id)probe_initWithSuiteName:(NSString *)name {
    return [self probe_initWithSuiteName:[name isEqual:hostID] ? preferenceDomain : name];
}
@end

@interface ProbeDriver : NSObject <SPUUserDriver, SPUUpdaterDelegate>
@end
@implementation ProbeDriver
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return feed; }
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancel {
    puts("USER_INITIATED_SPARKLE_CHECK_STARTED");
}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    NSDictionary *enclosure = item.propertiesDictionary[@"enclosure"];
    BOOL matched = [item.versionString isEqual:expectedItem[@"buildNumber"]]
        && [item.fileURL.absoluteString isEqual:expectedItem[@"url"]]
        && item.contentLength == [expectedItem[@"enclosureSize"] unsignedLongLongValue]
        && [enclosure[@"sparkle:edSignature"] isEqual:expectedItem[@"edSignature"]];
    NSLog(@"UPDATE_FOUND build=%@ url=%@ exactManifestMatch=%@", item.versionString, item.fileURL, matched ? @"YES" : @"NO");
    reply(SPUUserUpdateChoiceDismiss); // Never install or skip a version.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(matched ? 0 : 4); });
}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack {
    NSLog(@"NO_UPDATE %@ %@", error, error.userInfo); ack(); exit(5);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack {
    NSLog(@"UPDATER_ERROR %@ %@", error, error.userInfo); ack(); exit(6);
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply { exit(7); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancel { cancel(); exit(8); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length { exit(8); }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length { exit(8); }
- (void)showDownloadDidStartExtractingUpdate { exit(8); }
- (void)showExtractionReceivedProgress:(double)progress { exit(8); }
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { exit(8); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry { exit(8); }
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { exit(8); }
- (void)dismissUpdateInstallation {}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) return 64; // host app, expected manifest, feed URL
        NSBundle *host = [NSBundle bundleWithPath:@(argv[1])];
        hostID = host.bundleIdentifier;
        if (![hostID isEqual:@"com.pvncher.repoprompt.ce"]
            || ![[host objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"43"]) return 65;
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[2])] options:0 error:nil];
        expectedItem = [manifest[@"appcastItems"] firstObject];
        if (![expectedItem[@"buildNumber"] isEqual:@"43.24.43"]) return 66;
        feed = @(argv[3]);
        preferenceDomain = [@"com.repoprompt.updater-probe." stringByAppendingString:NSUUID.UUID.UUIDString];
        atexit(cleanupPreferences);
        method_exchangeImplementations(class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:)),
                                       class_getInstanceMethod(NSUserDefaults.class, @selector(probe_initWithSuiteName:)));
        NSLog(@"Published Stable host build=43; feed=%@; isolated preference domain=%@", feed, preferenceDomain);
        ProbeDriver *driver = [ProbeDriver new];
        SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:host applicationBundle:host userDriver:driver delegate:driver];
        NSError *error = nil;
        if (![updater startUpdater:&error]) { NSLog(@"START_FAILED %@", error); return 2; }
        updater.automaticallyChecksForUpdates = NO;
        updater.automaticallyDownloadsUpdates = NO;
        [updater checkForUpdates];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ puts("TIMEOUT"); exit(9); });
        [[NSRunLoop mainRunLoop] run];
        return 3;
    }
}
