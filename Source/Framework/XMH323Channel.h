/*
 * Copyright (c) 2006-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2006-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_H323_CHANNEL_H__
#define __XM_H323_CHANNEL_H__

#include <ptlib.h>
#include <h323/channels.h>

class XMH323Channel : public H323_RTPChannel
{
  PCLASSINFO(XMH323Channel, H323_RTPChannel);
	
  XMH323Channel(H323Connection & connection,
                const H323Capability & capability,
                Directions direction,
                RTP_Session & rtp);
	
  virtual void OnFlowControl(long bitRateRestriction);
};

#endif // __XM_H323_CHANNEL_H__

