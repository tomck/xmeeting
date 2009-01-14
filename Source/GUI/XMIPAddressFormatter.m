/*
 * Copyright (c) 2007-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2007-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#import "XMIPAddressFormatter.h"
#import "XMeeting.h"

@implementation XMIPAddressFormatter

- (NSString *)stringForObjectValue:(id)anObject
{
  if (![anObject isKindOfClass:[NSString class]]) {
    return nil;
  }
  
  if (!XMIsIPAddress((NSString *)anObject)) {
    return nil;
  }
  
  return (NSString *)anObject;
}

- (BOOL)getObjectValue:(id *)anObject forString:(NSString *)string errorDescription:(NSString **)error
{
  if (XMIsIPAddress(string)) {
    *anObject = string;
    return YES;
  } else {
    if (error != NULL) {
      *error = @"Not an IP Address"; 
    }
    return NO;
  }
}

@end
