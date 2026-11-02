/*	NSFileManager.h
	A cut-down header for the package-view tests.
*/
@class NSURL;

@interface NSFileManager : NSObject

@property (class, readonly, strong) NSFileManager *defaultManager;

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)removeItemAtURL:(NSURL *)URL error:(NSError **)error;
- (BOOL)fileExistsAtPath:(NSString *)path;

@end
