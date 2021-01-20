//
//  JPObject.m
//  JSPatchDemo
//
//  Created by suyoulong on 2020/4/23.
//  Copyright © 2020 bang. All rights reserved.
//

#import "JPObject.h"

@implementation JPObject

typedef void (^JSBlock)(NSDictionary *dict);

+ (void)request:(void(^)(NSString *content, BOOL success))callback
{
  callback(@"I'm content", YES);
}

+ (JSBlock)genBlock
{
  NSString *ctn = @"JSPatch";
  JSBlock block = ^(NSDictionary *dict) {
      NSLog(@"I'm %@, version: %@", ctn, dict[@"v"]);
  };
  return block;
}

+ (void)requestUrl:(NSString *)url withCallback:(void(^)(id data))callback {
    NSLog(@"%@",url);
    callback(@"syl");
}

//+ (void)execBlock:(JSBlock)blk
//{
//    NSLog(@"123");
//}

@end
