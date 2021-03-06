/*! @file OIDAuthorizationService.m
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

#import "OIDAuthorizationService.h"

#if TARGET_OS_IPHONE
# import <SafariServices/SafariServices.h>
#else
# import <WebKit/WebKit.h>
#endif

#import "OIDAuthorizationRequest.h"
#import "OIDAuthorizationResponse.h"
#import "OIDDefines.h"
#import "OIDErrorUtilities.h"
#import "OIDServiceConfiguration.h"
#import "OIDServiceDiscovery.h"
#import "OIDTokenRequest.h"
#import "OIDTokenResponse.h"
#import "OIDURLQueryComponent.h"
#import "OIDWebViewController.h"

/*! @var kOpenIDConfigurationWellKnownPath
    @brief Path appended to an OpenID Connect issuer for discovery
    @see https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfig
 */
static NSString *const kOpenIDConfigurationWellKnownPath = @".well-known/openid-configuration";

NS_ASSUME_NONNULL_BEGIN

@interface OIDAuthorizationFlowSessionImplementation : NSObject <OIDAuthorizationFlowSession,
#if TARGET_OS_IPHONE
                                                                 SFSafariViewControllerDelegate
#else
                                                                 WKNavigationDelegate
#endif
                                                                >

- (instancetype)init NS_UNAVAILABLE;

- (nullable instancetype)initWithRequest:(OIDAuthorizationRequest *)request
    NS_DESIGNATED_INITIALIZER;

#if TARGET_OS_IPHONE
- (void)presentSafariViewControllerWithViewController:(UIViewController *)parentViewController
    callback:(OIDAuthorizationCallback)authorizationFlowCallback;
#else
- (void)presentWebViewControllerWithConfiguration:(WKWebViewConfiguration *)configuration
presentationCallback:(OIDWebViewControllerPresentationCallback)presentation
   dismissalCallback:(OIDWebViewControllerDismissalCallback)dismissal
  completionCallback:(OIDAuthorizationCallback)completion;
#endif

@end

@implementation OIDAuthorizationFlowSessionImplementation {
#if TARGET_OS_IPHONE
  __weak SFSafariViewController *_safariVC;
#else
  __weak OIDWebViewController *_webVC;
  OIDWebViewControllerDismissalCallback _webCVDismissalCallback;
#endif
  OIDAuthorizationRequest *_request;
  OIDAuthorizationCallback _pendingauthorizationFlowCallback;
}

- (nullable instancetype)initWithRequest:(OIDAuthorizationRequest *)request {
  self = [super init];
  if (self) {
    _request = [request copy];
  }
  return self;
}

#if TARGET_OS_IPHONE
- (void)presentSafariViewControllerWithViewController:(UIViewController *)parentViewController
    callback:(OIDAuthorizationCallback)authorizationFlowCallback {
  _pendingauthorizationFlowCallback = authorizationFlowCallback;
  NSURL *URL = [_request authorizationRequestURL];
  if ([SFSafariViewController class]) {
    SFSafariViewController *safariVC = [[SFSafariViewController alloc] initWithURL:URL
                                                           entersReaderIfAvailable:NO];
    safariVC.delegate = self;
    _safariVC = safariVC;
    [parentViewController presentViewController:safariVC animated:YES completion:nil];
  } else {
    BOOL openedSafari = [[UIApplication sharedApplication] openURL:URL];
    if (!openedSafari) {
      NSError *safariError = [OIDErrorUtilities errorWithCode:OIDErrorCodeSafariOpenError
                                              underlyingError:nil
                                                  description:@"Unable to open Safari."];
      [self didFinishWithResponse:nil error:safariError];
    }
  }
}
#else
- (void)presentWebViewControllerWithConfiguration:(WKWebViewConfiguration *)configuration
    presentationCallback:(OIDWebViewControllerPresentationCallback)presentation
    dismissalCallback:(OIDWebViewControllerDismissalCallback)dismissal
    completionCallback:(OIDAuthorizationCallback)completion {
  _pendingauthorizationFlowCallback = completion;
  _webCVDismissalCallback = dismissal;
  
  OIDWebViewController *webViewController = [[OIDWebViewController alloc] initWithConfiguration:configuration];
  _webVC = webViewController;
  presentation(webViewController);
  
  WKWebView *webView = webViewController.webView;
  NSURL *URL = [_request authorizationRequestURL];
  webView.navigationDelegate = self;
  [webView loadRequest:[NSURLRequest requestWithURL:URL]];
}
#endif

#if TARGET_OS_IPHONE
- (void)cancel {
  SFSafariViewController *safari = _safariVC;
  _safariVC = nil;
  [safari dismissViewControllerAnimated:YES completion:^{
    NSError *error = [OIDErrorUtilities errorWithCode:OIDErrorCodeUserCanceledAuthorizationFlow
                                      underlyingError:nil
                                          description:nil];
    [self didFinishWithResponse:nil error:error];
  }];
}
#else
- (void)cancel {
  OIDWebViewController *webVC = _webVC;
  OIDWebViewControllerDismissalCallback dismis = _webCVDismissalCallback;
  _webVC = nil;
  _webCVDismissalCallback = nil;
  
  [webVC.webView stopLoading];
  dismis(webVC, ^{
    NSError *error = [OIDErrorUtilities errorWithCode:OIDErrorCodeUserCanceledAuthorizationFlow
                                      underlyingError:nil
                                          description:nil];
    [self didFinishWithResponse:nil error:error];
  });
}
#endif

- (BOOL)shouldHandleURL:(NSURL *)URL {
  NSURL *standardizedURL = [URL standardizedURL];
  NSURL *standardizedRedirectURL = [_request.redirectURL standardizedURL];

  return OIDIsEqualIncludingNil(standardizedURL.scheme, standardizedRedirectURL.scheme) &&
      OIDIsEqualIncludingNil(standardizedURL.user, standardizedRedirectURL.user) &&
      OIDIsEqualIncludingNil(standardizedURL.password, standardizedRedirectURL.password) &&
      OIDIsEqualIncludingNil(standardizedURL.host, standardizedRedirectURL.host) &&
      OIDIsEqualIncludingNil(standardizedURL.port, standardizedRedirectURL.port) &&
      OIDIsEqualIncludingNil(standardizedURL.path, standardizedRedirectURL.path);
}

- (BOOL)resumeAuthorizationFlowWithURL:(NSURL *)URL {
  // rejects URLs that don't match redirect (these may be completely unrelated to the authorization)
  if (![self shouldHandleURL:URL]) {
    return NO;
  }
  // checks for an invalid state
  if (!_pendingauthorizationFlowCallback) {
    [NSException raise:OIDOAuthExceptionInvalidAuthorizationFlow
                format:@"%@", OIDOAuthExceptionInvalidAuthorizationFlow, nil];
  }

  OIDURLQueryComponent *query = [[OIDURLQueryComponent alloc] initWithURL:URL];

  NSError *error;
  OIDAuthorizationResponse *response = nil;

  // checks for an OAuth error response as per RFC6749 Section 4.1.2.1
  if (query.dictionaryValue[OIDOAuthErrorFieldError]) {
    error = [OIDErrorUtilities OAuthErrorWithDomain:OIDOAuthAuthorizationErrorDomain
                                      OAuthResponse:query.dictionaryValue
                                    underlyingError:nil];
  }

  // no errors, must be a valid OAuth 2.0 response
  if (!error) {
    response = [[OIDAuthorizationResponse alloc] initWithRequest:_request
                                                      parameters:query.dictionaryValue];
  }

  // verifies that the state in the response matches the state in the request, or both are nil
  if (!OIDIsEqualIncludingNil(_request.state, response.state)) {
    NSMutableDictionary *userInfo = [query.dictionaryValue mutableCopy];
    userInfo[NSLocalizedFailureReasonErrorKey] =
        [NSString stringWithFormat:@"State mismatch, expecting %@ but got %@ in authorization "
                                    "response %@",
                                   _request.state,
                                   response.state,
                                   response];
    response = nil;
    error = [NSError errorWithDomain:OIDOAuthAuthorizationErrorDomain
                                code:OIDErrorCodeOAuthAuthorizationClientError
                            userInfo:userInfo];
  }

#if TARGET_OS_IPHONE
  if (_safariVC) {
    SFSafariViewController *safari = _safariVC;
    _safariVC = nil;
    [safari dismissViewControllerAnimated:YES completion:^{
      [self didFinishWithResponse:response error:error];
    }];
  } else {
    [self didFinishWithResponse:response error:error];
  }
#else
  OIDWebViewController *webVC = _webVC;
  OIDWebViewControllerDismissalCallback dismis = _webCVDismissalCallback;
  _webVC = nil;
  _webCVDismissalCallback = nil;
  
  if (dismis) {
    dismis(webVC, ^{
      [self didFinishWithResponse:response error:error];
    });
  } else {
    [self didFinishWithResponse:response error:error];
  }
#endif

  return YES;
}

#if TARGET_OS_IPHONE
- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
  NSError *error = [OIDErrorUtilities errorWithCode:OIDErrorCodeProgramCanceledAuthorizationFlow
                                    underlyingError:nil
                                        description:nil];
  [self didFinishWithResponse:nil error:error];
}
#else
- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  NSURL *URL = navigationAction.request.URL;
  if ([self shouldHandleURL:URL]) {
    decisionHandler(WKNavigationActionPolicyCancel);
    [self resumeAuthorizationFlowWithURL:URL];
  } else {
    decisionHandler(WKNavigationActionPolicyAllow);
  }
}
#endif

/*! @fn didFinishWithResponse:error:
    @brief Invokes the pending callback and performs cleanup.
    @param response The authorization response, if any to return to the callback.
    @param error The error, if any, to return to the callback.
 */
- (void)didFinishWithResponse:(nullable OIDAuthorizationResponse *)response
                        error:(nullable NSError *)error {
  OIDAuthorizationCallback callback = _pendingauthorizationFlowCallback;
#if TARGET_OS_IPHONE
  _safariVC = nil;
#else
  _webVC = nil;
  _webCVDismissalCallback = nil;
#endif
  _pendingauthorizationFlowCallback = nil;

  if (callback) {
    callback(response, error);
  }
}

@end

@implementation OIDAuthorizationService

+ (void)discoverServiceConfigurationForIssuer:(NSURL *)issuerURL
                                   completion:(OIDDiscoveryCallback)completion {
  NSURL *fullDiscoveryURL =
      [issuerURL URLByAppendingPathComponent:kOpenIDConfigurationWellKnownPath];

  return [[self class] discoverServiceConfigurationForDiscoveryURL:fullDiscoveryURL
                                                        completion:completion];
}


+ (void)discoverServiceConfigurationForDiscoveryURL:(NSURL *)discoveryURL
    completion:(OIDDiscoveryCallback)completion {

  NSURLSession *session = [NSURLSession sharedSession];
  NSURLSessionDataTask *task =
      [session dataTaskWithURL:discoveryURL
             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    // If we got any sort of error, just report it.
    if (error || !data) {
      error = [OIDErrorUtilities errorWithCode:OIDErrorCodeNetworkError
                               underlyingError:error
                                   description:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, error);
      });
      return;
    }

    NSHTTPURLResponse *urlResponse = (NSHTTPURLResponse *)response;

    // Check for non-200 status codes.
    // https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfigurationResponse
    if (urlResponse.statusCode != 200) {
      NSError *URLResponseError = [OIDErrorUtilities HTTPErrorWithHTTPResponse:urlResponse
                                                                          data:data];
      error = [OIDErrorUtilities errorWithCode:OIDErrorCodeNetworkError
                               underlyingError:URLResponseError
                                   description:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, error);
      });
      return;
    }

    // Construct an OIDServiceDiscovery with the received JSON.
    OIDServiceDiscovery *discovery =
        [[OIDServiceDiscovery alloc] initWithJSONData:data error:&error];
    if (error || !discovery) {
      error = [OIDErrorUtilities errorWithCode:OIDErrorCodeNetworkError
                               underlyingError:error
                                   description:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, error);
      });
      return;
    }

    // Create our service configuration with the discovery document and return it.
    OIDServiceConfiguration *configuration =
        [[OIDServiceConfiguration alloc] initWithDiscoveryDocument:discovery];
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(configuration, nil);
    });
  }];
  [task resume];
}

#pragma mark - Authorization Endpoint

#if TARGET_OS_IPHONE
+ (id<OIDAuthorizationFlowSession>)
    presentAuthorizationRequest:(OIDAuthorizationRequest *)request
       presentingViewController:(UIViewController *)presentingViewController
                       callback:(OIDAuthorizationCallback)callback {
  OIDAuthorizationFlowSessionImplementation *flow =
      [[OIDAuthorizationFlowSessionImplementation alloc] initWithRequest:request];
  [flow presentSafariViewControllerWithViewController:presentingViewController
                                             callback:callback];
  return flow;
}
#else
+ (id<OIDAuthorizationFlowSession>)
    presentAuthorizationRequest:(OIDAuthorizationRequest *)request
                  configuration:(WKWebViewConfiguration * _Nullable)configuration
           presentationCallback:(OIDWebViewControllerPresentationCallback)presentation
              dismissalCallback:(OIDWebViewControllerDismissalCallback)dismissal
             completionCallback:(OIDAuthorizationCallback)completion {
  OIDAuthorizationFlowSessionImplementation *flow =
      [[OIDAuthorizationFlowSessionImplementation alloc] initWithRequest:request];
  [flow presentWebViewControllerWithConfiguration:configuration ?: [[WKWebViewConfiguration alloc] init]
                             presentationCallback:presentation
                                dismissalCallback:dismissal
                               completionCallback:completion];
  return flow;
}
#endif

#pragma mark - Token Endpoint

+ (void)performTokenRequest:(OIDTokenRequest *)request callback:(OIDTokenCallback)callback {
  NSURLRequest *URLRequest = [request URLRequest];
  NSURLSession *session = [NSURLSession sharedSession];
  [[session dataTaskWithRequest:URLRequest
              completionHandler:^(NSData *_Nullable data,
                                  NSURLResponse *_Nullable response,
                                  NSError *_Nullable error) {
    if (error) {
      // A network error or server error occurred.
      NSError *returnedError =
          [OIDErrorUtilities errorWithCode:OIDErrorCodeNetworkError
                           underlyingError:error
                               description:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        callback(nil, returnedError);
      });
      return;
    }

    NSHTTPURLResponse *HTTPURLResponse = (NSHTTPURLResponse *)response;

    if (HTTPURLResponse.statusCode != 200) {
      // A server error occurred.
      NSError *serverError =
          [OIDErrorUtilities HTTPErrorWithHTTPResponse:HTTPURLResponse data:data];

      // HTTP 400 may indicate an RFC6749 Section 5.2 error response, checks for that
      if (HTTPURLResponse.statusCode == 400) {
        NSError *jsonDeserializationError;
        NSDictionary<NSString *, NSObject<NSCopying> *> *json =
            [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonDeserializationError];

        // if the HTTP 400 response parses as JSON and has an 'error' key, it's an OAuth error
        // these errors are special as they indicate a problem with the authorization grant
        if (json[OIDOAuthErrorFieldError]) {
          NSError *oauthError =
            [OIDErrorUtilities OAuthErrorWithDomain:OIDOAuthTokenErrorDomain
                                      OAuthResponse:json
                                    underlyingError:serverError];
          dispatch_async(dispatch_get_main_queue(), ^{
            callback(nil, oauthError);
          });
          return;
        }
      }

      // not an OAuth error, just a generic server error
      NSError *returnedError =
          [OIDErrorUtilities errorWithCode:OIDErrorCodeServerError
                           underlyingError:serverError
                               description:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        callback(nil, returnedError);
      });
      return;
    }

    NSError *jsonDeserializationError;
    NSDictionary<NSString *, NSObject<NSCopying> *> *json =
        [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonDeserializationError];
    if (jsonDeserializationError) {
      // A problem occurred deserializing the response/JSON.
      NSError *returnedError =
          [OIDErrorUtilities errorWithCode:OIDErrorCodeJSONDeserializationError
                           underlyingError:jsonDeserializationError
                               description:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        callback(nil, returnedError);
      });
      return;
    }

    OIDTokenResponse *tokenResponse =
        [[OIDTokenResponse alloc] initWithRequest:request parameters:json];
    if (!tokenResponse) {
      // A problem occurred constructing the token response from the JSON.
      NSError *returnedError =
          [OIDErrorUtilities errorWithCode:OIDErrorCodeTokenResponseConstructionError
                           underlyingError:jsonDeserializationError
                               description:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        callback(nil, returnedError);
      });
      return;
    }

    // Success
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(tokenResponse, nil);
    });
  }] resume];
}

@end

NS_ASSUME_NONNULL_END
