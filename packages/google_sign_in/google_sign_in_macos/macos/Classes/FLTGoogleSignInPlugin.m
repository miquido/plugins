// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FLTGoogleSignInPlugin.h"
#import "FLTGoogleSignInPlugin_Test.h"

#import <GoogleSignIn/GoogleSignIn.h>

// The key within `GoogleService-Info.plist` used to hold the application's
// client id.  See https://developers.google.com/identity/sign-in/ios/start
// for more info.
static NSString *const kClientIdKey = @"CLIENT_ID";

static NSString *const kServerClientIdKey = @"SERVER_CLIENT_ID";

// These error codes must match with ones declared on Android and Dart sides.
static NSString *const kErrorReasonSignInRequired = @"sign_in_required";
static NSString *const kErrorReasonSignInCanceled = @"sign_in_canceled";
static NSString *const kErrorReasonNetworkError = @"network_error";
static NSString *const kErrorReasonSignInFailed = @"sign_in_failed";

static FlutterError *getFlutterError(NSError *error) {
  NSString *errorCode;
  if (error.code == kGIDSignInErrorCodeHasNoAuthInKeychain) {
    errorCode = kErrorReasonSignInRequired;
  } else if (error.code == kGIDSignInErrorCodeCanceled) {
    errorCode = kErrorReasonSignInCanceled;
  } else if ([error.domain isEqualToString:NSURLErrorDomain]) {
    errorCode = kErrorReasonNetworkError;
  } else {
    errorCode = kErrorReasonSignInFailed;
  }
  return [FlutterError errorWithCode:errorCode
                             message:error.domain
                             details:error.localizedDescription];
}

@interface FLTGoogleSignInPlugin ()

// Configuration wrapping Google Cloud Console, Google Apps, OpenID,
// and other initialization metadata.
@property(strong) GIDConfiguration *configuration;

// Permissions requested during at sign in "init" method call
// unioned with scopes requested later with incremental authorization
// "requestScopes" method call.
// The "email" and "profile" base scopes are always implicitly requested.
@property(copy) NSSet<NSString *> *requestedScopes;

// Instance used to manage Google Sign In authentication including
// sign in, sign out, and requesting additional scopes.
@property(strong, readonly) GIDSignIn *signIn;

// Redeclared as not a designated initializer.
- (instancetype)init;

@end

@implementation FLTGoogleSignInPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/google_sign_in_macos"
                                  binaryMessenger:[registrar messenger]];
  FLTGoogleSignInPlugin *instance = [[FLTGoogleSignInPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init {
  return [self initWithSignIn:GIDSignIn.sharedInstance];
}

- (instancetype)initWithSignIn:(GIDSignIn *)signIn {
  self = [super init];
  if (self) {
    _signIn = signIn;

    // On the iOS simulator, we get "Broken pipe" errors after sign-in for some
    // unknown reason. We can avoid crashing the app by ignoring them.
    signal(SIGPIPE, SIG_IGN);
    _requestedScopes = [[NSSet alloc] init];
  }
  return self;
}

#pragma mark - <FlutterPlugin> protocol

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"init"]) {
    GIDConfiguration *configuration =
        [self configurationWithClientIdArgument:call.arguments[@"clientId"]
                           hostedDomainArgument:call.arguments[@"hostedDomain"]];
    if (configuration != nil) {
      if ([call.arguments[@"scopes"] isKindOfClass:[NSArray class]]) {
        self.requestedScopes = [NSSet setWithArray:call.arguments[@"scopes"]];
      }
      self.configuration = configuration;
      result(nil);
    } else {
      result([FlutterError errorWithCode:@"missing-config"
                                 message:@"GoogleService-Info.plist file not found"
                                 details:nil]);
    }
  } else if ([call.method isEqualToString:@"signInSilently"]) {
    [self.signIn restorePreviousSignInWithCallback:^(GIDGoogleUser *user, NSError *error) {
      [self didSignInForUser:user result:result withError:error];
    }];
  } else if ([call.method isEqualToString:@"isSignedIn"]) {
    result(@([self.signIn hasPreviousSignIn]));
  } else if ([call.method isEqualToString:@"signIn"]) {
    @try {
      GIDConfiguration *configuration = self.configuration
                                            ?: [self configurationWithClientIdArgument:nil
                                                                  hostedDomainArgument:nil];

          [self.signIn signInWithConfiguration:configuration
                          presentingWindow:[NSApplication sharedApplication].keyWindow
                          hint:nil
                          additionalScopes:self.requestedScopes.allObjects
                          callback:^(GIDGoogleUser *user, NSError *error) {
                                    [self didSignInForUser:user result:result withError:error];
                          }];
    } @catch (NSException *e) {
      result([FlutterError errorWithCode:@"google_sign_in" message:e.reason details:e.name]);
      [e raise];
    }
  } else if ([call.method isEqualToString:@"getTokens"]) {
    GIDGoogleUser *currentUser = self.signIn.currentUser;
    GIDAuthentication *auth = currentUser.authentication;
    [auth doWithFreshTokens:^void(GIDAuthentication *authentication, NSError *error) {
      result(error != nil ? getFlutterError(error) : @{
        @"idToken" : authentication.idToken,
        @"accessToken" : authentication.accessToken,
      });
    }];
  } else if ([call.method isEqualToString:@"signOut"]) {
    [self.signIn signOut];
    result(nil);
  } else if ([call.method isEqualToString:@"disconnect"]) {
    [self.signIn disconnectWithCallback:^(NSError *error) {
      [self respondWithAccount:@{} result:result error:nil];
    }];
  } else if ([call.method isEqualToString:@"requestScopes"]) {
    id scopeArgument = call.arguments[@"scopes"];
    if ([scopeArgument isKindOfClass:[NSArray class]]) {
      self.requestedScopes = [self.requestedScopes setByAddingObjectsFromArray:scopeArgument];
    }
    NSSet<NSString *> *requestedScopes = self.requestedScopes;

    @try {
      [self.signIn addScopes:requestedScopes.allObjects
          presentingWindow:[NSApplication sharedApplication].keyWindow
          callback:^(GIDGoogleUser *addedScopeUser, NSError *addedScopeError) {
            if ([addedScopeError.domain isEqualToString:kGIDSignInErrorDomain] &&
                addedScopeError.code == kGIDSignInErrorCodeNoCurrentUser) {
              result([FlutterError errorWithCode:@"sign_in_required"
                                          message:@"No account to grant scopes."
                                          details:nil]);
            } else if ([addedScopeError.domain
                            isEqualToString:kGIDSignInErrorDomain] &&
                        addedScopeError.code ==
                            kGIDSignInErrorCodeScopesAlreadyGranted) {
              // Scopes already granted, report success.
              result(@YES);
            } else if (addedScopeUser == nil) {
              result(@NO);
            } else {
              NSSet<NSString *> *grantedScopes =
                  [NSSet setWithArray:addedScopeUser.grantedScopes];
              BOOL granted = [requestedScopes isSubsetOfSet:grantedScopes];
              result(@(granted));
            }
          }];
    } @catch (NSException *e) {
      result([FlutterError errorWithCode:@"request_scopes" message:e.reason details:e.name]);
    }
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (BOOL)application:(NSApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
  return [self.signIn handleURL:url];
}

#pragma mark - private methods

/// @return @c nil if GoogleService-Info.plist not found.
- (GIDConfiguration *)configurationWithClientIdArgument:(id)clientIDArg
                                   hostedDomainArgument:(id)hostedDomainArg {
  NSString *plistPath = [NSBundle.mainBundle pathForResource:@"GoogleService-Info" ofType:@"plist"];
  if (plistPath == nil) {
    return nil;
  }

  NSDictionary<NSString *, id> *plist = [[NSDictionary alloc] initWithContentsOfFile:plistPath];

  BOOL hasDynamicClientId = [clientIDArg isKindOfClass:[NSString class]];
  NSString *clientID = hasDynamicClientId ? clientIDArg : plist[kClientIdKey];

  NSString *hostedDomain = nil;
  if (hostedDomainArg != [NSNull null]) {
    hostedDomain = hostedDomainArg;
  }
  return [[GIDConfiguration alloc] initWithClientID:clientID
                                     serverClientID:plist[kServerClientIdKey]
                                       hostedDomain:hostedDomain
                                        openIDRealm:nil];
}

- (void)didSignInForUser:(GIDGoogleUser *)user
                  result:(FlutterResult)result
               withError:(NSError *)error {
  if (error != nil) {
    // Forward all errors and let Dart side decide how to handle.
    [self respondWithAccount:nil result:result error:error];
  } else {
    NSURL *photoUrl;
    if (user.profile.hasImage) {
      // Placeholder that will be replaced by on the Dart side based on screen size.
      photoUrl = [user.profile imageURLWithDimension:1337];
    }
    [self respondWithAccount:@{
      @"displayName" : user.profile.name ?: [NSNull null],
      @"email" : user.profile.email ?: [NSNull null],
      @"id" : user.userID ?: [NSNull null],
      @"photoUrl" : [photoUrl absoluteString] ?: [NSNull null],
      @"serverAuthCode" : user.serverAuthCode ?: [NSNull null]
    }
                      result:result
                       error:nil];
  }
}

- (void)respondWithAccount:(NSDictionary<NSString *, id> *)account
                    result:(FlutterResult)result
                     error:(NSError *)error {
  result(error != nil ? getFlutterError(error) : account);
}
@end
