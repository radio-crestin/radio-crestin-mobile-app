#import "FlutterAirplayPlugin.h"
#if __has_include(<flutter_airplay/flutter_airplay-Swift.h>)
#import <flutter_airplay/flutter_airplay-Swift.h>
#else
#import "flutter_airplay-Swift.h"
#endif

@implementation FlutterAirplayPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftFlutterAirplayPlugin registerWithRegistrar:registrar];
}
@end
