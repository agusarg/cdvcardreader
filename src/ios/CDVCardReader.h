//
//  CDVCardReader.h
//  cashmobile
//
//  Created by Agustin Andreucci on 2/2/14.
//
//

#import <Cordova/CDVPlugin.h>
#import <Foundation/Foundation.h>
#import "AudioUnit/AudioUnit.h"
#import "AudioUnit/AUComponent.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface CDVCardReader : CDVPlugin

- (void) init:(NSMutableArray*)arguments withDict:(NSMutableDictionary*)options;
- (void) startRead:(NSMutableArray*)arguments withDict:(NSMutableDictionary*)options;
- (void) stopRead:(NSMutableArray*)arguments withDict:(NSMutableDictionary*)options;
- (void) getStatus:(NSMutableArray*)arguments withDict:(NSMutableDictionary*)options;

@end
