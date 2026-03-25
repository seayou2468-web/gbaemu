#import "AppDelegate.h"
#import "SceneDelegate.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  (void)application;
  (void)launchOptions;
  return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                    options:(UISceneConnectionOptions *)options {
  (void)application;
  (void)connectingSceneSession;
  (void)options;
  UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default Configuration"
                                                                 sessionRole:UISceneSessionRoleApplication];
  config.delegateClass = [SceneDelegate class];
  return config;
}

@end
