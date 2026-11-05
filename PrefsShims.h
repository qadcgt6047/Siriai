//
//  PrefsShims.h
//  Settings.app 私有框架 Preferences.framework 的最小声明。
//
//  刻意不 #import <Preferences/...>：roothide 的 SDK 里往往没有私有框架头文件，
//  这些声明 + Makefile 里的 -undefined dynamic_lookup 即可在运行时正确解析。
//  只在 Preferences.app 进程中加载 SiriAIPrefs.dylib，因此 PSListController
//  一定已经由系统加载，子类化是安全的。
//

#ifndef PrefsShims_h
#define PrefsShims_h

#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(Class)cell
                                    edit:(Class)edit;
- (NSDictionary *)properties;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (void)removePropertyForKey:(NSString *)key;
- (NSString *)name;
- (void)setName:(NSString *)name;
- (NSString *)identifier;
@end

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (id)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)reloadSpecifiers;
- (void)reload;
@end

#endif /* PrefsShims_h */
