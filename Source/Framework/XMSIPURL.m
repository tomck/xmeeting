/*
 * Copyright (c) 2007-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2007-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#import "XMSIPURL.h"

#import "XMStringConstants.h"
#import "XMPrivate.h"
#import "XMURLParser.h"

#define PREFIX @"sip:"

@implementation XMSIPURL

#pragma mark -
#pragma mark Class Methods

+ (BOOL)canHandleStringRepresentation:(NSString *)url
{
  return [url hasPrefix:PREFIX];
}

+ (BOOL)canHandleDictionaryRepresentation:(NSDictionary *)dict
{
  return NO;
}

+ (XMSIPURL *)addressResourceWithStringRepresentation:(NSString *)url
{
  XMSIPURL *sipURL = [[XMSIPURL alloc] initWithStringRepresentation:url];
  if (sipURL != nil) {
    return [sipURL autorelease];
  }
  return nil;
}

+ (XMSIPURL *)addressResourceWithDictionaryRepresentation:(NSDictionary *)dict
{
  return nil;
}

#pragma mark -
#pragma mark Overriding from XMURL

- (XMCallProtocol)callProtocol
{
  return XMCallProtocol_SIP;
}

- (NSString *)_prefix
{
  return PREFIX;
}

- (BOOL)_parseString:(const char *)string usingCallback:(XMURLParseCallback)callback
{
  return _XMParseSIPURI(string, callback, (void*)self);
}

@end

