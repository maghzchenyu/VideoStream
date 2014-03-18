//
//  RTSPClientConnection.h
//  Encoder Demo
//
//  Created by chenyu on 13-11-17.
//  Copyright (c) 2013年 ReNew. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "RTSPServer.h"

@interface RTSPClientConnection : NSObject


+ (RTSPClientConnection*) createWithSocket:(CFSocketNativeHandle) s server:(RTSPServer*) server;

- (void) onVideoData:(NSArray*) data time:(double) pts;
- (void) shutdown;

@end
