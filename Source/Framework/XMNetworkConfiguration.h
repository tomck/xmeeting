/*
 * Copyright (c) 2007-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2007-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_NETWORK_CONFIGURATION_H__
#define __XM_NETWORK_CONFIGURATION_H__

#define XM_NOT_REACHABLE 0
#define XM_REACHABLE 1
#define XM_DIRECT_REACHABLE 2

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>

#include <ptclib/psockbun.h>

class XMInterfaceFilter : public PInterfaceFilter
{
  PCLASSINFO(XMInterfaceFilter, PInterfaceFilter);
public:
  PIPSocket::InterfaceTable FilterInterfaces(const PIPSocket::Address & destination,
                                             PIPSocket::InterfaceTable & interfaces) const;
};

#endif // __XM_NETWORK_CONFIGURATION_H__

