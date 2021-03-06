// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "FBSDKAppEventsUtility.h"

#import <AdSupport/AdSupport.h>

#import "FBSDKAccessToken.h"
#import "FBSDKAppEvents.h"
#import "FBSDKConstants.h"
#import "FBSDKDynamicFrameworkLoader.h"
#import "FBSDKError.h"
#import "FBSDKInternalUtility.h"
#import "FBSDKLogger.h"
#import "FBSDKMacros.h"
#import "FBSDKSettings.h"
#import "FBSDKTimeSpentData.h"

#define FBSDK_APPEVENTSUTILITY_ANONYMOUSIDFILENAME @"com-facebook-sdk-PersistedAnonymousID.json"
#define FBSDK_APPEVENTSUTILITY_ANONYMOUSID_KEY @"anon_id"
#define FBSDK_APPEVENTSUTILITY_MAX_IDENTIFIER_LENGTH 40

@implementation FBSDKAppEventsUtility

+ (NSMutableDictionary *)activityParametersDictionaryForEvent:(NSString *)eventCategory
                                           implicitEventsOnly:(BOOL)implicitEventsOnly
                                    shouldAccessAdvertisingID:(BOOL)shouldAccessAdvertisingID {
  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
  parameters[@"event"] = eventCategory;

  NSString *attributionID = [[self class] attributionID];  // Only present on iOS 6 and below.
  [FBSDKInternalUtility dictionary:parameters setObject:attributionID forKey:@"attribution"];

  if (!implicitEventsOnly && shouldAccessAdvertisingID) {
    NSString *advertiserID = [[self class] advertiserID];
    [FBSDKInternalUtility dictionary:parameters setObject:advertiserID forKey:@"advertiser_id"];
  }

  parameters[@"anon_id"] = [self anonymousID];

  FBSDKAdvertisingTrackingStatus advertisingTrackingStatus = [[self class] advertisingTrackingStatus];
  if (advertisingTrackingStatus != FBSDKAdvertisingTrackingUnspecified) {
    BOOL allowed = (advertisingTrackingStatus == FBSDKAdvertisingTrackingAllowed);
    parameters[@"advertiser_tracking_enabled"] = [@(allowed) stringValue];
  }

  parameters[@"application_tracking_enabled"] = [@(!FBSDKSettings.limitEventAndDataUsage) stringValue];

  static dispatch_once_t fetchBundleOnce;
  static NSString *bundleIdentifier;
  static NSMutableArray *urlSchemes;
  static NSString *longVersion;
  static NSString *shortVersion;

  dispatch_once(&fetchBundleOnce, ^{
    NSBundle *mainBundle = [NSBundle mainBundle];
    urlSchemes = [[NSMutableArray alloc] init];
    for (NSDictionary *fields in [mainBundle objectForInfoDictionaryKey:@"CFBundleURLTypes"]) {
      NSArray *schemesForType = [fields objectForKey:@"CFBundleURLSchemes"];
      if (schemesForType) {
        [urlSchemes addObjectsFromArray:schemesForType];
      }
    }
    bundleIdentifier = [mainBundle.bundleIdentifier copy];
    longVersion = [[mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] copy];
    shortVersion = [[mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] copy];
  });

  if (bundleIdentifier.length > 0) {
    [parameters setObject:bundleIdentifier forKey:@"bundle_id"];
  }
  if (urlSchemes.count > 0) {
    [parameters setObject:[FBSDKInternalUtility JSONStringForObject:urlSchemes error:NULL invalidObjectHandler:NULL]
                   forKey:@"url_schemes"];
  }
  if (longVersion.length > 0) {
    [parameters setObject:longVersion forKey:@"bundle_version"];
  }
  if (shortVersion.length > 0) {
    [parameters setObject:shortVersion forKey:@"bundle_short_version"];
  }

  return parameters;
}

+ (NSString *)advertiserID
{
  NSString *result = nil;

  Class ASIdentifierManagerClass = fbsdkdfl_ASIdentifierManagerClass();
  if ([ASIdentifierManagerClass class]) {
    ASIdentifierManager *manager = [ASIdentifierManagerClass sharedManager];
    result = [[manager advertisingIdentifier] UUIDString];
  }

  return result;
}

+ (FBSDKAdvertisingTrackingStatus)advertisingTrackingStatus
{
  static dispatch_once_t fetchAdvertisingTrackingStatusOnce;
  static FBSDKAdvertisingTrackingStatus status;

  dispatch_once(&fetchAdvertisingTrackingStatusOnce, ^{
    status = FBSDKAdvertisingTrackingUnspecified;
    Class ASIdentifierManagerClass = fbsdkdfl_ASIdentifierManagerClass();
    if ([ASIdentifierManagerClass class]) {
      ASIdentifierManager *manager = [ASIdentifierManagerClass sharedManager];
      if (manager) {
        status = [manager isAdvertisingTrackingEnabled] ? FBSDKAdvertisingTrackingAllowed : FBSDKAdvertisingTrackingDisallowed;
      }
    }
  });

  return status;
}

+ (NSString *)anonymousID
{
  // Grab previously written anonymous ID and, if none have been generated, create and
  // persist a new one which will remain associated with this app.
  NSString *result = [[self class] retrievePersistedAnonymousID];
  if (!result) {
    // Generate a new anonymous ID.  Create as a UUID, but then prepend the fairly
    // arbitrary 'XZ' to the front so it's easily distinguishable from IDFA's which
    // will only contain hex.
    result = [NSString stringWithFormat:@"XZ%@", [[NSUUID UUID] UUIDString]];

    [self persistAnonymousID:result];
  }
  return result;
}

+ (NSString *)attributionID
{
  return [[UIPasteboard pasteboardWithName:@"fb_app_attribution" create:NO] string];
}

// for tests only.
+ (void)clearLibraryFiles
{
  [[NSFileManager defaultManager] removeItemAtPath:[[self class] persistenceFilePath:FBSDK_APPEVENTSUTILITY_ANONYMOUSIDFILENAME]
                                             error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:[[self class] persistenceFilePath:FBSDKTimeSpentFilename]
                                             error:NULL];
}

+ (void)ensureOnMainThread
{
  FBSDKConditionalLog([NSThread isMainThread], FBSDKLoggingBehaviorInformational, @"*** This method expected to be called on the main thread.");
}

+ (NSString *)flushReasonToString:(FBSDKAppEventsFlushReason)flushReason
{
  NSString *result = @"Unknown";
  switch (flushReason) {
    case FBSDKAppEventsFlushReasonExplicit:
      result = @"Explicit";
      break;
    case FBSDKAppEventsFlushReasonTimer:
      result = @"Timer";
      break;
    case FBSDKAppEventsFlushReasonSessionChange:
      result = @"SessionChange";
      break;
    case FBSDKAppEventsFlushReasonPersistedEvents:
      result = @"PersistedEvents";
      break;
    case FBSDKAppEventsFlushReasonEventThreshold:
      result = @"EventCountThreshold";
      break;
    case FBSDKAppEventsFlushReasonEagerlyFlushingEvent:
      result = @"EagerlyFlushingEvent";
      break;
  }
  return result;
}

+ (void)logAndNotify:(NSString *)msg
{
  [[self class] logAndNotify:msg allowLogAsDeveloperError:YES];
}

+ (void)logAndNotify:(NSString *)msg allowLogAsDeveloperError:(BOOL)allowLogAsDeveloperError
{
  NSString *behaviorToLog = FBSDKLoggingBehaviorAppEvents;
  if (allowLogAsDeveloperError) {
    if ([[FBSDKSettings loggingBehavior] containsObject:FBSDKLoggingBehaviorDeveloperErrors]) {
      // Rather than log twice, prefer 'DeveloperErrors' if it's set over AppEvents.
      behaviorToLog = FBSDKLoggingBehaviorDeveloperErrors;
    }
  }

  [FBSDKLogger singleShotLogEntry:behaviorToLog logEntry:msg];
  NSError *error = [FBSDKError errorWithCode:FBSDKAppEventsFlushErrorCode message:msg];
  [[NSNotificationCenter defaultCenter] postNotificationName:FBSDKAppEventsLoggingResultNotification object:error];
}

+ (BOOL)regexValidateIdentifier:(NSString *)identifier
{
  static NSRegularExpression *regex;
  static dispatch_once_t onceToken;
  static NSMutableSet *cachedIdentifiers;
  dispatch_once(&onceToken, ^{
    NSString *regexString = @"^[0-9a-zA-Z_]+[0-9a-zA-Z _-]*$";
    regex = [NSRegularExpression regularExpressionWithPattern:regexString
                                                      options:0
                                                        error:NULL];
    cachedIdentifiers = [[NSMutableSet alloc] init];
  });

  if (![cachedIdentifiers containsObject:identifier]) {
    NSUInteger numMatches = [regex numberOfMatchesInString:identifier options:0 range:NSMakeRange(0, identifier.length)];
    if (numMatches > 0) {
      [cachedIdentifiers addObject:identifier];
    } else {
      return NO;
    }
  }

  return YES;
}

+ (BOOL)validateIdentifier:(NSString *)identifier
{
  if (identifier == nil || identifier.length == 0 || identifier.length > FBSDK_APPEVENTSUTILITY_MAX_IDENTIFIER_LENGTH || ![[self class] regexValidateIdentifier:identifier]) {
    [[self class] logAndNotify:[NSString stringWithFormat:@"Invalid identifier: '%@'.  Must be between 1 and %d characters, and must be contain only alphanumerics, _, - or spaces, starting with alphanumeric or _.",
                                identifier, FBSDK_APPEVENTSUTILITY_MAX_IDENTIFIER_LENGTH]];
    return NO;
  }

  return YES;
}

+ (void)persistAnonymousID:(NSString *)anonymousID
{
  [[self class] ensureOnMainThread];
  NSDictionary *data = @{ FBSDK_APPEVENTSUTILITY_ANONYMOUSID_KEY : anonymousID };
  NSString *content = [FBSDKInternalUtility JSONStringForObject:data error:NULL invalidObjectHandler:NULL];

  [content writeToFile:[[self class] persistenceFilePath:FBSDK_APPEVENTSUTILITY_ANONYMOUSIDFILENAME]
            atomically:YES
              encoding:NSASCIIStringEncoding
                 error:nil];
}

+ (NSString *)persistenceFilePath:(NSString *)filename
{
  NSSearchPathDirectory directory = NSLibraryDirectory;
  NSArray *paths = NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES);
  NSString *docDirectory = [paths objectAtIndex:0];
  return [docDirectory stringByAppendingPathComponent:filename];
}

+ (NSString *)retrievePersistedAnonymousID
{
  [[self class] ensureOnMainThread];
  NSString *file = [[self class] persistenceFilePath:FBSDK_APPEVENTSUTILITY_ANONYMOUSIDFILENAME];
  NSString *content = [[NSString alloc] initWithContentsOfFile:file
                                                      encoding:NSASCIIStringEncoding
                                                         error:nil];
  NSDictionary *results = [FBSDKInternalUtility objectForJSONString:content error:NULL];
  return [results objectForKey:FBSDK_APPEVENTSUTILITY_ANONYMOUSID_KEY];
}

// Given a candidate token (which may be nil), find the real token to string to use.
// Precedence: 1) provided token, 2) current token, 3) app | client token, 4) fully anonymous session.
+ (NSString *)tokenStringToUseFor:(FBSDKAccessToken *)token
{
  if (!token) {
    token = [FBSDKAccessToken currentAccessToken];
  }

  NSString *appID = [FBSDKAppEvents loggingOverrideAppID] ?: token.appID ?: [FBSDKSettings appID];
  NSString *tokenString = token.tokenString;
  if (!tokenString || ![appID isEqualToString:token.appID]) {
    // If there's an logging override app id present, then we don't want to use the client token since the client token
    // is intended to match up with the primary app id (and AppEvents doesn't require a client token).
    NSString *clientTokenString = [FBSDKSettings clientToken];
    if (clientTokenString && appID && [appID isEqualToString:token.appID]){
      tokenString = [NSString stringWithFormat:@"%@|%@", appID, clientTokenString];
    } else if (appID) {
      tokenString = nil;
    }
  }
  return tokenString;
}

+ (long)unixTimeNow
{
  return (long)round([[NSDate date] timeIntervalSince1970]);
}

- (instancetype)init
{
  FBSDK_NO_DESIGNATED_INITIALIZER();
  return nil;
}

@end
