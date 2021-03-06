/*! @file OIDAuthorizationService.h
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

#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
# import <UIKit/UIKit.h>
#else
# import <Cocoa/Cocoa.h>
# import <WebKit/WebKit.h>
# import "OIDWebViewController.h"
#endif

@class OIDAuthorization;
@class OIDAuthorizationRequest;
@class OIDAuthorizationResponse;
@class OIDServiceConfiguration;
@class OIDTokenRequest;
@class OIDTokenResponse;
@protocol OIDAuthorizationFlowSession;

NS_ASSUME_NONNULL_BEGIN

/*! @typedef OIDDiscoveryCallback
    @brief Represents the type of block used as a callback for creating a service configuration from
        a remote OpenID Connect Discovery document.
    @param configuration The service configuration, if available.
    @param error The error if an error occurred.
 */
typedef void (^OIDDiscoveryCallback)(OIDServiceConfiguration *_Nullable configuration,
                                     NSError *_Nullable error);

/*! @typedef OIDAuthorizationCallback
    @brief Represents the type of block used as a callback for various methods of
        @c OIDAuthorizationService.
    @param authorizationResponse The authorization response, if available.
    @param error The error if an error occurred.
 */
typedef void (^OIDAuthorizationCallback)(OIDAuthorizationResponse *_Nullable authorizationResponse,
                                         NSError *_Nullable error);

/*! @typedef OIDTokenCallback
    @brief Represents the type of block used as a callback for various methods of
        @c OIDAuthorizationService.
    @param tokenResponse The token response, if available.
    @param error The error if an error occurred.
 */
typedef void (^OIDTokenCallback)(OIDTokenResponse *_Nullable tokenResponse,
                                 NSError *_Nullable error);

/*! @typedef OIDTokenEndpointParameters
    @brief Represents the type of dictionary used to specify additional querystring parameters
        when making authorization or token endpoint requests.
 */
typedef NSDictionary<NSString *, NSString *> *_Nullable OIDTokenEndpointParameters;

/*! @class OIDAuthorizationService
    @brief Performs various OAuth and OpenID Connect related RPCs via \SFSafariViewController or
        \NSURLSession.
 */
@interface OIDAuthorizationService : NSObject

/*! @property configuration
    @brief The service's configuration.
    @remarks Each authorization service is initialized with a configuration. This configuration
        specifies how to connect to a particular OAuth provider. Clients should use separate
        authorization service instances for each provider they wish to integrate with.
        Configurations may be created manually, or via an OpenID Connect Discovery Document.
 */
@property(nonatomic, readonly) OIDServiceConfiguration *configuration;

/*! @fn init
    @internal
    @brief Unavailable. This class should not be initialized.
 */
- (nullable instancetype)init NS_UNAVAILABLE;

/*! @fn discoverServiceConfigurationForIssuer:completion:
    @brief Convenience method for creating an authorization service configuration from an OpenID
        Connect compliant issuer URL.
    @param issuerURL The service provider's OpenID Connect issuer.
    @param completion A block which will be invoked when the authorization service configuration has
        been created, or when an error has occurred.
    @see https://openid.net/specs/openid-connect-discovery-1_0.html
 */
+ (void)discoverServiceConfigurationForIssuer:(NSURL *)issuerURL
                                   completion:(OIDDiscoveryCallback)completion;


/*! @fn discoverServiceConfigurationForDiscoveryURL:completion:
    @brief Convenience method for creating an authorization service configuration from an OpenID
        Connect compliant identity provider's discovery document.
    @param discoveryURL The URL of the service provider's OpenID Connect discovery document.
    @param completion A block which will be invoked when the authorization service configuration has
        been created, or when an error has occurred.
    @see https://openid.net/specs/openid-connect-discovery-1_0.html
 */
+ (void)discoverServiceConfigurationForDiscoveryURL:(NSURL *)discoveryURL
                                         completion:(OIDDiscoveryCallback)completion;

#if TARGET_OS_IPHONE
/*! @fn presentAuthorizationRequest:presentingViewController:callback:
    @brief Perform an authorization flow using \SFSafariViewController.
    @param request The authorization request.
    @param presentingViewController The view controller from which to present the
        \SFSafariViewController.
    @param callback The method called when the request has completed or failed.
    @return A @c OIDAuthorizationFlowSession instance which will terminate when it
        receives a @c OIDAuthorizationFlowSession.cancel message, or after processing a
        @c OIDAuthorizationFlowSession.resumeAuthorizationFlowWithURL: message.
 */
+ (id<OIDAuthorizationFlowSession>)
    presentAuthorizationRequest:(OIDAuthorizationRequest *)request
       presentingViewController:(UIViewController *)presentingViewController
                       callback:(OIDAuthorizationCallback)callback;
#else
/*! @fn presentAuthorizationRequest:presentationCallback:dismissalCallback:completionCallback:
    @brief Perform an authorization flow using a web view controller.
    @param request The authorization request.
    @param configuration Optional WKWebView configuration. If nil is passed, the default
        configuration is used.
    @param presentation Callback to present the web view controller.
    @param dismissal Callback to dismiss the presented the web view controller.
    @param completion The method called when the request has completed or failed.
    @return A @c OIDAuthorizationFlowSession instance which will terminate when it
        receives a @c OIDAuthorizationFlowSession.cancel message, or after processing a
        @c OIDAuthorizationFlowSession.resumeAuthorizationFlowWithURL: message.
 */
+ (id<OIDAuthorizationFlowSession>)
    presentAuthorizationRequest:(OIDAuthorizationRequest *)request
    configuration:(WKWebViewConfiguration * _Nullable)configuration
    presentationCallback:(OIDWebViewControllerPresentationCallback)presentation
    dismissalCallback:(OIDWebViewControllerDismissalCallback)dismissal
    completionCallback:(OIDAuthorizationCallback)completion;
#endif

/*! @fn performTokenRequest:callback:
    @brief Performs a token request.
    @param request The token request.
    @param callback The method called when the request has completed or failed.
 */
+ (void)performTokenRequest:(OIDTokenRequest *)request callback:(OIDTokenCallback)callback;

@end

/*! @protocol OIDAuthorizationFlowSession
    @brief Represents an in-flight authorization flow session.
 */
@protocol OIDAuthorizationFlowSession <NSObject>

/*! @brief Cancels the code flow session, invoking the request's callback with a cancelled error.
    @remarks Has no effect if called more than once, or after a
        @c OIDAuthorizationFlowSession.resumeAuthorizationFlowWithURL: message was received. Will
        cause an error with code: @c ::OIDErrorCodeProgramCanceledAuthorizationFlow to be passed to
        the @c callback block passed to
        @c OIDAuthorizationService.presentAuthorizationRequest:presentingViewController:callback:
 */
- (void)cancel;

/*! @brief Clients should call this method with the result of the authorization code flow if it
        becomes available. Causes the \SFSafariViewController created by the
        @c OIDAuthorizationService::presentAuthorizationRequest:presentingViewController:callback:
        method to be dismissed, the pending request's completion block is invoked, and this method
        returns.
    @param URL The redirect URL invoked by the authorization server.
    @remarks Has no effect if called more than once, or after a @c cancel message was received.
    @return YES if the passed URL matches the expected redirect URL and was consumed, NO otherwise.
 */
- (BOOL)resumeAuthorizationFlowWithURL:(NSURL *)URL;

@end

NS_ASSUME_NONNULL_END
