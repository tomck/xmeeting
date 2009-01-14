/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_DUMMY_VIDEO_INPUT_MODULE_H__
#define __XM_DUMMY_VIDEO_INPUT_MODULE_H__

#import <Cocoa/Cocoa.h>
#import "XMVideoInputModule.h"

@interface XMDummyVideoInputModule : NSObject <XMVideoInputModule> {

@private
  id<XMVideoInputManager> inputManager;	
  NSArray *device;
  XMVideoSize videoSize;
}

- (id)_init;

+ (CVPixelBufferRef)getDummyImageForVideoSize:(XMVideoSize)videoSize; //XMVideoSize_NoVideo releases buffer

@end

#endif // __XM_DUMMY_VIDEO_INPUT_MODULE_H__
