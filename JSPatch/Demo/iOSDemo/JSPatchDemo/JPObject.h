//
//  JPObject.h
//  JSPatchDemo
//
//  Created by suyoulong on 2020/4/23.
//  Copyright © 2020 bang. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JPObject : NSObject

+ (void)request:(void(^)(NSString *content, BOOL success))callback;

@end

NS_ASSUME_NONNULL_END
