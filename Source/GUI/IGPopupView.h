/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Ivan Guajana, Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

/* IGPopupView */
#ifndef __IGPopupView_H__
#define __IGPopupView_H__

#import <Cocoa/Cocoa.h>

@interface IGPopupView : NSPopUpButton {
@private
  NSBezierPath* oval, *triangle;
  NSRect area;
  NSString* title;
  NSDictionary* titleAttributes, *titleAttributesOver;
  NSTrackingRectTag trackingRect;
  float fontSize;
  
  BOOL mouseOver;
  BOOL showingTitleOfSelectedItem;
  
  IBOutlet NSMenu* theMenu;
}

- (void)setTitle:(NSString*)t;
- (void)setCustomMenu:(NSMenu*)m;


@end

#endif// __IGPopupView_H__
