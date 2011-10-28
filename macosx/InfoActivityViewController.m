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

#import "InfoActivityViewController.h"
#import "NSStringAdditions.h"
#import "PiecesView.h"
#import "Torrent.h"

#include "transmission.h" // required by utils.h
#include "utils.h" //tr_getRatio()

#define PIECES_CONTROL_PROGRESS 0
#define PIECES_CONTROL_AVAILABLE 1

@interface InfoActivityViewController (Private)

- (void) setupInfo;

- (void) updatePiecesView;

@end

@implementation InfoActivityViewController

- (id) init
{
    if ((self = [super initWithNibName: @"InfoActivityView" bundle: nil]))
    {
        [self setTitle: NSLocalizedString(@"Activity", "Inspector view -> title")];
    }

    return self;
}

- (void) awakeFromNib
{
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(updatePiecesView) name: @"UpdatePiecesView" object: nil];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver: self];

    [fTorrents release];

    [super dealloc];
}

- (void) setInfoForTorrents: (NSArray *) torrents
{
    //don't check if it's the same in case the metadata changed
    [fTorrents release];
    fTorrents = [torrents retain];

    fSet = NO;
}

- (void) updateInfo
{
    if (!fSet)
        [self setupInfo];

    const NSInteger numberSelected = [fTorrents count];
    if (numberSelected == 0)
        return;

    uint64_t have = 0, haveVerified = 0, downloadedTotal = 0, uploadedTotal = 0, failedHash = 0;
    NSDate * lastActivity = nil;
    for (Torrent * torrent in fTorrents)
    {
        have += [torrent haveTotal];
        haveVerified += [torrent haveVerified];
        downloadedTotal += [torrent downloadedTotal];
        uploadedTotal += [torrent uploadedTotal];
        failedHash += [torrent failedHash];

        NSDate * nextLastActivity;
        if ((nextLastActivity = [torrent dateActivity]))
            lastActivity = lastActivity ? [lastActivity laterDate: nextLastActivity] : nextLastActivity;
    }

    if (have == 0)
        [fHaveField setStringValue: [NSString stringForFileSize: 0]];
    else
    {
        NSString * verifiedString = [NSString stringWithFormat: NSLocalizedString(@"%@ verified", "Inspector -> Activity tab -> have"),
                                        [NSString stringForFileSize: haveVerified]];
        if (have == haveVerified)
            [fHaveField setStringValue: verifiedString];
        else
            [fHaveField setStringValue: [NSString stringWithFormat: @"%@ (%@)", [NSString stringForFileSize: have], verifiedString]];
    }

    [fDownloadedTotalField setStringValue: [NSString stringForFileSize: downloadedTotal]];
    [fUploadedTotalField setStringValue: [NSString stringForFileSize: uploadedTotal]];
    [fFailedHashField setStringValue: [NSString stringForFileSize: failedHash]];

    [fDateActivityField setObjectValue: lastActivity];

    if (numberSelected == 1)
    {
        Torrent * torrent = [fTorrents objectAtIndex: 0];

        [fStateField setStringValue: [torrent stateString]];

        NSString * progressString = [NSString percentString: [torrent progress] longDecimals: YES];
        if ([torrent isFolder])
        {
            NSString * progressSelectedString = [NSString stringWithFormat:
                                                    NSLocalizedString(@"%@ selected", "Inspector -> Activity tab -> progress"),
                                                    [NSString percentString: [torrent progressDone] longDecimals: YES]];
            progressString = [progressString stringByAppendingFormat: @" (%@)", progressSelectedString];
        }
        [fProgressField setStringValue: progressString];

        [fRatioField setStringValue: [NSString stringForRatio: [torrent ratio]]];

        NSString * errorMessage = [torrent errorMessage];
        if (![errorMessage isEqualToString: [fErrorMessageView string]])
            [fErrorMessageView setString: errorMessage];

        [fDateCompletedField setObjectValue: [torrent dateCompleted]];

        [fDownloadTimeField setStringValue: [NSString timeString: [torrent secondsDownloading] showSeconds: YES]];
        [fSeedTimeField setStringValue: [NSString timeString: [torrent secondsSeeding] showSeconds: YES]];

        [fPiecesView updateView];
    }
    else if (numberSelected > 1)
    {
        [fRatioField setStringValue: [NSString stringForRatio: tr_getRatio(uploadedTotal, downloadedTotal)]];
    }
    else;
}

- (void) setPiecesView: (id) sender
{
    const BOOL availability = [sender selectedSegment] == PIECES_CONTROL_AVAILABLE;
    [[NSUserDefaults standardUserDefaults] setBool: availability forKey: @"PiecesViewShowAvailability"];
    [self updatePiecesView];
}

- (void) clearView
{
    [fPiecesView clearView];
}

@end

@implementation InfoActivityViewController (Private)

- (void) setupInfo
{
    const NSUInteger count = [fTorrents count];
    if (count != 1)
    {
        if (count == 0)
        {
            [fHaveField setStringValue: @""];
            [fDownloadedTotalField setStringValue: @""];
            [fUploadedTotalField setStringValue: @""];
            [fFailedHashField setStringValue: @""];
            [fDateActivityField setStringValue: @""];
            [fRatioField setStringValue: @""];
        }

        [fStateField setStringValue: @""];
        [fProgressField setStringValue: @""];

        [fErrorMessageView setString: @""];

        [fDateAddedField setStringValue: @""];
        [fDateCompletedField setStringValue: @""];

        [fDownloadTimeField setStringValue: @""];
        [fSeedTimeField setStringValue: @""];

        [fPiecesControl setSelected: NO forSegment: PIECES_CONTROL_AVAILABLE];
        [fPiecesControl setSelected: NO forSegment: PIECES_CONTROL_PROGRESS];
        [fPiecesControl setEnabled: NO];
        [fPiecesView setTorrent: nil];
    }
    else
    {
        Torrent * torrent = [fTorrents objectAtIndex: 0];

        [fDateAddedField setObjectValue: [torrent dateAdded]];

        const BOOL piecesAvailableSegment = [[NSUserDefaults standardUserDefaults] boolForKey: @"PiecesViewShowAvailability"];
        [fPiecesControl setSelected: piecesAvailableSegment forSegment: PIECES_CONTROL_AVAILABLE];
        [fPiecesControl setSelected: !piecesAvailableSegment forSegment: PIECES_CONTROL_PROGRESS];
        [fPiecesControl setEnabled: YES];

        [fPiecesView setTorrent: torrent];
    }

    fSet = YES;
}

- (void) updatePiecesView
{
    const BOOL piecesAvailableSegment = [[NSUserDefaults standardUserDefaults] boolForKey: @"PiecesViewShowAvailability"];

    [fPiecesControl setSelected: piecesAvailableSegment forSegment: PIECES_CONTROL_AVAILABLE];
    [fPiecesControl setSelected: !piecesAvailableSegment forSegment: PIECES_CONTROL_PROGRESS];

    [fPiecesView updateView];
}

@end
