#import <Foundation/Foundation.h>
@class OIDRedirectHTTPHandler;

/// AppAuth documents nil on bind failure but imports its return as nonoptional URL.
/// Keep the documented nullable boundary before Swift bridges NSURL to URL.
NSURL * _Nullable LimareStartMCPRedirectListener(OIDRedirectHTTPHandler * _Nonnull handler,
                                                NSError * _Nullable * _Nullable error);
