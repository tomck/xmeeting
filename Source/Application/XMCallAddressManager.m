/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#import "XMCallAddressManager.h"
#import "XMApplicationController.h"
#import "XMPreferencesManager.h"
#import "XMLocation.h"

@interface XMCallAddressManager (PrivateMethods)

- (id)_init;

- (void)_callEnded:(NSNotification *)notif;
- (void)_frameworkDidInitialize:(NSNotification *)notif;

@end

@implementation XMCallAddressManager

#pragma mark Class Methods

+ (XMCallAddressManager *)sharedInstance
{
  static XMCallAddressManager *sharedInstance = nil;
  
  if (sharedInstance == nil) {
    sharedInstance = [[XMCallAddressManager alloc] _init];
  }
  return sharedInstance;
}

#pragma mark Init & Deallocation Methods

- (id)init
{
  [self doesNotRecognizeSelector:_cmd];
  [self release];
  return nil;
}

- (id)_init
{
  callAddressProviders = [[NSMutableArray alloc] initWithCapacity:3];
  activeCallAddress = nil;
  addressToCallWhenInitialized = nil;
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_callEnded:)
                                               name:XMNotification_CallManagerDidNotStartCalling object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_callEnded:)
                                               name:XMNotification_CallManagerDidClearCall object:nil];  
  // use the _didInitialize notification to ensure the location is properly set
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_frameworkDidInitialize:)
                                               name:XMNotification_CallManagerDidEndSubsystemSetup object:nil];
  return self;
}

- (void)dealloc
{
  [callAddressProviders release];
  
  [activeCallAddress release];
  [addressToCallWhenInitialized release];
  
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  
  [super dealloc];
}

#pragma mark handling CallAddressProviders

- (void)addCallAddressProvider:(id<XMCallAddressProvider>)provider
{
  [callAddressProviders addObject:provider];
}

- (void)removeCallAddressProvider:(id<XMCallAddressProvider>)provider
{
  [callAddressProviders removeObject:provider];
}

#pragma mark handling call addresses

- (NSArray *)addressesMatchingString:(NSString *)searchString
{
  unsigned count = [callAddressProviders count];
  
  NSMutableArray *matches = [NSMutableArray arrayWithCapacity:10];
  
  for (unsigned i = 0; i < count; i++) {
    id<XMCallAddressProvider> provider = (id<XMCallAddressProvider>)[callAddressProviders objectAtIndex:i];
    NSArray *providerMatches = [provider addressesMatchingString:searchString];
    
    [matches addObjectsFromArray:providerMatches];
  }
  
  return matches;
}

- (NSArray *)addressesMatchingString:(NSString *)searchString allowedProtocols:(XMCallProtocol)allowedProtocols
{
  unsigned count = [callAddressProviders count];
  NSMutableArray *matches = [NSMutableArray arrayWithCapacity:10];
  for (unsigned i = 0; i < count; i++) {
    id<XMCallAddressProvider> provider = (id<XMCallAddressProvider>)[callAddressProviders objectAtIndex:i];
    NSArray *providerMatches = [provider addressesMatchingString:searchString];
    unsigned numMatches = [providerMatches count];
    for (unsigned j = 0; j < numMatches; j++) {
      id<XMCallAddress> callAddress = (id<XMCallAddress>)[providerMatches objectAtIndex:j];
      XMCallProtocol protocol = [[callAddress addressResource] callProtocol];
      if ((protocol & allowedProtocols) != 0) {
        [matches addObject:callAddress];
      }
    }
  }
  return matches;
}

- (NSString *)completionStringForAddress:(id<XMCallAddress>)address uncompletedString:(NSString *)uncompletedString
{
  id<XMCallAddressProvider> provider = [address provider];
  
  if (provider == nil) {
    return nil;
  }
  return [provider completionStringForAddress:address uncompletedString:uncompletedString];
}

- (id<XMCallAddress>)addressMatchingResource:(XMAddressResource *)addressResource
{
  unsigned count = [callAddressProviders count];
  
  for (unsigned i = 0; i < count; i++) 
  {
    id<XMCallAddressProvider> provider = (id<XMCallAddressProvider>)[callAddressProviders objectAtIndex:i];
    id<XMCallAddress> address = [provider addressMatchingResource:addressResource];
    if (address != nil) {
      return address;
    }
  }
  return nil;
}

- (NSArray *)alternativesForAddress:(id<XMCallAddress>)address selectedIndex:(unsigned *)selectedIndex
{
  id<XMCallAddressProvider> provider = [address provider];
  
  if (provider == nil) {
    return [NSArray array];
  }
  return [provider alternativesForAddress:address selectedIndex:selectedIndex];
}

- (id<XMCallAddress>)alternativeForAddress:(id<XMCallAddress>)address atIndex:(unsigned)index
{
  id<XMCallAddressProvider> provider = [address provider];
  
  if (provider == nil) {
    return nil;
  }
  
  return [provider alternativeForAddress:address atIndex:index];
}

- (NSArray *)allAddresses
{
  NSMutableArray *addresses = [NSMutableArray arrayWithCapacity:20];
  unsigned count = [callAddressProviders count]; 
  for (unsigned i = 0; i < count; i++) {
    id<XMCallAddressProvider> provider = (id<XMCallAddressProvider>)[callAddressProviders objectAtIndex:i];
    if ([provider priorityForAllAddresses] == XMProviderPriority_Normal) {
      NSArray *addr = [provider allAddresses];
      [addresses addObjectsFromArray:addr];
    }
  }
  for (unsigned i = 0; i < count; i++) {
    id<XMCallAddressProvider> provider = (id<XMCallAddressProvider>)[callAddressProviders objectAtIndex:i];
    if ([provider priorityForAllAddresses] == XMProviderPriority_Low) {
      NSArray *addr = [provider allAddresses];
      [addresses addObjectsFromArray:addr];
    }
  }
  
  return addresses;
}

- (id<XMCallAddress>)activeCallAddress
{
  return activeCallAddress;
}

- (void)makeCallToAddress:(id<XMCallAddress>)callAddress
{
  if (activeCallAddress != nil) {
    NSLog(@"Illegal, active callAddress not nil");
    return;
  }
  
  if (callAddress == nil || [[[callAddress addressResource] address] isEqualToString:@""]) {
    NSLog(@"nil or EMPTY ADDRESS!");
    return;
  }
  
  if (!XMIsInitialized()) {
    // framework not yet ready (e.g. if call initiated through a script)
    [addressToCallWhenInitialized release];
    addressToCallWhenInitialized = [callAddress retain];
    return;
  }
  
  // check that protocol really is enabled
  XMCallProtocol callProtocol = [[callAddress addressResource] callProtocol];
  XMLocation *activeLocation = [[XMPreferencesManager sharedInstance] activeLocation];
  if (callProtocol == XMCallProtocol_H323 && ![activeLocation enableH323]) {
    [[NSApp delegate] noteCannotCallAddress:[[callAddress addressResource] address] reason:XMCallStartFailReason_H323NotEnabled];
    return;
  } else if (callProtocol == XMCallProtocol_SIP && ![activeLocation enableSIP]) {
    [[NSApp delegate] noteCannotCallAddress:[[callAddress addressResource] address] reason:XMCallStartFailReason_SIPNotEnabled];
    return;
  }
  
  activeCallAddress = [callAddress retain];
  
  [[XMCallManager sharedInstance] makeCall:[callAddress addressResource]];
}

#pragma mark Private Methods

- (void)_callEnded:(NSNotification *)notif
{
  if (activeCallAddress != nil) {
    [activeCallAddress release];
    activeCallAddress = nil;
  }
}

- (void)_frameworkDidInitialize:(NSNotification *)notif
{
  if (addressToCallWhenInitialized != nil) {
    id<XMCallAddress> addr = addressToCallWhenInitialized;
    // set addressToCall... to nil -> addr inherits retain count
    addressToCallWhenInitialized = nil;
    [self makeCallToAddress:addr];
    [addr release];
  }
}

@end
