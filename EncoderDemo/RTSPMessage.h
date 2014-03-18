//
//  RTSPMessage.h
//  Encoder Demo
//
//  Created by chenyu on 13-11-17.
//  Copyright (c) 2013年 ReNew. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface RTSPMessage : NSObject


+ (RTSPMessage*) createWithData:(CFDataRef) data;

- (NSString*) valueForOption:(NSString*) option;
- (NSString*) createResponse:(int) code text:(NSString*) desc;

@property NSString* command;
@property int sequence;

@end
