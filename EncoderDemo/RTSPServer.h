//
//  RTSPServer.h
//  Encoder Demo
//
//  Created by chenyu on 13-11-17.
//  Copyright (c) 2013年 ReNew. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h> 
#include <sys/socket.h> 
#include <netinet/in.h>

@interface RTSPServer : NSObject


+ (NSString*) getIPAddress;
+ (RTSPServer*) setupListener:(NSData*) configData;

- (NSData*) getConfigData;
- (void) onVideoData:(NSArray*) data time:(double) pts;
- (void) shutdownConnection:(id) conn;
- (void) shutdownServer;

@property (readwrite, atomic) int bitrate;

@end
