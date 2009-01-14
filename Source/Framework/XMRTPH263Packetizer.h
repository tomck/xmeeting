/*
 * Copyright (c) 2006-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2006-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_RTP_H263_PACKETIZER_H__
#define __XM_RTP_H263_PACKETIZER_H__

#include <QuickTime/QuickTime.h>

#define kXMRTPH263PacketizerComponentType kRTPMediaPacketizerType
#define kXMRTPH263PacketizerComponentSubType 'h263'
#define kXMRTPH263PacketizerComponentManufacturer 'XMet'

#define kXMRTPH263PacketizerType 'h263'

/**
 * Registering the XMRTPH263Packetizer QuickTime Component
 * so that it can be used when needed.
 **/
Boolean XMRegisterRTPH263Packetizer();

#endif // __XM_RTP_H263_PACKETIZER_H__