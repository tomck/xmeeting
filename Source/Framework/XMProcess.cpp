/*
 * Copyright (c) 2005-2009 XMeeting Project ("http://xmeeting.sf.net").
 * All rights reserved.
 * Copyright (c) 2005-2009 Hannes Friederich. All rights reserved.
 *
 * $Revision$
 * $Author$
 * $Date$
 */

#include "XMProcess.h"

// keep PTLib-linking happy
namespace PWLibStupidLinkerHacks {
  int loadFakeVideoStuff;
  int loadCoreAudioStuff;
}

XMProcess::XMProcess() 
: PProcess("XMeeting Project", "XMeeting", 0, 4, BetaCode, 0) 
{
}

XMProcess::~XMProcess()
{
}

void XMProcess::Main() {}