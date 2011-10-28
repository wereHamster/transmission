/******************************************************************************
 * $Id$
 *
 * Copyright (c) 2008-2011 Transmission authors and contributors
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

@class Controller;
@class FileOutlineController;
@class Torrent;

@interface AddWindowController : NSWindowController
{
    IBOutlet NSImageView * fIconView, * fLocationImageView;
    IBOutlet NSTextField * fNameField, * fStatusField, * fLocationField;
    IBOutlet NSButton * fStartCheck, * fDeleteCheck;
    IBOutlet NSPopUpButton * fGroupPopUp, * fPriorityPopUp;
    IBOutlet NSProgressIndicator * fVerifyIndicator;

    IBOutlet FileOutlineController * fFileController;

    Controller * fController;

    Torrent * fTorrent;
    NSString * fDestination, * fTorrentFile;
    BOOL fLockDestination;

    BOOL fDeleteTorrentInitial, fDeleteEnableInitial;
    NSInteger fGroupValue;

    NSTimer * fTimer;
}

- (id) initWithTorrent: (Torrent *) torrent destination: (NSString *) path lockDestination: (BOOL) lockDestination
    controller: (Controller *) controller torrentFile: (NSString *) torrentFile
    deleteTorrent: (BOOL) deleteTorrent canToggleDelete: (BOOL) canToggleDelete;

- (Torrent *) torrent;

- (void) setDestination: (id) sender;

- (void) add: (id) sender;
- (void) cancelAdd: (id) sender;

- (void) verifyLocalData: (id) sender;

- (void) changePriority: (id) sender;

- (void) updateStatusField: (NSNotification *) notification;

- (void) updateGroupMenu: (NSNotification *) notification;

@end
