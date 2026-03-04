#import "VibeReactBridgeHolder.h"

#import <React/RCTBridge.h>

static id _Nullable sVibeBridgeObject = nil;

@interface VibeReactBridgeHolder ()
@property(nonatomic, weak, readwrite, nullable) RCTBridge *bridge;
@end

@implementation VibeReactBridgeHolder

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

+ (id _Nullable)currentBridgeObject {
  return sVibeBridgeObject;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(ping) {
  NSLog(@"[VibeNativeCall][BridgeHolder] ping hasBridge=%@",
        sVibeBridgeObject != nil ? @"true" : @"false");
  return @(YES);
}

- (void)setBridge:(RCTBridge *)bridge {
  _bridge = bridge;
  sVibeBridgeObject = bridge;
  NSLog(@"[VibeNativeCall][BridgeHolder] setBridge class=%@",
        NSStringFromClass([bridge class]));
}

@end
