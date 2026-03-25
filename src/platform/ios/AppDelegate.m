#import "AppDelegate.h"
#import "SceneDelegate.h"

@implementation AppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                    options:(UISceneConnectionOptions *)options {
  (void)application;
  (void)options;

  UISceneConfiguration *config =
      [UISceneConfiguration configurationWithName:nil sessionRole:connectingSceneSession.role];
  config.delegateClass = [SceneDelegate class];
  return config;
}

@end
