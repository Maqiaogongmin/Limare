#import "../MCPBridge.h"
@import AppAuth;

NSURL * _Nullable LimareStartMCPRedirectListener(OIDRedirectHTTPHandler *handler, NSError **error) {
    return [handler startHTTPListener:error withPort:0];
}
