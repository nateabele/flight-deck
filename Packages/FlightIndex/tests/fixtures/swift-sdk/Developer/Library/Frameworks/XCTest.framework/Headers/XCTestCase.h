#import <Foundation/Foundation.h>

@interface XCTestCase : NSObject
- (XCTestExpectation *)expectationWithDescription:(NSString *)description;
@end
