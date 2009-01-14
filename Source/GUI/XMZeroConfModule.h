/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_ZERO_CONF_MODULE_H__
#define __XM_ZERO_CONF_MOUDLE_H__

#import <Cocoa/Cocoa.h>
//#import "XMMainWindowAdditionModule.h"

@interface XMZeroConfModule : NSObject <XMMainWindowAdditionModule> {

  IBOutlet NSView *contentView;
  NSSize contentViewSize;
  
  NSNib *nibLoader;
}

@end

#endif // __XM_ZERO_CONF_MODULE_H__