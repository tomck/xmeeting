/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_RECENT_CALLS_VIEW_H__
#define __XM_RECENT_CALLS_VIEW_H__

#import <Cocoa/Cocoa.h>

/**
 * This view manages the a set of XMCallInfoView instances which represent
 * the recent calls made.
 **/
@interface XMRecentCallsView : NSView {
	
@private
  IBOutlet NSScrollView *scrollView;
  BOOL layoutDone;
}

- (void)noteSubviewHeightDidChange:(NSView *)subview;

@end

#endif // __XM_RECENT_CALLS_VIEW_H__
