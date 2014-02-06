/********* Echo.h Cordova Plugin Header *******/

#import <Cordova/CDVPlugin.h>

@interface Echo : CDVPlugin

- (void) echo:(NSMutableArray*)arguments withDict:(NSMutableDictionary*)options;

@end