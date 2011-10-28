/******************************************************************************
 * $Id$
 *
 * Copyright (c) 2007-2011 Transmission authors and contributors
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
#import "transmission.h"
#import "makemeta.h"

@interface CreatorWindowController : NSWindowController
{
    IBOutlet NSImageView * fIconView;
    IBOutlet NSTextField * fNameField, * fStatusField, * fPiecesField, * fLocationField;
    IBOutlet NSTableView * fTrackerTable;
    IBOutlet NSSegmentedControl * fTrackerAddRemoveControl;
    IBOutlet NSTextView * fCommentView;
    IBOutlet NSButton * fPrivateCheck, * fOpenCheck;

    IBOutlet NSView * fProgressView;
    IBOutlet NSProgressIndicator * fProgressIndicator;

    tr_metainfo_builder * fInfo;
    NSString * fPath, * fLocation;
    NSMutableArray * fTrackers;

    NSTimer * fTimer;
    BOOL fStarted;

    NSUserDefaults * fDefaults;
}

+ (void) createTorrentFile: (tr_session *) handle;
+ (void) createTorrentFile: (tr_session *) handle forFile: (NSString *) file;

- (id) initWithHandle: (tr_session *) handle path: (NSString *) path;

- (void) setLocation: (id) sender;
- (void) create: (id) sender;
- (void) cancelCreateWindow: (id) sender;
- (void) cancelCreateProgress: (id) sender;

- (void) addRemoveTracker: (id) sender;

- (void) copy: (id) sender;
- (void) paste: (id) sender;

@end
