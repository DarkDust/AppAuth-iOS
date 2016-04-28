/*! @file OIDAuthState.m
    @brief AppAuth iOS SDK
    @copyright
        Copyright 2015 Google Inc. All Rights Reserved.
    @copydetails
        Licensed under the Apache License, Version 2.0 (the "License");
        you may not use this file except in compliance with the License.
        You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

        Unless required by applicable law or agreed to in writing, software
        distributed under the License is distributed on an "AS IS" BASIS,
        WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
        See the License for the specific language governing permissions and
        limitations under the License.
 */

#import "OIDAuthState.h"

#import "OIDAuthStateChangeDelegate.h"
#import "OIDAuthStateErrorDelegate.h"
#import "OIDAuthorizationRequest.h"
#import "OIDAuthorizationResponse.h"
#import "OIDAuthorizationService.h"
#import "OIDDefines.h"
#import "OIDError.h"
#import "OIDErrorUtilities.h"
#import "OIDTokenRequest.h"
#import "OIDTokenResponse.h"

/*! @var kRefreshTokenKey
    @brief Key used to encode the @c refreshToken property for @c NSSecureCoding.
 */
static NSString *const kRefreshTokenKey = @"refreshToken";

/*! @var kScopeKey
    @brief Key used to encode the @c scope property for @c NSSecureCoding.
 */
static NSString *const kScopeKey = @"scope";

/*! @var kLastAuthorizationResponseKey
    @brief Key used to encode the @c lastAuthorizationResponse property for @c NSSecureCoding.
 */
static NSString *const kLastAuthorizationResponseKey = @"lastAuthorizationResponse";

/*! @var kLastTokenResponseKey
    @brief Key used to encode the @c lastTokenResponse property for @c NSSecureCoding.
 */
static NSString *const kLastTokenResponseKey = @"lastTokenResponse";

/*! @var kLastOAuthErrorKey
    @brief Key used to encode the @c lastOAuthError property for @c NSSecureCoding.
 */
static NSString *const kAuthorizationErrorKey = @"authorizationError";

/*! @var kRefreshTokenRequestException
    @brief The exception thrown when a developer tries to create a refresh request from an
        authorization request with no authorization code.
 */
static NSString *const kRefreshTokenRequestException =
    @"Attempted to create a token refresh request from a token response with no refresh token.";

/*! @var kExpiryTimeTolerance
    @brief Number of seconds the access token is refreshed before it actually expires.
 */
static const NSUInteger kExpiryTimeTolerance = 60;

@interface OIDAuthState ()

/*! @property accessToken
    @brief The access token generated by the authorization server.
    @discussion Rather than using this property directly, you should call
        @c OIDAuthState.withFreshTokenPerformAction:.
 */
@property(nonatomic, readonly, nullable) NSString *accessToken;

/*! @property accessTokenExpirationDate
    @brief The approximate expiration date & time of the access token.
    @discussion Rather than using this property directly, you should call
        @c OIDAuthState.withFreshTokenPerformAction:.
 */
@property(nonatomic, readonly, nullable) NSDate *accessTokenExpirationDate;

/*! @property idToken
    @brief ID Token value associated with the authenticated session.
    @discussion Rather than using this property directly, you should call
        OIDAuthState.withFreshTokenPerformAction:.
 */
@property(nonatomic, readonly, nullable) NSString *idToken;

/*! @fn didChangeState
    @brief Private method, called when the internal state changes.
 */
- (void)didChangeState;

@end


@implementation OIDAuthState {
  /*! @var _pendingActions
      @brief Array of pending actions (use @c _pendingActionsSyncObject to synchronize access).
   */
  NSMutableArray *_pendingActions;

  /*! @var _pendingActionsSyncObject
      @brief Object for synchronizing access to @c pendingActions.
   */
  id _pendingActionsSyncObject;

  /*! @var _needsTokenRefresh
      @brief If YES, tokens will be refreshed on the next API call regardless of expiry.
   */
  BOOL _needsTokenRefresh;
}

#pragma mark - Convenience initializers

#if TARGET_OS_IPHONE
+ (id<OIDAuthorizationFlowSession>)authStateByPresentingAuthorizationRequest:
    (OIDAuthorizationRequest *)authorizationRequest
    presentingViewController:(UIViewController *)presentingViewController
                    callback:(OIDAuthStateAuthorizationCallback)callback {
  // presents the authorization request
  id<OIDAuthorizationFlowSession> authFlowSession =
      [OIDAuthorizationService presentAuthorizationRequest:authorizationRequest
                                  presentingViewController:presentingViewController
          callback:^(OIDAuthorizationResponse *_Nullable authorizationResponse,
                     NSError *_Nullable error) {
    // inspects response and processes further if needed (e.g. authorization code exchange)
    if (authorizationResponse) {
      if ([authorizationRequest.responseType isEqualToString:OIDResponseTypeCode]) {
        // if the request is for the code flow (NB. not hybrid), assumes the code is intended for
        // this client, and performs the authorization code exchange
        OIDTokenRequest *tokenExchangeRequest = [authorizationResponse tokenExchangeRequest];
        [OIDAuthorizationService performTokenRequest:tokenExchangeRequest
                                            callback:^(OIDTokenResponse *_Nullable tokenResponse,
                                                       NSError *_Nullable error) {
          OIDAuthState *authState;
          if (tokenResponse) {
            authState = [[OIDAuthState alloc] initWithAuthorizationResponse:authorizationResponse
                                                              tokenResponse:tokenResponse];
          }
          callback(authState, error);
        }];
      } else {
        // implicit or hybrid flow (hybrid flow assumes code is not for this client)
        OIDAuthState *authState =
            [[OIDAuthState alloc] initWithAuthorizationResponse:authorizationResponse];
        callback(authState, error);
      }
    } else {
      callback(nil, error);
    }
  }];
  return authFlowSession;
}
#else
+ (id<OIDAuthorizationFlowSession>)authStateByPresentingAuthorizationRequest:
    (OIDAuthorizationRequest *)authorizationRequest
        presentationCallback:(OIDWebViewControllerPresentationCallback)presentation
           dismissalCallback:(OIDWebViewControllerDismissalCallback)dismissal
          completionCallback:(OIDAuthStateAuthorizationCallback)completion {
  // presents the authorization request
  id<OIDAuthorizationFlowSession> authFlowSession =
      [OIDAuthorizationService presentAuthorizationRequest:authorizationRequest
                                      presentationCallback:presentation
                                         dismissalCallback:dismissal
          completionCallback:^(OIDAuthorizationResponse * _Nullable authorizationResponse,
                               NSError * _Nullable error) {
    // inspects response and processes further if needed (e.g. authorization code exchange)
    if (authorizationResponse) {
      if ([authorizationRequest.responseType isEqualToString:OIDResponseTypeCode]) {
        // if the request is for the code flow (NB. not hybrid), assumes the code is intended for
        // this client, and performs the authorization code exchange
        OIDTokenRequest *tokenExchangeRequest = [authorizationResponse tokenExchangeRequest];
        [OIDAuthorizationService performTokenRequest:tokenExchangeRequest
                                            callback:^(OIDTokenResponse *_Nullable tokenResponse,
                                                       NSError *_Nullable error) {
          OIDAuthState *authState;
          if (tokenResponse) {
            authState = [[OIDAuthState alloc] initWithAuthorizationResponse:authorizationResponse
                                                              tokenResponse:tokenResponse];
          }
          completion(authState, error);
        }];
      } else {
        // implicit or hybrid flow (hybrid flow assumes code is not for this client)
        OIDAuthState *authState =
            [[OIDAuthState alloc] initWithAuthorizationResponse:authorizationResponse];
        completion(authState, error);
      }
    } else {
      completion(nil, error);
    }
  }];
  return authFlowSession;
}
#endif

#pragma mark - Initializers

- (nullable instancetype)init
    OID_UNAVAILABLE_USE_INITIALIZER(@selector(initWithAuthorizationResponse:tokenResponse:));

/*! @fn initWithAuthorizationResponse:
    @brief Creates an auth state from an authorization response.
    @param response The authorization response.
 */
- (nullable instancetype)initWithAuthorizationResponse:
    (OIDAuthorizationResponse *)authorizationResponse {
  return [self initWithAuthorizationResponse:authorizationResponse tokenResponse:nil];
}


/*! @fn initWithAuthorizationResponse:tokenResponse:
    @brief Designated initializer.
    @param response The authorization response.
    @discussion Creates an auth state from an authorization response and token response.
 */
- (nullable instancetype)initWithAuthorizationResponse:
    (OIDAuthorizationResponse *)authorizationResponse
                                         tokenResponse:(nullable OIDTokenResponse *)tokenResponse {
  self = [super init];
  if (self) {
    _pendingActionsSyncObject = [[NSObject alloc] init];
    [self updateWithAuthorizationResponse:authorizationResponse error:nil];

    if (tokenResponse) {
      [self updateWithTokenResponse:tokenResponse error:nil];
    }
  }
  return self;
}

#pragma mark - NSObject overrides

- (NSString *)description {
  return [NSString stringWithFormat:@"<%@: %p, isAuthorized: %@, refreshToken: \"%@\", "
                                     "scope: \"%@\", accessToken: \"%@\", "
                                     "accessTokenExpirationDate: %@, idToken: \"%@\", "
                                     "lastAuthorizationResponse: %@, lastTokenResponse: %@, "
                                     "authorizationError: %@>",
                                    NSStringFromClass([self class]),
                                    self,
                                    (self.isAuthorized) ? @"YES" : @"NO",
                                    _refreshToken,
                                    _scope,
                                    self.accessToken,
                                    self.accessTokenExpirationDate,
                                    self.idToken,
                                    _lastAuthorizationResponse,
                                    _lastTokenResponse,
                                    _authorizationError];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  _lastAuthorizationResponse = [aDecoder decodeObjectOfClass:[OIDAuthorizationResponse class]
                                                      forKey:kLastAuthorizationResponseKey];
  _lastTokenResponse = [aDecoder decodeObjectOfClass:[OIDTokenResponse class]
                                              forKey:kLastTokenResponseKey];
  self = [self initWithAuthorizationResponse:_lastAuthorizationResponse
                               tokenResponse:_lastTokenResponse];
  if (self) {
    _authorizationError =
        [aDecoder decodeObjectOfClass:[NSError class] forKey:kAuthorizationErrorKey];
    _scope = [aDecoder decodeObjectOfClass:[NSString class] forKey:kScopeKey];
    _refreshToken = [aDecoder decodeObjectOfClass:[NSString class] forKey:kRefreshTokenKey];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeObject:_lastAuthorizationResponse forKey:kLastAuthorizationResponseKey];
  [aCoder encodeObject:_lastTokenResponse forKey:kLastTokenResponseKey];
  if (_authorizationError) {
    NSError *codingSafeAuthorizationError = [NSError errorWithDomain:_authorizationError.domain
                                                                code:_authorizationError.code
                                                            userInfo:nil];
    [aCoder encodeObject:codingSafeAuthorizationError forKey:kAuthorizationErrorKey];
  }
  [aCoder encodeObject:_scope forKey:kScopeKey];
  [aCoder encodeObject:_refreshToken forKey:kRefreshTokenKey];
}

#pragma mark - Private convenience getters

- (NSString *)accessToken {
  if (_authorizationError) {
    return nil;
  }
  return _lastTokenResponse ? _lastTokenResponse.accessToken
                            : _lastAuthorizationResponse.accessToken;
}

- (NSString *)tokenType {
  if (_authorizationError) {
    return nil;
  }
  return _lastTokenResponse ? _lastTokenResponse.tokenType
                            : _lastAuthorizationResponse.tokenType;
}

- (NSDate *)accessTokenExpirationDate {
  if (_authorizationError) {
    return nil;
  }
  return _lastTokenResponse ? _lastTokenResponse.accessTokenExpirationDate
                            : _lastAuthorizationResponse.accessTokenExpirationDate;
}

- (NSString *)idToken {
  if (_authorizationError) {
    return nil;
  }
  return _lastTokenResponse ? _lastTokenResponse.idToken
                            : _lastAuthorizationResponse.idToken;
}

#pragma mark - Getters

- (BOOL)isAuthorized {
  return !self.authorizationError && (self.accessToken || self.idToken);
}

#pragma mark - Updating the state

- (void)updateWithAuthorizationResponse:(nullable OIDAuthorizationResponse *)authorizationResponse
                                  error:(nullable NSError *)error {
  // If the error is an OAuth authorization error, updates the state. Other errors are ignored.
  if (error.domain == OIDOAuthAuthorizationErrorDomain) {
    [self updateWithAuthorizationError:error];
    return;
  }
  if (!authorizationResponse) {
    return;
  }

  _lastAuthorizationResponse = authorizationResponse;

  // clears the last token response and refresh token as these now relate to an old authorization
  // that is no longer relevant
  _lastTokenResponse = nil;
  _refreshToken = nil;
  _authorizationError = nil;

  // if the response's scope is nil, it means that it equals that of the request
  // see: https://tools.ietf.org/html/rfc6749#section-5.1
  _scope = (authorizationResponse.scope) ? authorizationResponse.scope
                                         : authorizationResponse.request.scope;

  [self didChangeState];
}

- (void)updateWithTokenResponse:(nullable OIDTokenResponse *)tokenResponse
                          error:(nullable NSError *)error {
  if (_authorizationError) {
    // Calling updateWithTokenResponse while in an error state probably means the developer obtained
    // a new token and did the exchange without also calling updateWithAuthorizationResponse.
    // Attempts to handle gracefully, but warns the developer that this is unexpected.
    NSLog(@"OIDAuthState:updateWithTokenResponse should not be called in an error state [%@] call"
         "updateWithAuthorizationResponse with the result of the fresh authorization response"
         "first",
         _authorizationError);

    _authorizationError = nil;
  }

  // If the error is an OAuth authorization error, updates the state. Other errors are ignored.
  if (error.domain == OIDOAuthTokenErrorDomain) {
    [self updateWithAuthorizationError:error];
    return;
  }
  if (!tokenResponse) {
    return;
  }

  _lastTokenResponse = tokenResponse;

  // updates the scope and refresh token if they are present on the TokenResponse.
  // according to the spec, these may be changed by the server, including when refreshing the
  // access token. See: https://tools.ietf.org/html/rfc6749#section-5.1 and
  // https://tools.ietf.org/html/rfc6749#section-6
  if (tokenResponse.scope) {
    _scope = tokenResponse.scope;
  }
  if (tokenResponse.refreshToken) {
    _refreshToken = tokenResponse.refreshToken;
  }

  [self didChangeState];
}

- (void)updateWithAuthorizationError:(NSError *)oauthError {
  _authorizationError = oauthError;

  [self didChangeState];

  [_errorDelegate authState:self didEncounterAuthorizationError:oauthError];
}

#pragma mark - OAuth Requests

- (OIDTokenRequest *)tokenRefreshRequest {
  return [self tokenRefreshRequestWithAdditionalParameters:nil];
}

- (OIDTokenRequest *)tokenRefreshRequestWithAdditionalParameters:
    (NSDictionary<NSString *, NSString *> *)additionalParameters {

  // TODO: Add unit test to confirm exception is thrown when expected

  if (!_refreshToken) {
    [OIDErrorUtilities raiseException:kRefreshTokenRequestException];
  }
  return [[OIDTokenRequest alloc]
      initWithConfiguration:_lastAuthorizationResponse.request.configuration
                  grantType:OIDGrantTypeRefreshToken
          authorizationCode:nil
                redirectURL:_lastAuthorizationResponse.request.redirectURL
                   clientID:_lastAuthorizationResponse.request.clientID
                      scope:_lastAuthorizationResponse.request.scope
               refreshToken:_refreshToken
               codeVerifier:nil
       additionalParameters:additionalParameters];
}

#pragma mark - Stateful Actions

- (void)didChangeState {
  [_stateChangeDelegate didChangeState:self];
}

- (void)setNeedsTokenRefresh {
  _needsTokenRefresh = YES;
}

- (void)withFreshTokensPerformAction:(OIDAuthStateAction)action {
  if (!_refreshToken) {
    [OIDErrorUtilities raiseException:kRefreshTokenRequestException];
  }

  if ([self.accessTokenExpirationDate timeIntervalSinceNow] > kExpiryTimeTolerance
      && !_needsTokenRefresh) {
    // access token is valid within tolerance levels, perform action
    dispatch_async(dispatch_get_main_queue(), ^() {
      action(self.accessToken, self.idToken, nil);
    });
  } else {
    // else, first refresh the token, then perform action
    _needsTokenRefresh = NO;
    NSAssert(_pendingActionsSyncObject, @"_pendingActionsSyncObject cannot be nil");
    @synchronized(_pendingActionsSyncObject) {
      // if a token is already in the process of being refreshed, adds to pending actions
      if (_pendingActions) {
        [_pendingActions addObject:action];
        return;
      }

      // creates a list of pending actions, starting with this one
      _pendingActions = [NSMutableArray arrayWithObject:action];
    }

    // refresh the tokens
    OIDTokenRequest *tokenRefreshRequest = [self tokenRefreshRequest];
    [OIDAuthorizationService performTokenRequest:tokenRefreshRequest
                                        callback:^(OIDTokenResponse *_Nullable response,
                                                   NSError *_Nullable error) {
      dispatch_async(dispatch_get_main_queue(), ^() {
        // update OIDAuthState based on response
        if (response) {
          [self updateWithTokenResponse:response error:nil];
        } else {
          if (error.domain == OIDOAuthTokenErrorDomain) {
            [self updateWithAuthorizationError:error];
          } else {
            if ([_errorDelegate respondsToSelector:
                @selector(authState:didEncounterTransientError:)]) {
              [_errorDelegate authState:self didEncounterTransientError:error];
            }
          }
        }

        // nil the pending queue and process everything that was queued up
        NSArray *actionsToProcess;
        @synchronized(_pendingActionsSyncObject) {
          actionsToProcess = _pendingActions;
          _pendingActions = nil;
        }
        for (OIDAuthStateAction actionToProcess in actionsToProcess) {
          actionToProcess(self.accessToken, self.idToken, error);
        }
      });
    }];
  }
}

#pragma mark -

@end


