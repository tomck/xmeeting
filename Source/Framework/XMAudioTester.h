/*
 * Copyright (c) 2006-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2006-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#ifndef __XM_AUDIO_TESTER_H__
#define __XM_AUDIO_TESTER_H__

#include <ptlib.h>
#include "XMSoundChannel.h"
#include "XMCircularBuffer.h"

class XMAudioTester : public PThread
{
	PCLASSINFO(XMAudioTester, PThread);
	
public:
	XMAudioTester(unsigned delay);
  virtual ~XMAudioTester();
	virtual void Main();
	
	static void Start(unsigned delay);
	static void Stop();
	
private:
	unsigned delay;
	XMCircularBuffer circularBuffer;
	bool stop;
};

#endif // __XM_AUDIO_TESTER_H__

