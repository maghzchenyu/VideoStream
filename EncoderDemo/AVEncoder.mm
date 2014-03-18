//
//  AVEncoder.m
//  Encoder Demo
//
//  Created by chenyu on 13-11-17.
//  Copyright (c) 2013年 ReNew. All rights reserved.
//

#import "AVEncoder.h"
#import "NALUnit.h"

static unsigned int to_host(unsigned char* p)
{
    return (p[0] << 24) + (p[1] << 16) + (p[2] << 8) + p[3];
}

#define OUTPUT_FILE_SWITCH_POINT (50 * 1024 * 1024)  // 50 MB switch point
#define MAX_FILENAME_INDEX  5                       // filenames "capture1.mp4" wraps at capture5.mp4


@interface AVEncoder ()

{
    VideoEncoder* _headerWriter;
    
    VideoEncoder* _writer;
    
    NSFileHandle* _inputFile;
    dispatch_queue_t _readQueue;
    dispatch_source_t _readSource;
    
    BOOL _swapping;
    int _currentFile;
    int _height;
    int _width;
    
    NSData* _avcC;
    int _lengthSize;
    
    BOOL _foundMDAT;
    uint64_t _posMDAT;
    int _bytesToNextAtom;
    BOOL _needParams;
    
    int _prev_nal_idc;
    int _prev_nal_type;
    
    NSMutableArray* _pendingNALU;
    
    NSMutableArray* _times;
    
    encoder_handler_t _outputBlock;
    param_handler_t _paramsBlock;
    
    int _bitspersecond;
    double _firstpts;
}

- (void) initForHeight:(int) height andWidth:(int) width;

@end

@implementation AVEncoder

@synthesize bitspersecond = _bitspersecond;

+ (AVEncoder*) encoderForHeight:(int) height andWidth:(int) width
{
    AVEncoder* enc = [AVEncoder alloc];
    [enc initForHeight:height andWidth:width];
    return enc;
}

- (NSString*) makeFilename
{
    NSString* filename = [NSString stringWithFormat:@"capture%d.mp4", _currentFile];
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
    return path;
}
- (void) initForHeight:(int)height andWidth:(int)width
{
    _height = height;
    _width = width;
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"params.mp4"];
    _headerWriter = [VideoEncoder encoderForPath:path Height:height andWidth:width];
    _times = [NSMutableArray arrayWithCapacity:10];
    
    _currentFile = 1;
    _writer = [VideoEncoder encoderForPath:[self makeFilename] Height:height andWidth:width];
}

- (void) encodeWithBlock:(encoder_handler_t) block onParams: (param_handler_t) paramsHandler
{
    _outputBlock = block;
    _paramsBlock = paramsHandler;
    _needParams = YES;
    _pendingNALU = nil;
    _firstpts = -1;
    _bitspersecond = 0;
}

- (BOOL) parseParams:(NSString*) path
{
    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath:path];
    struct stat s;
    fstat([file fileDescriptor], &s);
    MP4Atom* movie = [MP4Atom atomAt:0 size:s.st_size type:(OSType)('file') inFile:file];
    MP4Atom* moov = [movie childOfType:(OSType)('moov') startAt:0];
    MP4Atom* trak = nil;
    if (moov != nil)
    {
        for (;;)
        {
            trak = [moov nextChild];
            if (trak == nil)
            {
                break;
            }
            
            if (trak.type == (OSType)('trak'))
            {
                MP4Atom* tkhd = [trak childOfType:(OSType)('tkhd') startAt:0];
                NSData* verflags = [tkhd readAt:0 size:4];
                unsigned char* p = (unsigned char*)[verflags bytes];
                if (p[3] & 1)
                {
                    break;
                }
                else
                {
                    tkhd = nil;
                }
            }
        }
    }
    MP4Atom* stsd = nil;
    if (trak != nil)
    {
        MP4Atom* media = [trak childOfType:(OSType)('mdia') startAt:0];
        if (media != nil)
        {
            MP4Atom* minf = [media childOfType:(OSType)('minf') startAt:0];
            if (minf != nil)
            {
                MP4Atom* stbl = [minf childOfType:(OSType)('stbl') startAt:0];
                if (stbl != nil)
                {
                    stsd = [stbl childOfType:(OSType)('stsd') startAt:0];
                }
            }
        }
    }
    if (stsd != nil)
    {
        MP4Atom* avc1 = [stsd childOfType:(OSType)('avc1') startAt:8];
        if (avc1 != nil)
        {
            MP4Atom* esd = [avc1 childOfType:(OSType)('avcC') startAt:78];
            if (esd != nil)
            {
               
                _avcC = [esd readAt:0 size:esd.length];
                if (_avcC != nil)
                {
                    unsigned char* p = (unsigned char*)[_avcC bytes];
                    _lengthSize = (p[4] & 3) + 1;
                    return YES;
                }
            }
        }
    }
    return NO;
}

- (void) onParamsCompletion
{
   
    if ([self parseParams:_headerWriter.path])
    {
        if (_paramsBlock)
        {
            _paramsBlock(_avcC);
        }
        _headerWriter = nil;
        _swapping = NO;
        _inputFile = [NSFileHandle fileHandleForReadingAtPath:_writer.path];
        _readQueue = dispatch_queue_create("uk.co.gdcl.avencoder.read", DISPATCH_QUEUE_SERIAL);
        
        _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, [_inputFile fileDescriptor], 0, _readQueue);
        dispatch_source_set_event_handler(_readSource, ^{
            [self onFileUpdate];
        });
        dispatch_resume(_readSource);
    }
}

- (void) encodeFrame:(CMSampleBufferRef) sampleBuffer
{
    @synchronized(self)
    {
        if (_needParams)
        {
            _needParams = NO;
            if ([_headerWriter encodeFrame:sampleBuffer])
            {
                [_headerWriter finishWithCompletionHandler:^{
                    [self onParamsCompletion];
                }];
            }
        }
    }
    CMTime prestime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    double dPTS = (double)(prestime.value) / prestime.timescale;
    NSNumber* pts = [NSNumber numberWithDouble:dPTS];
    @synchronized(_times)
    {
        [_times addObject:pts];
    }
    @synchronized(self)
    {
        if (!_swapping)
        {
            struct stat st;
            fstat([_inputFile fileDescriptor], &st);
            if (st.st_size > OUTPUT_FILE_SWITCH_POINT)
            {
                _swapping = YES;
                VideoEncoder* oldVideo = _writer;
                
                if (++_currentFile > MAX_FILENAME_INDEX)
                {
                    _currentFile = 1;
                }
                NSLog(@"Swap to file %d", _currentFile);
                _writer = [VideoEncoder encoderForPath:[self makeFilename] Height:_height andWidth:_width];
                
                dispatch_source_cancel(_readSource);
                
                dispatch_async(_readQueue, ^{
                    
                    _readSource = nil;
                    [oldVideo finishWithCompletionHandler:^{
                        [self swapFiles:oldVideo.path];
                    }];
                });
            }
        }
        [_writer encodeFrame:sampleBuffer];
    }
}

- (void) swapFiles:(NSString*) oldPath
{
    uint64_t pos = [_inputFile offsetInFile];
    
    [_inputFile seekToFileOffset:_posMDAT];
    NSData* hdr = [_inputFile readDataOfLength:4];
    unsigned char* p = (unsigned char*) [hdr bytes];
    int lenMDAT = to_host(p);

    uint64_t posEnd = _posMDAT + lenMDAT;
    uint32_t cRead = (uint32_t)(posEnd - pos);
    [_inputFile seekToFileOffset:pos];
    [self readAndDeliver:cRead];
    
    [_inputFile closeFile];
    _foundMDAT = false;
    _bytesToNextAtom = 0;
    [[NSFileManager defaultManager] removeItemAtPath:oldPath error:nil];
    
    
    _inputFile = [NSFileHandle fileHandleForReadingAtPath:_writer.path];
    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, [_inputFile fileDescriptor], 0, _readQueue);
    dispatch_source_set_event_handler(_readSource, ^{
        [self onFileUpdate];
    });
    dispatch_resume(_readSource);
    _swapping = NO;
}


- (void) readAndDeliver:(uint32_t) cReady
{
    while (cReady > _lengthSize)
    {
        NSData* lenField = [_inputFile readDataOfLength:_lengthSize];
        cReady -= _lengthSize;
        unsigned char* p = (unsigned char*) [lenField bytes];
        unsigned int lenNALU = to_host(p);
        
        if (lenNALU > cReady)
        {
        
            [_inputFile seekToFileOffset:[_inputFile offsetInFile] - 4];
            break;
        }
        NSData* nalu = [_inputFile readDataOfLength:lenNALU];
        cReady -= lenNALU;
        
        [self onNALU:nalu];
    }
}

- (void) onFileUpdate
{
    struct stat s;
    fstat([_inputFile fileDescriptor], &s);
    int cReady = s.st_size - [_inputFile offsetInFile];
    
    while (!_foundMDAT && (cReady > 8))
    {
        if (_bytesToNextAtom == 0)
        {
            NSData* hdr = [_inputFile readDataOfLength:8];
            cReady -= 8;
            unsigned char* p = (unsigned char*) [hdr bytes];
            int lenAtom = to_host(p);
            unsigned int nameAtom = to_host(p+4);
            if (nameAtom == (unsigned int)('mdat'))
            {
                _foundMDAT = true;
                _posMDAT = [_inputFile offsetInFile] - 8;
            }
            else
            {
                _bytesToNextAtom = lenAtom - 8;
            }
        }
        if (_bytesToNextAtom > 0)
        {
            int cThis = cReady < _bytesToNextAtom ? cReady :_bytesToNextAtom;
            _bytesToNextAtom -= cThis;
            [_inputFile seekToFileOffset:[_inputFile offsetInFile]+cThis];
            cReady -= cThis;
        }
    }
    
    if (!_foundMDAT)
    {
        return;
    }
    
    [self readAndDeliver:cReady];
}

- (void) onEncodedFrame
{
    double pts = 0;
    @synchronized(_times)
    {
        if ([_times count] > 0)
        {
            pts = [_times[0] doubleValue];
            [_times removeObjectAtIndex:0];
            if (_firstpts < 0)
            {
                _firstpts = pts;
            }
            if ((pts - _firstpts) < 1)
            {
                int bytes = 0;
                for (NSData* data in _pendingNALU)
                {
                    bytes += [data length];
                }
                _bitspersecond += (bytes * 8);
            }
        }
        else
        {
            NSLog(@"no pts for buffer");
        }
    }
    if (_outputBlock != nil)
    {
        _outputBlock(_pendingNALU, pts);
    }
}

- (void) onNALU:(NSData*) nalu
{
    unsigned char* pNal = (unsigned char*)[nalu bytes];
    int idc = pNal[0] & 0x60;
    int naltype = pNal[0] & 0x1f;

    if (_pendingNALU)
    {
        NALUnit nal(pNal, [nalu length]);
        
        BOOL bNew = NO;
        if ((idc != _prev_nal_idc) && ((idc * _prev_nal_idc) == 0))
        {
            bNew = YES;
        }
        else if ((naltype != _prev_nal_type) && ((naltype == 5) || (_prev_nal_type == 5)))
        {
            bNew = YES;
        }
        else if ((naltype >= 1) && (naltype <= 5))
        {
            nal.Skip(8);
            int first_mb = nal.GetUE();
            if (first_mb == 0)
            {
                bNew = YES;
            }
        }
        if (bNew)
        {
            [self onEncodedFrame];
            _pendingNALU = nil;
        }
    }
    _prev_nal_type = naltype;
    _prev_nal_idc = idc;
    if (_pendingNALU == nil)
    {
        _pendingNALU = [NSMutableArray arrayWithCapacity:2];
    }
    [_pendingNALU addObject:nalu];
}

- (NSData*) getConfigData
{
    return [_avcC copy];
}

- (void) shutdown
{
    @synchronized(self)
    {
        _readSource = nil;
        if (_headerWriter)
        {
            [_headerWriter finishWithCompletionHandler:^{
                _headerWriter = nil;
            }];
        }
        if (_writer)
        {
            [_writer finishWithCompletionHandler:^{
                _writer = nil;
            }];
        }
    }
}

@end