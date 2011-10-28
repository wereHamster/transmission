/******************************************************************************
 * $Id$
 *
 * Copyright (c) 2010-2011 Transmission authors and contributors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 *****************************************************************************/

#import <Cocoa/Cocoa.h>
#import "InfoViewController.h"

@interface InfoOptionsViewController : NSViewController <InfoViewController>
{
    NSArray * fTorrents;

    BOOL fSet;

    IBOutlet NSPopUpButton * fPriorityPopUp, * fRatioPopUp, * fIdlePopUp;
    IBOutlet NSButton * fUploadLimitCheck, * fDownloadLimitCheck, * fGlobalLimitCheck;
    IBOutlet NSTextField * fUploadLimitField, * fDownloadLimitField, * fRatioLimitField, * fIdleLimitField,
                        * fUploadLimitLabel, * fDownloadLimitLabel, * fIdleLimitLabel,
                        * fRatioLimitGlobalLabel, * fIdleLimitGlobalLabel,
                        * fPeersConnectLabel, * fPeersConnectField;

    NSString * fInitialString;
}

- (void) setInfoForTorrents: (NSArray *) torrents;
- (void) updateInfo;
- (void) updateOptions;

- (void) setUseSpeedLimit: (id) sender;
- (void) setSpeedLimit: (id) sender;
- (void) setUseGlobalSpeedLimit: (id) sender;

- (void) setRatioSetting: (id) sender;
- (void) setRatioLimit: (id) sender;

- (void) setIdleSetting: (id) sender;
- (void) setIdleLimit: (id) sender;

- (void) setPriority: (id) sender;

- (void) setPeersConnectLimit: (id) sender;

@end
