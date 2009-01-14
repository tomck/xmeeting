/*
 * Copyright (c) 2006-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2006-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#include "XMRTPPacket.h"

XMRTPPacket::XMRTPPacket(PINDEX payloadSize)
: RTP_DataFrame(payloadSize)
{
}