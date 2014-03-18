//
//  EncoderDemoViewController.h
//  Encoder Demo
//
//  Created by chenyu on 13-11-17.
//  Copyright (c) 2013年 ReNew. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface EncoderDemoViewController : UIViewController
@property (strong, nonatomic) IBOutlet UIView *cameraView;
@property (strong, nonatomic) IBOutlet UILabel *serverAddress;

- (void) startPreview;

@end
