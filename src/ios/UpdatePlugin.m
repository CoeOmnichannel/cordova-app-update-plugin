#import "UpdatePlugin.h"
#import <Cordova/CDVPlugin.h>
#import "SystemConfiguration/SystemConfiguration.h"

@interface Updater: NSObject

@property (nullable, nonatomic, strong) NSString *alertTitle;
@property (nullable, nonatomic, strong) NSString *alertMessage;
@property (nullable, nonatomic, strong) NSString *alertUpdateButtonTitle;
@property (nullable, nonatomic, strong) NSString *alertCancelButtonTitle;
@property (nullable, nonatomic, strong) NSString *version;
@property (nullable, nonatomic, strong) NSString *appName;

@end

@implementation Updater

- (BOOL)hasConnection {
    const char *host = "itunes.apple.com";
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, host);
    SCNetworkReachabilityFlags flags;
    BOOL success = SCNetworkReachabilityGetFlags(reachability, &flags);
    BOOL reachable = success && (flags & kSCNetworkFlagsReachable) && !(flags & kSCNetworkFlagsConnectionRequired);
    CFRelease(reachability);
    return reachable;
}

NSString *appStoreURL = nil;

+ (NSInteger)daysBetweenDate:(NSDate *)fromDateTime endDate:(NSDate *)toDateTime {
    NSDate *fromDate;
    NSDate *toDate;
    NSCalendar *calendar = [NSCalendar currentCalendar];
    [calendar rangeOfUnit:NSCalendarUnitDay startDate:&fromDate interval:NULL forDate:fromDateTime];
    [calendar rangeOfUnit:NSCalendarUnitDay startDate:&toDate interval:NULL forDate:toDateTime];
    NSDateComponents *difference = [calendar components:NSCalendarUnitDay fromDate:fromDate toDate:toDate options:0];
    return [difference day];
}

- (void)checkNewAppVersion:(void(^)(BOOL newVersion, NSInteger days))completion {
    NSDictionary *bundleInfo = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleIdentifier = bundleInfo[@"CFBundleIdentifier"];
    NSString *currentVersion = bundleInfo[@"CFBundleShortVersionString"];

    NSLocale *currentLocale = [NSLocale currentLocale];
    NSString *countryCode = [currentLocale objectForKey:NSLocaleCountryCode];
    NSURL *lookupURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&t=%f&country=%@", bundleIdentifier, [NSDate.date timeIntervalSince1970],countryCode]];
   
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSData *lookupResults = [NSData dataWithContentsOfURL:lookupURL];
        if (!lookupResults) {
            completion(NO, 0);
            return;
        }
       
        NSError *error = nil;
        NSDictionary *jsonResults = [NSJSONSerialization JSONObjectWithData:lookupResults options:0 error:&error];
        if (error) {
            completion(NO, 0);
            return;
        }
       
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger resultCount = [jsonResults[@"resultCount"] integerValue];
            if (resultCount > 0) {
                NSDictionary *appDetails = [jsonResults[@"results"] firstObject];
                NSString *appItunesUrl = [appDetails[@"trackViewUrl"] stringByReplacingOccurrencesOfString:@"&uo=4" withString:@""];
                NSString *latestVersion = appDetails[@"version"];
                NSString *currentVersionReleaseDate = appDetails[@"currentVersionReleaseDate"];
                NSDateFormatter *dateFormatter = [NSDateFormatter new];
                [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];
                NSDate *releaseDate = [dateFormatter dateFromString:currentVersionReleaseDate];
                
                self.appName = appDetails[@"trackName"];
                self.version = appDetails[@"version"];
                
                if ([latestVersion compare:currentVersion options:NSNumericSearch] == NSOrderedDescending) {
                    appStoreURL = appItunesUrl;
                    NSInteger daysDiff = [Updater daysBetweenDate:releaseDate endDate:[NSDate date]];
                    completion(YES, daysDiff);
                } else {
                    completion(NO, 0);
                }
            } else {
                completion(NO, 0);
            }
        });
    });
}

- (void)alertUpdateWithForce:(BOOL)force {
    UIWindow *foundWindow = nil;
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
        if (window.isKeyWindow) {
            foundWindow = window;
            break;
        }
    }
    if (foundWindow) {
        self.alertMessage = [self.alertMessage stringByReplacingOccurrencesOfString:@"__version__" withString:self.version];
        self.alertMessage = [self.alertMessage stringByReplacingOccurrencesOfString:@"__appName__" withString:self.appName];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.alertTitle message:self.alertMessage preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *updateAction = [UIAlertAction actionWithTitle:self.alertUpdateButtonTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:appStoreURL] options:@{} completionHandler:nil];
        }];
        [alert addAction:updateAction];

        if (!force) {
            UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:self.alertCancelButtonTitle style:UIAlertActionStyleCancel handler:nil];
            [alert addAction:cancelAction];
        }
        
        [foundWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    }
}

@end

@implementation CDVUpdatePlugin

- (void)update:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *pluginResult = nil;
    NSDictionary *args = [command.arguments objectAtIndex:0];
    NSDictionary *iosArgs = args[@"IOS"];
    Updater *updater = [Updater new];
    updater.alertTitle = iosArgs[@"alertTitle"];
    updater.alertMessage = iosArgs[@"alertMessage"];
    updater.alertUpdateButtonTitle = iosArgs[@"alertUpdateButtonTitle"];
    updater.alertCancelButtonTitle = iosArgs[@"alertCancelButtonTitle"];

    BOOL hasConnection = [updater hasConnection];
    if (hasConnection) {
        [updater checkNewAppVersion:^(BOOL newVersion, NSInteger days) {
            if (newVersion) {
                NSString *type = iosArgs[@"type"];
                if ([type isEqual:@"MIXED"]) {
                    NSInteger flexibleUpdateStalenessDays = [iosArgs[@"flexibleUpdateStalenessDays"] integerValue];
                    NSInteger immediateUpdateStalenessDays = [iosArgs[@"immediateUpdateStalenessDays"] integerValue];
                    if (days >= immediateUpdateStalenessDays) {
                        [updater alertUpdateWithForce:YES];
                    } else if (days >= flexibleUpdateStalenessDays) {
                        [updater alertUpdateWithForce:NO];
                    }
                } else if ([type isEqual:@"FLEXIBLE"]) {
                    NSInteger stallDays = [iosArgs[@"stallDays"] integerValue];
                    if (days >= stallDays) {
                        [updater alertUpdateWithForce:NO];
                    }
                } else if ([type isEqual:@"IMMEDIATE"]) {
                    NSInteger stallDays = [iosArgs[@"stallDays"] integerValue];
                    if (days >= stallDays) {
                        [updater alertUpdateWithForce:YES];
                    }
                }
            }
        }];
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"success"];
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"failure"];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

@end
