/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_BOOLEAN_CELL_H__
#define __XM_BOOLEAN_CELL_H__

#import <Cocoa/Cocoa.h>

/**
 * This cell displays a Boolean value in a textual representation and edits the value through
 * a simple PopUp Menu containing the two boolean values
 **/
@interface XMBooleanCell : NSComboBoxCell {

}

- (BOOL)doesPopUp;
- (void)setDoesPopUp:(BOOL)flag;

@end

#endif // __XM_BOOLEAN_CELL_H__
