//
//  WallpaperPrivate.h
//  LiveWallWallpaper
//
//  Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
//  Source: PhospheneExtension/WallpaperExtension-Bridging-Header.h at commit db03edf.
//  See THIRD_PARTY_NOTICES.md for the full license text.
//
//  Objective-C declarations of the private WallpaperExtensionKit XPC protocols.
//  NSXPC matches methods by selector and type encoding, not by protocol name, so
//  these local declarations describe the same wire interface WallpaperAgent uses.
//  The XPC value classes themselves are looked up at runtime after dlopen.
//
//  CAContext is deliberately NOT declared here: the extension reaches it through
//  the Objective-C runtime (NSClassFromString / performSelector / KVC) so the
//  build never depends on an SDK stub exporting the private class.
//

#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Private NSXPCConnection caller identity
//
// NSXPCConnection exposes the connecting peer's audit token as private API.
// Declaring it here lets Swift read the token to validate the caller's code
// signature before accepting a connection. Guarded with -respondsToSelector:
// at the call site so a future OS that drops the SPI degrades gracefully.

@interface NSXPCConnection (LiveWallCallerIdentity)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

NS_ASSUME_NONNULL_END

// requestReadOnlyAccessTo:reply: replies with (NSSecurityScopedURLWrapper, NSError) on 26.6.2,
// `@?<v@?@"NSSecurityScopedURLWrapper"@"NSError">`. LiveWall does not call it yet.
// All other methods in both protocols match the host's shapes.

@protocol WallpaperExtensionProxyXPCProtocol <NSObject>
- (void)pingWithId:(id _Nullable)anId;
- (void)updateSettingsViewModels:(id _Nullable)models reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)requestReadOnlyAccessTo:(id _Nullable)url reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)invalidateSnapshotsWithReply:(void (^ _Nonnull)(NSError * _Nullable))reply;
@end

// MARK: - Host → Extension protocol (what WallpaperAgent calls on us)

@protocol WallpaperExtensionXPCProtocol <NSObject>

// Lifecycle
- (void)acquireWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)updateWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invalidateWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)snapshotWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Settings
- (void)provideSettingsViewModelsWithContentTypes:(id _Nullable)types reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Choices
- (void)addChoiceRequestWithChoiceRequest:(id _Nullable)request onBehalfOfProcess:(id _Nullable)process reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)selectedChoicesDidChangeFor:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invokeContextMenuActionWithMenuItemID:(id _Nullable)menuItemID groupItemID:(id _Nullable)groupItemID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Downloads
// The reply carries an NSNumber-boxed Bool (`@?<v@?@"NSNumber"@"NSError">`). Declaring a bare BOOL
// makes NSXPC reject the call as an undecodable message and cancel the whole agent connection.
- (void)isChoiceDownloadedWith:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSNumber * _Nullable, NSError * _Nullable))reply;
- (id _Nullable)downloadWithChoiceID:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)pauseDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)cancelDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)resumeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)removeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Migration
- (void)migrateSelectedChoiceFor:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)migrateFrom:(id _Nullable)from to:(id _Nullable)to reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Shuffle
- (void)skipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)canSkipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;

// Debug & notifications
- (void)handleDebugRequestFor:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)handleNotificationWithNamed:(id _Nullable)name reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

@end
