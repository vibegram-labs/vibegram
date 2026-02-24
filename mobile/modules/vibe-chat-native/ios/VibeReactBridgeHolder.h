#import <Foundation/Foundation.h>
#import <React/RCTBridgeModule.h>

NS_ASSUME_NONNULL_BEGIN

@interface VibeReactBridgeHolder : NSObject <RCTBridgeModule>

+ (id _Nullable)currentBridgeObject;

@end

NS_ASSUME_NONNULL_END
