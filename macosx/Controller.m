/******************************************************************************
 * $Id$
 *
 * Copyright (c) 2005-2011 Transmission authors and contributors
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

#import <IOKit/IOMessage.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>

#import "Controller.h"
#import "Torrent.h"
#import "TorrentGroup.h"
#import "TorrentTableView.h"
#import "CreatorWindowController.h"
#import "StatsWindowController.h"
#import "InfoWindowController.h"
#import "PrefsController.h"
#import "GroupsController.h"
#import "AboutWindowController.h"
#import "URLSheetWindowController.h"
#import "AddWindowController.h"
#import "AddMagnetWindowController.h"
#import "MessageWindowController.h"
#import "ButtonToolbarItem.h"
#import "GroupToolbarItem.h"
#import "ToolbarSegmentedCell.h"
#import "BlocklistDownloader.h"
#import "StatusBarController.h"
#import "FilterBarController.h"
#import "BonjourController.h"
#import "Badger.h"
#import "DragOverlayWindow.h"
#import "NSApplicationAdditions.h"
#import "NSStringAdditions.h"
#import "ExpandedPathToPathTransformer.h"
#import "ExpandedPathToIconTransformer.h"

#import "transmission.h"
#import "bencode.h"
#import "utils.h"

#import "UKKQueue.h"
#import <Sparkle/Sparkle.h>

#define TOOLBAR_CREATE                  @"Toolbar Create"
#define TOOLBAR_OPEN_FILE               @"Toolbar Open"
#define TOOLBAR_OPEN_WEB                @"Toolbar Open Web"
#define TOOLBAR_REMOVE                  @"Toolbar Remove"
#define TOOLBAR_INFO                    @"Toolbar Info"
#define TOOLBAR_PAUSE_ALL               @"Toolbar Pause All"
#define TOOLBAR_RESUME_ALL              @"Toolbar Resume All"
#define TOOLBAR_PAUSE_RESUME_ALL        @"Toolbar Pause / Resume All"
#define TOOLBAR_PAUSE_SELECTED          @"Toolbar Pause Selected"
#define TOOLBAR_RESUME_SELECTED         @"Toolbar Resume Selected"
#define TOOLBAR_PAUSE_RESUME_SELECTED   @"Toolbar Pause / Resume Selected"
#define TOOLBAR_FILTER                  @"Toolbar Toggle Filter"
#define TOOLBAR_QUICKLOOK               @"Toolbar QuickLook"

typedef enum
{
    TOOLBAR_PAUSE_TAG = 0,
    TOOLBAR_RESUME_TAG = 1
} toolbarGroupTag;

#define SORT_DATE       @"Date"
#define SORT_NAME       @"Name"
#define SORT_STATE      @"State"
#define SORT_PROGRESS   @"Progress"
#define SORT_TRACKER    @"Tracker"
#define SORT_ORDER      @"Order"
#define SORT_ACTIVITY   @"Activity"
#define SORT_SIZE       @"Size"

typedef enum
{
    SORT_ORDER_TAG = 0,
    SORT_DATE_TAG = 1,
    SORT_NAME_TAG = 2,
    SORT_PROGRESS_TAG = 3,
    SORT_STATE_TAG = 4,
    SORT_TRACKER_TAG = 5,
    SORT_ACTIVITY_TAG = 6,
    SORT_SIZE_TAG = 7
} sortTag;

typedef enum
{
    SORT_ASC_TAG = 0,
    SORT_DESC_TAG = 1
} sortOrderTag;

#define GROWL_DOWNLOAD_COMPLETE @"Download Complete"
#define GROWL_SEEDING_COMPLETE  @"Seeding Complete"
#define GROWL_AUTO_ADD          @"Torrent Auto Added"
#define GROWL_AUTO_SPEED_LIMIT  @"Speed Limit Auto Changed"

#define TORRENT_TABLE_VIEW_DATA_TYPE    @"TorrentTableViewDataType"

#define ROW_HEIGHT_REGULAR      62.0
#define ROW_HEIGHT_SMALL        22.0
#define WINDOW_REGULAR_WIDTH    468.0

#define STATUS_BAR_HEIGHT   21.0
#define FILTER_BAR_HEIGHT   23.0

#define UPDATE_UI_SECONDS   1.0

#define DOCK_SEEDING_TAG        101
#define DOCK_DOWNLOADING_TAG    102

#define TRANSFER_PLIST  @"/Library/Application Support/Transmission/Transfers.plist"

#define WEBSITE_URL @"http://www.transmissionbt.com/"
#define FORUM_URL   @"http://forum.transmissionbt.com/"
#define TRAC_URL    @"http://trac.transmissionbt.com/"
#define DONATE_URL  @"http://www.transmissionbt.com/donate.php"

#define DONATE_NAG_TIME (60 * 60 * 24 * 7)

static void altSpeedToggledCallback(tr_session * handle UNUSED, bool active, bool byUser, void * controller)
{
    NSDictionary * dict = [[NSDictionary alloc] initWithObjectsAndKeys: [[NSNumber alloc] initWithBool: active], @"Active",
                                [[NSNumber alloc] initWithBool: byUser], @"ByUser", nil];
    [(Controller *)controller performSelectorOnMainThread: @selector(altSpeedToggledCallbackIsLimited:)
        withObject: dict waitUntilDone: NO];
}

static tr_rpc_callback_status rpcCallback(tr_session * handle UNUSED, tr_rpc_callback_type type, struct tr_torrent * torrentStruct,
                                            void * controller)
{
    [(Controller *)controller rpcCallback: type forTorrentStruct: torrentStruct];
    return TR_RPC_NOREMOVE; //we'll do the remove manually
}

static void sleepCallback(void * controller, io_service_t y, natural_t messageType, void * messageArgument)
{
    [(Controller *)controller sleepCallback: messageType argument: messageArgument];
}

@implementation Controller

+ (void) initialize
{
    //make sure another Transmission.app isn't running already
    BOOL othersRunning = NO;

    if ([NSApp isOnSnowLeopardOrBetter])
    {
        NSArray * apps = [NSRunningApplicationSL runningApplicationsWithBundleIdentifier: [[NSBundle mainBundle] bundleIdentifier]];
        othersRunning = [apps count] > 1;
    }
    else
    {
        NSString * bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
        const int processIdentifier = [[NSProcessInfo processInfo] processIdentifier];

        for (NSDictionary * dic in [[NSWorkspace sharedWorkspace] launchedApplications])
        {
            if ([[dic objectForKey: @"NSApplicationBundleIdentifier"] isEqualToString: bundleIdentifier]
                    && [[dic objectForKey: @"NSApplicationProcessIdentifier"] intValue] != processIdentifier)
                othersRunning = YES;
        }
    }

    if (othersRunning)
    {
        NSAlert * alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle: NSLocalizedString(@"Quit", "Transmission already running alert -> button")];
        [alert setMessageText: NSLocalizedString(@"Transmission is already running.",
                                                "Transmission already running alert -> title")];
        [alert setInformativeText: NSLocalizedString(@"There is already a copy of Transmission running. "
            "This copy cannot be opened until that instance is quit.", "Transmission already running alert -> message")];
        [alert setAlertStyle: NSCriticalAlertStyle];

        [alert runModal];
        [alert release];

        //kill ourselves right away
        exit(0);
    }

    [[NSUserDefaults standardUserDefaults] registerDefaults: [NSDictionary dictionaryWithContentsOfFile:
        [[NSBundle mainBundle] pathForResource: @"Defaults" ofType: @"plist"]]];

    //set custom value transformers
    ExpandedPathToPathTransformer * pathTransformer = [[[ExpandedPathToPathTransformer alloc] init] autorelease];
    [NSValueTransformer setValueTransformer: pathTransformer forName: @"ExpandedPathToPathTransformer"];

    ExpandedPathToIconTransformer * iconTransformer = [[[ExpandedPathToIconTransformer alloc] init] autorelease];
    [NSValueTransformer setValueTransformer: iconTransformer forName: @"ExpandedPathToIconTransformer"];

    //cover our asses
    if ([[NSUserDefaults standardUserDefaults] boolForKey: @"WarningLegal"])
    {
        NSAlert * alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle: NSLocalizedString(@"I Accept", "Legal alert -> button")];
        [alert addButtonWithTitle: NSLocalizedString(@"Quit", "Legal alert -> button")];
        [alert setMessageText: NSLocalizedString(@"Welcome to Transmission", "Legal alert -> title")];
        [alert setInformativeText: NSLocalizedString(@"Transmission is a file-sharing program."
            " When you run a torrent, its data will be made available to others by means of upload."
            " You and you alone are fully responsible for exercising proper judgement and abiding by your local laws.",
            "Legal alert -> message")];
        [alert setAlertStyle: NSInformationalAlertStyle];

        if ([alert runModal] == NSAlertSecondButtonReturn)
            exit(0);
        [alert release];

        [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"WarningLegal"];
    }
}

- (id) init
{
    if ((self = [super init]))
    {
        fDefaults = [NSUserDefaults standardUserDefaults];

        //checks for old version speeds of -1
        if ([fDefaults integerForKey: @"UploadLimit"] < 0)
        {
            [fDefaults removeObjectForKey: @"UploadLimit"];
            [fDefaults setBool: NO forKey: @"CheckUpload"];
        }
        if ([fDefaults integerForKey: @"DownloadLimit"] < 0)
        {
            [fDefaults removeObjectForKey: @"DownloadLimit"];
            [fDefaults setBool: NO forKey: @"CheckDownload"];
        }

        tr_benc settings;
        tr_bencInitDict(&settings, 41);
        tr_sessionGetDefaultSettings(&settings);

        const BOOL usesSpeedLimitSched = [fDefaults boolForKey: @"SpeedLimitAuto"];
        if (!usesSpeedLimitSched)
            tr_bencDictAddBool(&settings, TR_PREFS_KEY_ALT_SPEED_ENABLED, [fDefaults boolForKey: @"SpeedLimit"]);

        tr_bencDictAddInt(&settings, TR_PREFS_KEY_ALT_SPEED_UP_KBps, [fDefaults integerForKey: @"SpeedLimitUploadLimit"]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_ALT_SPEED_DOWN_KBps, [fDefaults integerForKey: @"SpeedLimitDownloadLimit"]);

        tr_bencDictAddBool(&settings, TR_PREFS_KEY_ALT_SPEED_TIME_ENABLED, [fDefaults boolForKey: @"SpeedLimitAuto"]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_ALT_SPEED_TIME_BEGIN, [PrefsController dateToTimeSum:
                                                                            [fDefaults objectForKey: @"SpeedLimitAutoOnDate"]]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_ALT_SPEED_TIME_END, [PrefsController dateToTimeSum:
                                                                            [fDefaults objectForKey: @"SpeedLimitAutoOffDate"]]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_ALT_SPEED_TIME_DAY, [fDefaults integerForKey: @"SpeedLimitAutoDay"]);

        tr_bencDictAddInt(&settings, TR_PREFS_KEY_DSPEED_KBps, [fDefaults integerForKey: @"DownloadLimit"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_DSPEED_ENABLED, [fDefaults boolForKey: @"CheckDownload"]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_USPEED_KBps, [fDefaults integerForKey: @"UploadLimit"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_USPEED_ENABLED, [fDefaults boolForKey: @"CheckUpload"]);

        //hidden prefs
        if ([fDefaults objectForKey: @"BindAddressIPv4"])
            tr_bencDictAddStr(&settings, TR_PREFS_KEY_BIND_ADDRESS_IPV4, [[fDefaults stringForKey: @"BindAddressIPv4"] UTF8String]);
        if ([fDefaults objectForKey: @"BindAddressIPv6"])
            tr_bencDictAddStr(&settings, TR_PREFS_KEY_BIND_ADDRESS_IPV6, [[fDefaults stringForKey: @"BindAddressIPv6"] UTF8String]);

        tr_bencDictAddBool(&settings, TR_PREFS_KEY_BLOCKLIST_ENABLED, [fDefaults boolForKey: @"BlocklistNew"]);
        if ([fDefaults objectForKey: @"BlocklistURL"])
            tr_bencDictAddStr(&settings, TR_PREFS_KEY_BLOCKLIST_URL, [[fDefaults stringForKey: @"BlocklistURL"] UTF8String]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_DHT_ENABLED, [fDefaults boolForKey: @"DHTGlobal"]);
        tr_bencDictAddStr(&settings, TR_PREFS_KEY_DOWNLOAD_DIR, [[[fDefaults stringForKey: @"DownloadFolder"]
                                                                    stringByExpandingTildeInPath] UTF8String]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_IDLE_LIMIT, [fDefaults integerForKey: @"IdleLimitMinutes"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_IDLE_LIMIT_ENABLED, [fDefaults boolForKey: @"IdleLimitCheck"]);
        tr_bencDictAddStr(&settings, TR_PREFS_KEY_INCOMPLETE_DIR, [[[fDefaults stringForKey: @"IncompleteDownloadFolder"]
                                                                    stringByExpandingTildeInPath] UTF8String]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_INCOMPLETE_DIR_ENABLED, [fDefaults boolForKey: @"UseIncompleteDownloadFolder"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_LPD_ENABLED, [fDefaults boolForKey: @"LocalPeerDiscoveryGlobal"]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_MSGLEVEL, TR_MSG_DBG);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_PEER_LIMIT_GLOBAL, [fDefaults integerForKey: @"PeersTotal"]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_PEER_LIMIT_TORRENT, [fDefaults integerForKey: @"PeersTorrent"]);

        const BOOL randomPort = [fDefaults boolForKey: @"RandomPort"];
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_PEER_PORT_RANDOM_ON_START, randomPort);
        if (!randomPort)
            tr_bencDictAddInt(&settings, TR_PREFS_KEY_PEER_PORT, [fDefaults integerForKey: @"BindPort"]);

        //hidden pref
        if ([fDefaults objectForKey: @"PeerSocketTOS"])
            tr_bencDictAddStr(&settings, TR_PREFS_KEY_PEER_SOCKET_TOS, [[fDefaults stringForKey: @"PeerSocketTOS"] UTF8String]);

        tr_bencDictAddBool(&settings, TR_PREFS_KEY_PEX_ENABLED, [fDefaults boolForKey: @"PEXGlobal"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_PORT_FORWARDING, [fDefaults boolForKey: @"NatTraversal"]);
        tr_bencDictAddReal(&settings, TR_PREFS_KEY_RATIO, [fDefaults floatForKey: @"RatioLimit"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_RATIO_ENABLED, [fDefaults boolForKey: @"RatioCheck"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_RENAME_PARTIAL_FILES, [fDefaults boolForKey: @"RenamePartialFiles"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_RPC_AUTH_REQUIRED,  [fDefaults boolForKey: @"RPCAuthorize"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_RPC_ENABLED,  [fDefaults boolForKey: @"RPC"]);
        tr_bencDictAddInt(&settings, TR_PREFS_KEY_RPC_PORT, [fDefaults integerForKey: @"RPCPort"]);
        tr_bencDictAddStr(&settings, TR_PREFS_KEY_RPC_USERNAME,  [[fDefaults stringForKey: @"RPCUsername"] UTF8String]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_RPC_WHITELIST_ENABLED,  [fDefaults boolForKey: @"RPCUseWhitelist"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_START, [fDefaults boolForKey: @"AutoStartDownload"]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_SCRIPT_TORRENT_DONE_ENABLED, [fDefaults boolForKey: @"DoneScriptEnabled"]);
        tr_bencDictAddStr(&settings, TR_PREFS_KEY_SCRIPT_TORRENT_DONE_FILENAME, [[fDefaults stringForKey: @"DoneScriptPath"] UTF8String]);
        tr_bencDictAddBool(&settings, TR_PREFS_KEY_UTP_ENABLED, [fDefaults boolForKey: @"UTPGlobal"]);

        tr_formatter_size_init([NSApp isOnSnowLeopardOrBetter] ? 1000 : 1024,
                                    [NSLocalizedString(@"KB", "File size - kilobytes") UTF8String],
                                    [NSLocalizedString(@"MB", "File size - megabytes") UTF8String],
                                    [NSLocalizedString(@"GB", "File size - gigabytes") UTF8String],
                                    [NSLocalizedString(@"TB", "File size - terabytes") UTF8String]);

        tr_formatter_speed_init([NSApp isOnSnowLeopardOrBetter] ? 1000 : 1024,
                                    [NSLocalizedString(@"KB/s", "Transfer speed (kilobytes per second)") UTF8String],
                                    [NSLocalizedString(@"MB/s", "Transfer speed (megabytes per second)") UTF8String],
                                    [NSLocalizedString(@"GB/s", "Transfer speed (gigabytes per second)") UTF8String],
                                    [NSLocalizedString(@"TB/s", "Transfer speed (terabytes per second)") UTF8String]); //why not?

        tr_formatter_mem_init(1024, [NSLocalizedString(@"KB", "Memory size - kilobytes") UTF8String],
                                    [NSLocalizedString(@"MB", "Memory size - megabytes") UTF8String],
                                    [NSLocalizedString(@"GB", "Memory size - gigabytes") UTF8String],
                                    [NSLocalizedString(@"TB", "Memory size - terabytes") UTF8String]);

        const char * configDir = tr_getDefaultConfigDir("Transmission");
        fLib = tr_sessionInit("macosx", configDir, YES, &settings);
        tr_bencFree(&settings);

        [NSApp setDelegate: self];

        //register for magnet URLs (has to be in init)
        [[NSAppleEventManager sharedAppleEventManager] setEventHandler: self andSelector: @selector(handleOpenContentsEvent:replyEvent:)
            forEventClass: kInternetEventClass andEventID: kAEGetURL];

        fTorrents = [[NSMutableArray alloc] init];
        fDisplayedTorrents = [[NSMutableArray alloc] init];

        fInfoController = [[InfoWindowController alloc] init];

        [PrefsController setHandle: fLib];
        fPrefsController = [[PrefsController alloc] init];

        fQuitting = NO;
        fSoundPlaying = NO;

        tr_sessionSetAltSpeedFunc(fLib, altSpeedToggledCallback, self);
        if (usesSpeedLimitSched)
            [fDefaults setBool: tr_sessionUsesAltSpeed(fLib) forKey: @"SpeedLimit"];

        tr_sessionSetRPCCallback(fLib, rpcCallback, self);

        [GrowlApplicationBridge setGrowlDelegate: self];

        [[UKKQueue sharedFileWatcher] setDelegate: self];

        [[SUUpdater sharedUpdater] setDelegate: self];
        fQuitRequested = NO;

        fPauseOnLaunch = (GetCurrentKeyModifiers() & (optionKey | rightOptionKey)) != 0;
    }
    return self;
}

- (void) awakeFromNib
{
    NSToolbar * toolbar = [[NSToolbar alloc] initWithIdentifier: @"TRMainToolbar"];
    [toolbar setDelegate: self];
    [toolbar setAllowsUserCustomization: YES];
    [toolbar setAutosavesConfiguration: YES];
    [toolbar setDisplayMode: NSToolbarDisplayModeIconOnly];
    [fWindow setToolbar: toolbar];
    [toolbar release];

    [fWindow setDelegate: self]; //do manually to avoid placement issue

    [fWindow makeFirstResponder: fTableView];
    [fWindow setExcludedFromWindowsMenu: YES];

    //set table size
    const BOOL small = [fDefaults boolForKey: @"SmallView"];
    if (small)
        [fTableView setRowHeight: ROW_HEIGHT_SMALL];
    [fTableView setUsesAlternatingRowBackgroundColors: !small];

    [fWindow setContentBorderThickness: NSMinY([[fTableView enclosingScrollView] frame]) forEdge: NSMinYEdge];
    [fWindow setMovableByWindowBackground: YES];

    [[fTotalTorrentsField cell] setBackgroundStyle: NSBackgroundStyleRaised];

    //set up filter bar
    [self showFilterBar: [fDefaults boolForKey: @"FilterBar"] animate: NO];

    //set up status bar
    [self showStatusBar: [fDefaults boolForKey: @"StatusBar"] animate: NO];

    [fActionButton setToolTip: NSLocalizedString(@"Shortcuts for changing global settings.",
                                "Main window -> 1st bottom left button (action) tooltip")];
    [fSpeedLimitButton setToolTip: NSLocalizedString(@"Speed Limit overrides the total bandwidth limits with its own limits.",
                                "Main window -> 2nd bottom left button (turtle) tooltip")];
    [fClearCompletedButton setToolTip: NSLocalizedString(@"Remove all transfers that have completed seeding.",
                                "Main window -> 3rd bottom left button (remove all) tooltip")];

    [fTableView registerForDraggedTypes: [NSArray arrayWithObject: TORRENT_TABLE_VIEW_DATA_TYPE]];
    [fWindow registerForDraggedTypes: [NSArray arrayWithObjects: NSFilenamesPboardType, NSURLPboardType, nil]];

    //you would think this would be called later in this method from updateUI, but it's not reached in awakeFromNib
    //this must be called after showStatusBar:
    [fStatusBar updateWithDownload: 0.0 upload: 0.0];

    //this should also be after the rest of the setup
    [self updateForAutoSize];

    //register for sleep notifications
    IONotificationPortRef notify;
    io_object_t iterator;
    if ((fRootPort = IORegisterForSystemPower(self, & notify, sleepCallback, &iterator)))
        CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(notify), kCFRunLoopCommonModes);
    else
        NSLog(@"Could not IORegisterForSystemPower");

    //load previous transfers
    NSArray * history = [NSArray arrayWithContentsOfFile: [NSHomeDirectory() stringByAppendingPathComponent: TRANSFER_PLIST]];

    if (!history)
    {
        //old version saved transfer info in prefs file
        if ((history = [fDefaults arrayForKey: @"History"]))
            [fDefaults removeObjectForKey: @"History"];
    }

    if (history)
    {
        for (NSDictionary * historyItem in history)
        {
            Torrent * torrent;
            if ((torrent = [[Torrent alloc] initWithHistory: historyItem lib: fLib forcePause: fPauseOnLaunch]))
            {
                [fTorrents addObject: torrent];
                [torrent release];
            }
        }
    }

    fBadger = [[Badger alloc] initWithLib: fLib];

    //observe notifications
    NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];

    [nc addObserver: self selector: @selector(updateUI)
                    name: @"UpdateUI" object: nil];

    [nc addObserver: self selector: @selector(torrentFinishedDownloading:)
                    name: @"TorrentFinishedDownloading" object: nil];

    [nc addObserver: self selector: @selector(torrentRestartedDownloading:)
                    name: @"TorrentRestartedDownloading" object: nil];

    [nc addObserver: self selector: @selector(torrentFinishedSeeding:)
                    name: @"TorrentFinishedSeeding" object: nil];

    //avoids need of setting delegate
    [nc addObserver: self selector: @selector(torrentTableViewSelectionDidChange:)
                    name: NSOutlineViewSelectionDidChangeNotification object: fTableView];

    [nc addObserver: self selector: @selector(changeAutoImport)
                    name: @"AutoImportSettingChange" object: nil];

    [nc addObserver: self selector: @selector(updateForAutoSize)
                    name: @"AutoSizeSettingChange" object: nil];

    [nc addObserver: self selector: @selector(updateForExpandCollape)
                    name: @"OutlineExpandCollapse" object: nil];

    [nc addObserver: fWindow selector: @selector(makeKeyWindow)
                    name: @"MakeWindowKey" object: nil];

    [nc addObserver: self selector: @selector(updateTorrentsInQueue)
                    name: @"UpdateQueue" object: nil];

    [nc addObserver: self selector: @selector(applyFilter)
                    name: @"ApplyFilter" object: nil];

    //open newly created torrent file
    [nc addObserver: self selector: @selector(beginCreateFile:)
                    name: @"BeginCreateTorrentFile" object: nil];

    //open newly created torrent file
    [nc addObserver: self selector: @selector(openCreatedFile:)
                    name: @"OpenCreatedTorrentFile" object: nil];

    //timer to update the interface every second
    [self updateUI];
    fTimer = [NSTimer scheduledTimerWithTimeInterval: UPDATE_UI_SECONDS target: self
                selector: @selector(updateUI) userInfo: nil repeats: YES];
    [[NSRunLoop currentRunLoop] addTimer: fTimer forMode: NSModalPanelRunLoopMode];
    [[NSRunLoop currentRunLoop] addTimer: fTimer forMode: NSEventTrackingRunLoopMode];

    [self applyFilter];

    [fWindow makeKeyAndOrderFront: nil];

    if ([fDefaults boolForKey: @"InfoVisible"])
        [self showInfo: nil];
}

- (void) applicationDidFinishLaunching: (NSNotification *) notification
{
    [NSApp setServicesProvider: self];

    //register for dock icon drags (has to be in applicationDidFinishLaunching: to work)
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler: self andSelector: @selector(handleOpenContentsEvent:replyEvent:)
        forEventClass: kCoreEventClass andEventID: kAEOpenContents];

    //auto importing
    [self checkAutoImportDirectory];

    //registering the Web UI to Bonjour
    if ([fDefaults boolForKey: @"RPC"] && [fDefaults boolForKey: @"RPCWebDiscovery"])
        [[BonjourController defaultController] startWithPort: [fDefaults integerForKey: @"RPCPort"]];

    //shamelessly ask for donations
    if ([fDefaults boolForKey: @"WarningDonate"])
    {
        tr_session_stats stats;
        tr_sessionGetCumulativeStats(fLib, &stats);
        const BOOL firstLaunch = stats.sessionCount <= 1;

        NSDate * lastDonateDate = [fDefaults objectForKey: @"DonateAskDate"];
        const BOOL timePassed = !lastDonateDate || (-1 * [lastDonateDate timeIntervalSinceNow]) >= DONATE_NAG_TIME;

        if (!firstLaunch && timePassed)
        {
            [fDefaults setObject: [NSDate date] forKey: @"DonateAskDate"];

            NSAlert * alert = [[NSAlert alloc] init];
            [alert setMessageText: NSLocalizedString(@"Support open-source indie software", "Donation beg -> title")];

            NSString * donateMessage = [NSString stringWithFormat: @"%@\n\n%@",
                NSLocalizedString(@"Transmission is a full-featured torrent application."
                    " A lot of time and effort have gone into development, coding, and refinement."
                    " If you enjoy using it, please consider showing your love with a donation.", "Donation beg -> message"),
                NSLocalizedString(@"Donate or not, there will be no difference to your torrenting experience.", "Donation beg -> message")];

            [alert setInformativeText: donateMessage];
            [alert setAlertStyle: NSInformationalAlertStyle];

            [alert addButtonWithTitle: [NSLocalizedString(@"Donate", "Donation beg -> button") stringByAppendingEllipsis]];
            NSButton * noDonateButton = [alert addButtonWithTitle: NSLocalizedString(@"Nope", "Donation beg -> button")];
            [noDonateButton setKeyEquivalent: @"\e"]; //escape key

            const BOOL allowNeverAgain = lastDonateDate != nil; //hide the "don't show again" check the first time - give them time to try the app
            [alert setShowsSuppressionButton: allowNeverAgain];
            if (allowNeverAgain)
                [[alert suppressionButton] setTitle: NSLocalizedString(@"Don't bug me about this ever again.", "Donation beg -> button")];

            const NSInteger donateResult = [alert runModal];
            if (donateResult == NSAlertFirstButtonReturn)
                [self linkDonate: self];

            if (allowNeverAgain)
                [fDefaults setBool: ([[alert suppressionButton] state] != NSOnState) forKey: @"WarningDonate"];

            [alert release];
        }
    }
}

- (BOOL) applicationShouldHandleReopen: (NSApplication *) app hasVisibleWindows: (BOOL) visibleWindows
{
    NSWindow * mainWindow = [NSApp mainWindow];
    if (!mainWindow || ![mainWindow isVisible])
        [fWindow makeKeyAndOrderFront: nil];

    return NO;
}

- (NSApplicationTerminateReply) applicationShouldTerminate: (NSApplication *) sender
{
    if (!fQuitRequested && [fDefaults boolForKey: @"CheckQuit"])
    {
        NSInteger active = 0, downloading = 0;
        for (Torrent * torrent  in fTorrents)
            if ([torrent isActive] && ![torrent isStalled])
            {
                active++;
                if (![torrent allDownloaded])
                    downloading++;
            }

        if ([fDefaults boolForKey: @"CheckQuitDownloading"] ? downloading > 0 : active > 0)
        {
            NSString * message = active == 1
                ? NSLocalizedString(@"There is an active transfer that will be paused on quit."
                    " The transfer will automatically resume on the next launch.", "Confirm Quit panel -> message")
                : [NSString stringWithFormat: NSLocalizedString(@"There are %d active transfers that will be paused on quit."
                    " The transfers will automatically resume on the next launch.", "Confirm Quit panel -> message"), active];

            NSBeginAlertSheet(NSLocalizedString(@"Are you sure you want to quit?", "Confirm Quit panel -> title"),
                                NSLocalizedString(@"Quit", "Confirm Quit panel -> button"),
                                NSLocalizedString(@"Cancel", "Confirm Quit panel -> button"), nil, fWindow, self,
                                @selector(quitSheetDidEnd:returnCode:contextInfo:), nil, nil, message);
            return NSTerminateLater;
        }
    }

    return NSTerminateNow;
}

- (void) quitSheetDidEnd: (NSWindow *) sheet returnCode: (NSInteger) returnCode contextInfo: (void *) contextInfo
{
    [NSApp replyToApplicationShouldTerminate: returnCode == NSAlertDefaultReturn];
}

- (void) applicationWillTerminate: (NSNotification *) notification
{
    fQuitting = YES;

    //stop the Bonjour service
    [[BonjourController defaultController] stop];

    //stop blocklist download
    if ([BlocklistDownloader isRunning])
        [[BlocklistDownloader downloader] cancelDownload];

    //stop timers and notification checking
    [[NSNotificationCenter defaultCenter] removeObserver: self];

    [fTimer invalidate];

    if (fAutoImportTimer)
    {
        if ([fAutoImportTimer isValid])
            [fAutoImportTimer invalidate];
        [fAutoImportTimer release];
    }

    [fBadger setQuitting];

    //remove all torrent downloads
    if (fPendingTorrentDownloads)
    {
        for (NSDictionary * downloadDict in fPendingTorrentDownloads)
        {
            NSURLDownload * download = [downloadDict objectForKey: @"Download"];
            [download cancel];
            [download release];
        }
        [fPendingTorrentDownloads release];
    }

    //remember window states and close all windows
    [fDefaults setBool: [[fInfoController window] isVisible] forKey: @"InfoVisible"];

    const BOOL quickLookOpen = [NSApp isOnSnowLeopardOrBetter] && [QLPreviewPanelSL sharedPreviewPanelExists]
                                && [[QLPreviewPanelSL sharedPreviewPanel] isVisible];
    if (quickLookOpen)
        [[QLPreviewPanelSL sharedPreviewPanel] updateController];

    for (NSWindow * window in [NSApp windows])
        [window close];

    [self showStatusBar: NO animate: NO];
    [self showFilterBar: NO animate: NO];

    //save history
    [self updateTorrentHistory];
    [fTableView saveCollapsedGroups];

    //remaining calls the same as dealloc
    [fInfoController release];
    [fMessageController release];
    [fPrefsController release];

    [fStatusBar release];
    [fFilterBar release];

    [fTorrents release];
    [fDisplayedTorrents release];

    [fOverlayWindow release];
    [fBadger release];

    [fAutoImportedNames release];

    [fPreviewPanel release];

    //complete cleanup
    tr_sessionClose(fLib);
}

- (void) handleOpenContentsEvent: (NSAppleEventDescriptor *) event replyEvent: (NSAppleEventDescriptor *) replyEvent
{
    NSString * urlString = nil;

    NSAppleEventDescriptor * directObject = [event paramDescriptorForKeyword: keyDirectObject];
    if ([directObject descriptorType] == typeAEList)
    {
        for (NSInteger i = 1; i <= [directObject numberOfItems]; i++)
            if ((urlString = [[directObject descriptorAtIndex: i] stringValue]))
                break;
    }
    else
        urlString = [directObject stringValue];

    if (urlString)
        [self openURL: urlString];
}

- (void) download: (NSURLDownload *) download decideDestinationWithSuggestedFilename: (NSString *) suggestedName
{
    if ([[suggestedName pathExtension] caseInsensitiveCompare: @"torrent"] != NSOrderedSame)
    {
        [download cancel];

        NSRunAlertPanel(NSLocalizedString(@"Torrent download failed", "Download not a torrent -> title"),
            [NSString stringWithFormat: NSLocalizedString(@"It appears that the file \"%@\" from %@ is not a torrent file.",
            "Download not a torrent -> message"), suggestedName,
            [[[[download request] URL] absoluteString] stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding]],
            NSLocalizedString(@"OK", "Download not a torrent -> button"), nil, nil);

        [download release];
    }
    else
        [download setDestination: [NSTemporaryDirectory() stringByAppendingPathComponent: [suggestedName lastPathComponent]]
                    allowOverwrite: NO];
}

-(void) download: (NSURLDownload *) download didCreateDestination: (NSString *) path
{
    if (!fPendingTorrentDownloads)
        fPendingTorrentDownloads = [[NSMutableDictionary alloc] init];

    [fPendingTorrentDownloads setObject: [NSDictionary dictionaryWithObjectsAndKeys:
                    path, @"Path", download, @"Download", nil] forKey: [[download request] URL]];
}

- (void) download: (NSURLDownload *) download didFailWithError: (NSError *) error
{
    NSRunAlertPanel(NSLocalizedString(@"Torrent download failed", "Torrent download error -> title"),
        [NSString stringWithFormat: NSLocalizedString(@"The torrent could not be downloaded from %@: %@.",
        "Torrent download failed -> message"),
        [[[[download request] URL] absoluteString] stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding],
        [error localizedDescription]], NSLocalizedString(@"OK", "Torrent download failed -> button"), nil, nil);

    [fPendingTorrentDownloads removeObjectForKey: [[download request] URL]];
    if ([fPendingTorrentDownloads count] == 0)
    {
        [fPendingTorrentDownloads release];
        fPendingTorrentDownloads = nil;
    }

    [download release];
}

- (void) downloadDidFinish: (NSURLDownload *) download
{
    NSString * path = [[fPendingTorrentDownloads objectForKey: [[download request] URL]] objectForKey: @"Path"];

    [self openFiles: [NSArray arrayWithObject: path] addType: ADD_URL forcePath: nil];

    //delete the torrent file after opening
    [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];

    [fPendingTorrentDownloads removeObjectForKey: [[download request] URL]];
    if ([fPendingTorrentDownloads count] == 0)
    {
        [fPendingTorrentDownloads release];
        fPendingTorrentDownloads = nil;
    }

    [download release];
}

- (void) application: (NSApplication *) app openFiles: (NSArray *) filenames
{
    [self openFiles: filenames addType: ADD_MANUAL forcePath: nil];
}

- (void) openFiles: (NSArray *) filenames addType: (addType) type forcePath: (NSString *) path
{
    BOOL deleteTorrentFile, canToggleDelete = NO;
    switch (type)
    {
        case ADD_CREATED:
            deleteTorrentFile = NO;
            break;
        case ADD_URL:
            deleteTorrentFile = YES;
            break;
        default:
            deleteTorrentFile = [fDefaults boolForKey: @"DeleteOriginalTorrent"];
            canToggleDelete = YES;
    }

    for (NSString * torrentPath in filenames)
    {
        //ensure torrent doesn't already exist
        tr_ctor * ctor = tr_ctorNew(fLib);
        tr_ctorSetMetainfoFromFile(ctor, [torrentPath UTF8String]);

        tr_info info;
        const tr_parse_result result = tr_torrentParse(ctor, &info);
        tr_ctorFree(ctor);

        if (result != TR_PARSE_OK)
        {
            if (result == TR_PARSE_DUPLICATE)
                [self duplicateOpenAlert: [NSString stringWithUTF8String: info.name]];
            else if (result == TR_PARSE_ERR)
            {
                if (type != ADD_AUTO)
                    [self invalidOpenAlert: [torrentPath lastPathComponent]];
            }
            else
                NSAssert2(NO, @"Unknown error code (%d) when attempting to open \"%@\"", result, torrentPath);

            tr_metainfoFree(&info);
            continue;
        }

        //determine download location
        NSString * location;
        BOOL lockDestination = NO; //don't override the location with a group location if it has a hardcoded path
        if (path)
        {
            location = [path stringByExpandingTildeInPath];
            lockDestination = YES;
        }
        else if ([fDefaults boolForKey: @"DownloadLocationConstant"])
            location = [[fDefaults stringForKey: @"DownloadFolder"] stringByExpandingTildeInPath];
        else if (type != ADD_URL)
            location = [torrentPath stringByDeletingLastPathComponent];
        else
            location = nil;

        //determine to show the options window
        const BOOL showWindow = type == ADD_SHOW_OPTIONS || ([fDefaults boolForKey: @"DownloadAsk"]
                                    && (info.isMultifile || ![fDefaults boolForKey: @"DownloadAskMulti"])
                                    && (type != ADD_AUTO || ![fDefaults boolForKey: @"DownloadAskManual"]));
        tr_metainfoFree(&info);

        Torrent * torrent;
        if (!(torrent = [[Torrent alloc] initWithPath: torrentPath location: location
                            deleteTorrentFile: showWindow ? NO : deleteTorrentFile lib: fLib]))
            continue;

        //change the location if the group calls for it (this has to wait until after the torrent is created)
        if (!lockDestination && [[GroupsController groups] usesCustomDownloadLocationForIndex: [torrent groupValue]])
        {
            location = [[GroupsController groups] customDownloadLocationForIndex: [torrent groupValue]];
            [torrent changeDownloadFolderBeforeUsing: location];
        }

        //verify the data right away if it was newly created
        if (type == ADD_CREATED)
            [torrent resetCache];

        //add it to the "File -> Open Recent" menu
        [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL: [NSURL fileURLWithPath: torrentPath]];

        //show the add window or add directly
        if (showWindow || !location)
        {
            AddWindowController * addController = [[AddWindowController alloc] initWithTorrent: torrent destination: location
                                                    lockDestination: lockDestination controller: self torrentFile: torrentPath
                                                    deleteTorrent: deleteTorrentFile canToggleDelete: canToggleDelete];
            [addController showWindow: self];
        }
        else
        {
            [torrent setWaitToStart: [fDefaults boolForKey: @"AutoStartDownload"]];

            [torrent update];
            [fTorrents addObject: torrent];
            [torrent release];
        }
    }

    [self updateTorrentsInQueue];
}

- (void) askOpenConfirmed: (AddWindowController *) addController add: (BOOL) add
{
    Torrent * torrent = [addController torrent];
    [addController release];

    if (add)
    {
        [torrent update];
        [fTorrents addObject: torrent];
        [torrent release];

        [self updateTorrentsInQueue];
    }
    else
    {
        [torrent closeRemoveTorrent: NO];
        [torrent release];
    }
}

- (void) openMagnet: (NSString *) address
{
    tr_torrent * duplicateTorrent;
    if ((duplicateTorrent = tr_torrentFindFromMagnetLink(fLib, [address UTF8String])))
    {
        const tr_info * info = tr_torrentInfo(duplicateTorrent);
        NSString * name = (info != NULL && info->name != NULL) ? [NSString stringWithUTF8String: info->name] : nil;
        [self duplicateOpenMagnetAlert: address transferName: name];
        return;
    }

    //determine download location
    NSString * location = nil;
    if ([fDefaults boolForKey: @"DownloadLocationConstant"])
        location = [[fDefaults stringForKey: @"DownloadFolder"] stringByExpandingTildeInPath];

    Torrent * torrent;
    if (!(torrent = [[Torrent alloc] initWithMagnetAddress: address location: location lib: fLib]))
    {
        [self invalidOpenMagnetAlert: address];
        return;
    }

    //change the location if the group calls for it (this has to wait until after the torrent is created)
    if ([[GroupsController groups] usesCustomDownloadLocationForIndex: [torrent groupValue]])
    {
        location = [[GroupsController groups] customDownloadLocationForIndex: [torrent groupValue]];
        [torrent changeDownloadFolderBeforeUsing: location];
    }

    if ([fDefaults boolForKey: @"MagnetOpenAsk"] || !location)
    {
        AddMagnetWindowController * addController = [[AddMagnetWindowController alloc] initWithTorrent: torrent destination: location
                                                        controller: self];
        [addController showWindow: self];
    }
    else
    {
        [torrent setWaitToStart: [fDefaults boolForKey: @"AutoStartDownload"]];

        [torrent update];
        [fTorrents addObject: torrent];
        [torrent release];
    }

    [self updateTorrentsInQueue];
}

- (void) askOpenMagnetConfirmed: (AddMagnetWindowController *) addController add: (BOOL) add
{
    Torrent * torrent = [addController torrent];
    [addController release];

    if (add)
    {
        [torrent update];
        [fTorrents addObject: torrent];
        [torrent release];

        [self updateTorrentsInQueue];
    }
    else
    {
        [torrent closeRemoveTorrent: NO];
        [torrent release];
    }
}

- (void) openCreatedFile: (NSNotification *) notification
{
    NSDictionary * dict = [notification userInfo];
    [self openFiles: [NSArray arrayWithObject: [dict objectForKey: @"File"]] addType: ADD_CREATED
                        forcePath: [dict objectForKey: @"Path"]];
    [dict release];
}

- (void) openFilesWithDict: (NSDictionary *) dictionary
{
    [self openFiles: [dictionary objectForKey: @"Filenames"] addType: [[dictionary objectForKey: @"AddType"] intValue] forcePath: nil];

    [dictionary release];
}

//called on by applescript
- (void) open: (NSArray *) files
{
    NSDictionary * dict = [[NSDictionary alloc] initWithObjectsAndKeys: files, @"Filenames",
                                [NSNumber numberWithInt: ADD_MANUAL], @"AddType", nil];
    [self performSelectorOnMainThread: @selector(openFilesWithDict:) withObject: dict waitUntilDone: NO];
}

- (void) openShowSheet: (id) sender
{
    NSOpenPanel * panel = [NSOpenPanel openPanel];

    [panel setAllowsMultipleSelection: YES];
    [panel setCanChooseFiles: YES];
    [panel setCanChooseDirectories: NO];

    [panel beginSheetForDirectory: nil file: nil types: [NSArray arrayWithObjects: @"org.bittorrent.torrent", @"torrent", nil]
        modalForWindow: fWindow modalDelegate: self didEndSelector: @selector(openSheetClosed:returnCode:contextInfo:)
        contextInfo: [NSNumber numberWithBool: sender == fOpenIgnoreDownloadFolder]];
}

- (void) openSheetClosed: (NSOpenPanel *) panel returnCode: (NSInteger) code contextInfo: (NSNumber *) useOptions
{
    if (code == NSOKButton)
    {
        NSDictionary * dictionary = [[NSDictionary alloc] initWithObjectsAndKeys: [panel filenames], @"Filenames",
            [NSNumber numberWithInt: [useOptions boolValue] ? ADD_SHOW_OPTIONS : ADD_MANUAL], @"AddType", nil];
        [self performSelectorOnMainThread: @selector(openFilesWithDict:) withObject: dictionary waitUntilDone: NO];
    }
}

- (void) invalidOpenAlert: (NSString *) filename
{
    if (![fDefaults boolForKey: @"WarningInvalidOpen"])
        return;

    NSAlert * alert = [[NSAlert alloc] init];
    [alert setMessageText: [NSString stringWithFormat: NSLocalizedString(@"\"%@\" is not a valid torrent file.",
                            "Open invalid alert -> title"), filename]];
    [alert setInformativeText:
            NSLocalizedString(@"The torrent file cannot be opened because it contains invalid data.",
                            "Open invalid alert -> message")];
    [alert setAlertStyle: NSWarningAlertStyle];
    [alert addButtonWithTitle: NSLocalizedString(@"OK", "Open invalid alert -> button")];

    [alert runModal];
    if ([[alert suppressionButton] state] == NSOnState)
        [fDefaults setBool: NO forKey: @"WarningInvalidOpen"];
    [alert release];
}

- (void) invalidOpenMagnetAlert: (NSString *) address
{
    if (![fDefaults boolForKey: @"WarningInvalidOpen"])
        return;

    NSAlert * alert = [[NSAlert alloc] init];
    [alert setMessageText: NSLocalizedString(@"Adding magnetized transfer failed.", "Magnet link failed -> title")];
    [alert setInformativeText: [NSString stringWithFormat: NSLocalizedString(@"There was an error when adding the magnet link \"%@\"."
                                " The transfer will not occur.", "Magnet link failed -> message"), address]];
    [alert setAlertStyle: NSWarningAlertStyle];
    [alert addButtonWithTitle: NSLocalizedString(@"OK", "Magnet link failed -> button")];

    [alert runModal];
    if ([[alert suppressionButton] state] == NSOnState)
        [fDefaults setBool: NO forKey: @"WarningInvalidOpen"];
    [alert release];
}

- (void) duplicateOpenAlert: (NSString *) name
{
    if (![fDefaults boolForKey: @"WarningDuplicate"])
        return;

    NSAlert * alert = [[NSAlert alloc] init];
    [alert setMessageText: [NSString stringWithFormat: NSLocalizedString(@"A transfer of \"%@\" already exists.",
                            "Open duplicate alert -> title"), name]];
    [alert setInformativeText:
            NSLocalizedString(@"The transfer cannot be added because it is a duplicate of an already existing transfer.",
                            "Open duplicate alert -> message")];
    [alert setAlertStyle: NSWarningAlertStyle];
    [alert addButtonWithTitle: NSLocalizedString(@"OK", "Open duplicate alert -> button")];
    [alert setShowsSuppressionButton: YES];

    [alert runModal];
    if ([[alert suppressionButton] state])
        [fDefaults setBool: NO forKey: @"WarningDuplicate"];
    [alert release];
}

- (void) duplicateOpenMagnetAlert: (NSString *) address transferName: (NSString *) name
{
    if (![fDefaults boolForKey: @"WarningDuplicate"])
        return;

    NSAlert * alert = [[NSAlert alloc] init];
    if (name)
        [alert setMessageText: [NSString stringWithFormat: NSLocalizedString(@"A transfer of \"%@\" already exists.",
                                "Open duplicate magnet alert -> title"), name]];
    else
        [alert setMessageText: NSLocalizedString(@"Magnet link is a duplicate of an existing transfer.",
                                "Open duplicate magnet alert -> title")];
    [alert setInformativeText: [NSString stringWithFormat:
            NSLocalizedString(@"The magnet link  \"%@\" cannot be added because it is a duplicate of an already existing transfer.",
                            "Open duplicate magnet alert -> message"), address]];
    [alert setAlertStyle: NSWarningAlertStyle];
    [alert addButtonWithTitle: NSLocalizedString(@"OK", "Open duplicate magnet alert -> button")];
    [alert setShowsSuppressionButton: YES];

    [alert runModal];
    if ([[alert suppressionButton] state])
        [fDefaults setBool: NO forKey: @"WarningDuplicate"];
    [alert release];
}

- (void) openURL: (NSString *) urlString
{
    if ([urlString rangeOfString: @"magnet:" options: (NSAnchoredSearch | NSCaseInsensitiveSearch)].location != NSNotFound)
        [self openMagnet: urlString];
    else
    {
        if ([urlString rangeOfString: @"://"].location == NSNotFound)
        {
            if ([urlString rangeOfString: @"."].location == NSNotFound)
            {
                NSInteger beforeCom;
                if ((beforeCom = [urlString rangeOfString: @"/"].location) != NSNotFound)
                    urlString = [NSString stringWithFormat: @"http://www.%@.com/%@",
                                    [urlString substringToIndex: beforeCom],
                                    [urlString substringFromIndex: beforeCom + 1]];
                else
                    urlString = [NSString stringWithFormat: @"http://www.%@.com/", urlString];
            }
            else
                urlString = [@"http://" stringByAppendingString: urlString];
        }

        NSURLRequest * request = [NSURLRequest requestWithURL: [NSURL URLWithString: urlString]
                                    cachePolicy: NSURLRequestReloadIgnoringLocalAndRemoteCacheData timeoutInterval: 60];
        [[NSURLDownload alloc] initWithRequest: request delegate: self];
    }
}

- (void) openURLShowSheet: (id) sender
{
    [[[URLSheetWindowController alloc] initWithController: self] beginSheetForWindow: fWindow];
}

- (void) urlSheetDidEnd: (URLSheetWindowController *) controller url: (NSString *) urlString returnCode: (NSInteger) returnCode
{
    if (returnCode == 1)
        [self performSelectorOnMainThread: @selector(openURL:) withObject: urlString waitUntilDone: NO];

    [controller release];
}

- (void) createFile: (id) sender
{
    [CreatorWindowController createTorrentFile: fLib];
}

- (void) resumeSelectedTorrents: (id) sender
{
    [self resumeTorrents: [fTableView selectedTorrents]];
}

- (void) resumeAllTorrents: (id) sender
{
    NSMutableArray * torrents = [NSMutableArray arrayWithCapacity: [fTorrents count]];

    for (Torrent * torrent in fTorrents)
        if (![torrent isFinishedSeeding])
            [torrents addObject: torrent];

    [self resumeTorrents: torrents];
}

- (void) resumeTorrents: (NSArray *) torrents
{
    for (Torrent * torrent in torrents)
        [torrent setWaitToStart: YES];

    [self updateTorrentsInQueue];
}

- (void) resumeSelectedTorrentsNoWait:  (id) sender
{
    [self resumeTorrentsNoWait: [fTableView selectedTorrents]];
}

- (void) resumeWaitingTorrents: (id) sender
{
    NSMutableArray * torrents = [NSMutableArray arrayWithCapacity: [fTorrents count]];

    for (Torrent * torrent in fTorrents)
        if (![torrent isActive] && [torrent waitingToStart])
            [torrents addObject: torrent];

    [self resumeTorrentsNoWait: torrents];
}

- (void) resumeTorrentsNoWait: (NSArray *) torrents
{
    //iterate through instead of all at once to ensure no conflicts
    for (Torrent * torrent in torrents)
    {
        tr_inf( "restarting a torrent in resumeTorrentsNoWait" );
        [torrent startTransfer];
    }

    [self updateUI];
    [self applyFilter];
    [[fWindow toolbar] validateVisibleItems];
    [self updateTorrentHistory];
}

- (void) stopSelectedTorrents: (id) sender
{
    [self stopTorrents: [fTableView selectedTorrents]];
}

- (void) stopAllTorrents: (id) sender
{
    [self stopTorrents: fTorrents];
}

- (void) stopTorrents: (NSArray *) torrents
{
    //don't want any of these starting then stopping
    for (Torrent * torrent in torrents)
        [torrent setWaitToStart: NO];

    [torrents makeObjectsPerformSelector: @selector(stopTransfer)];

    [self updateUI];
    [self applyFilter];
    [[fWindow toolbar] validateVisibleItems];
    [self updateTorrentHistory];
}

- (void) removeTorrents: (NSArray *) torrents deleteData: (BOOL) deleteData
{
    [torrents retain];

    if ([fDefaults boolForKey: @"CheckRemove"])
    {
        NSUInteger active = 0, downloading = 0;
        for (Torrent * torrent in torrents)
            if ([torrent isActive])
            {
                ++active;
                if (![torrent isSeeding])
                    ++downloading;
            }

        if ([fDefaults boolForKey: @"CheckRemoveDownloading"] ? downloading > 0 : active > 0)
        {
            NSDictionary * dict = [[NSDictionary alloc] initWithObjectsAndKeys:
                                    torrents, @"Torrents",
                                    [NSNumber numberWithBool: deleteData], @"DeleteData", nil];

            NSString * title, * message;

            const NSInteger selected = [torrents count];
            if (selected == 1)
            {
                NSString * torrentName = [[torrents objectAtIndex: 0] name];

                if (deleteData)
                    title = [NSString stringWithFormat:
                                NSLocalizedString(@"Are you sure you want to remove \"%@\" from the transfer list"
                                " and trash the data file?", "Removal confirm panel -> title"), torrentName];
                else
                    title = [NSString stringWithFormat:
                                NSLocalizedString(@"Are you sure you want to remove \"%@\" from the transfer list?",
                                "Removal confirm panel -> title"), torrentName];

                message = NSLocalizedString(@"This transfer is active."
                            " Once removed, continuing the transfer will require the torrent file or magnet link.",
                            "Removal confirm panel -> message");
            }
            else
            {
                if (deleteData)
                    title = [NSString stringWithFormat:
                                NSLocalizedString(@"Are you sure you want to remove %@ transfers from the transfer list"
                                " and trash the data files?", "Removal confirm panel -> title"), [NSString formattedUInteger: selected]];
                else
                    title = [NSString stringWithFormat:
                                NSLocalizedString(@"Are you sure you want to remove %@ transfers from the transfer list?",
                                "Removal confirm panel -> title"), [NSString formattedUInteger: selected]];

                if (selected == active)
                    message = [NSString stringWithFormat: NSLocalizedString(@"There are %@ active transfers.",
                                "Removal confirm panel -> message part 1"), [NSString formattedUInteger: active]];
                else
                    message = [NSString stringWithFormat: NSLocalizedString(@"There are %@ transfers (%@ active).",
                                "Removal confirm panel -> message part 1"), [NSString formattedUInteger: selected], [NSString formattedUInteger: active]];
                message = [message stringByAppendingFormat: @" %@",
                            NSLocalizedString(@"Once removed, continuing the transfers will require the torrent files or magnet links.",
                            "Removal confirm panel -> message part 2")];
            }

            NSBeginAlertSheet(title, NSLocalizedString(@"Remove", "Removal confirm panel -> button"),
                NSLocalizedString(@"Cancel", "Removal confirm panel -> button"), nil, fWindow, self,
                nil, @selector(removeSheetDidEnd:returnCode:contextInfo:), dict, message);
            return;
        }
    }

    [self confirmRemoveTorrents: torrents deleteData: deleteData];
}

- (void) removeSheetDidEnd: (NSWindow *) sheet returnCode: (NSInteger) returnCode contextInfo: (NSDictionary *) dict
{
    NSArray * torrents = [dict objectForKey: @"Torrents"];
    if (returnCode == NSAlertDefaultReturn)
        [self confirmRemoveTorrents: torrents deleteData: [[dict objectForKey: @"DeleteData"] boolValue]];
    else
        [torrents release];

    [dict release];
}

- (void) confirmRemoveTorrents: (NSArray *) torrents deleteData: (BOOL) deleteData
{
    NSMutableArray * selectedValues = [NSMutableArray arrayWithArray: [fTableView selectedValues]];
    [selectedValues removeObjectsInArray: torrents];

    //don't want any of these starting then stopping
    for (Torrent * torrent in torrents)
        [torrent setWaitToStart: NO];

    [fTorrents removeObjectsInArray: torrents];

    //if not removed from displayed torrents, updateTorrentsInQueue might cause a crash
    if ([fDisplayedTorrents count] > 0)
    {
        if ([[fDisplayedTorrents objectAtIndex: 0] isKindOfClass: [TorrentGroup class]])
        {
            for (TorrentGroup * group in fDisplayedTorrents)
                [[group torrents] removeObjectsInArray: torrents];
        }
        else
            [fDisplayedTorrents removeObjectsInArray: torrents];
    }

    for (Torrent * torrent in torrents)
    {
        //let's expand all groups that have removed items - they either don't exist anymore, are already expanded, or are collapsed (rpc)
        [fTableView removeCollapsedGroup: [torrent groupValue]];

        //we can't assume the window is active - RPC removal, for example
        [fBadger removeTorrent: torrent];

        [torrent closeRemoveTorrent: deleteData];
    }

    #warning why do we need them retained?
    [torrents release];

    [fTableView selectValues: selectedValues];

    [self updateTorrentsInQueue];
}

- (void) removeNoDelete: (id) sender
{
    [self removeTorrents: [fTableView selectedTorrents] deleteData: NO];
}

- (void) removeDeleteData: (id) sender
{
    [self removeTorrents: [fTableView selectedTorrents] deleteData: YES];
}

- (void) clearCompleted: (id) sender
{
    NSMutableArray * torrents = [[NSMutableArray alloc] init];

    for (Torrent * torrent in fTorrents)
        if ([torrent isFinishedSeeding])
            [torrents addObject: torrent];

    if ([fDefaults boolForKey: @"WarningRemoveCompleted"])
    {
        NSString * message, * info;
        if ([torrents count] == 1)
        {
            NSString * torrentName = [[torrents objectAtIndex: 0] name];
            message = [NSString stringWithFormat: NSLocalizedString(@"Are you sure you want to remove \"%@\" from the transfer list?",
                                                                  "Remove completed confirm panel -> title"), torrentName];

            info = NSLocalizedString(@"Once removed, continuing the transfer will require the torrent file or magnet link.",
                                     "Remove completed confirm panel -> message");
        }
        else
        {
            message = [NSString stringWithFormat: NSLocalizedString(@"Are you sure you want to remove %@ completed transfers from the transfer list?",
                                                                  "Remove completed confirm panel -> title"), [NSString formattedUInteger: [torrents count]]];

            info = NSLocalizedString(@"Once removed, continuing the transfers will require the torrent files or magnet links.",
                                     "Remove completed confirm panel -> message");
        }

        NSAlert * alert = [[[NSAlert alloc] init] autorelease];
        [alert setMessageText: message];
        [alert setInformativeText: info];
        [alert setAlertStyle: NSWarningAlertStyle];
        [alert addButtonWithTitle: NSLocalizedString(@"Remove", "Remove completed confirm panel -> button")];
        [alert addButtonWithTitle: NSLocalizedString(@"Cancel", "Remove completed confirm panel -> button")];
        [alert setShowsSuppressionButton: YES];

        const NSInteger returnCode = [alert runModal];
        if ([[alert suppressionButton] state])
            [fDefaults setBool: NO forKey: @"WarningRemoveCompleted"];

        if (returnCode != NSAlertFirstButtonReturn)
            return;
    }

    [self confirmRemoveTorrents: torrents deleteData: NO];
}

- (void) moveDataFilesSelected: (id) sender
{
    [self moveDataFiles: [fTableView selectedTorrents]];
}

- (void) moveDataFiles: (NSArray *) torrents
{
    NSOpenPanel * panel = [NSOpenPanel openPanel];
    [panel setPrompt: NSLocalizedString(@"Select", "Move torrent -> prompt")];
    [panel setAllowsMultipleSelection: NO];
    [panel setCanChooseFiles: NO];
    [panel setCanChooseDirectories: YES];
    [panel setCanCreateDirectories: YES];

    torrents = [torrents retain];
    NSInteger count = [torrents count];
    if (count == 1)
        [panel setMessage: [NSString stringWithFormat: NSLocalizedString(@"Select the new folder for \"%@\".",
                            "Move torrent -> select destination folder"), [[torrents objectAtIndex: 0] name]]];
    else
        [panel setMessage: [NSString stringWithFormat: NSLocalizedString(@"Select the new folder for %d data files.",
                            "Move torrent -> select destination folder"), count]];

    [panel beginSheetForDirectory: nil file: nil modalForWindow: fWindow modalDelegate: self
        didEndSelector: @selector(moveDataFileChoiceClosed:returnCode:contextInfo:) contextInfo: torrents];
}

- (void) moveDataFileChoiceClosed: (NSOpenPanel *) panel returnCode: (NSInteger) code contextInfo: (NSArray *) torrents
{
    if (code == NSOKButton)
    {
        for (Torrent * torrent in torrents)
            [torrent moveTorrentDataFileTo: [[panel filenames] objectAtIndex: 0]];
    }

    [torrents release];
}

- (void) copyTorrentFiles: (id) sender
{
    [self copyTorrentFileForTorrents: [[NSMutableArray alloc] initWithArray: [fTableView selectedTorrents]]];
}

- (void) copyTorrentFileForTorrents: (NSMutableArray *) torrents
{
    if ([torrents count] == 0)
    {
        [torrents release];
        return;
    }

    Torrent * torrent = [torrents objectAtIndex: 0];

    if (![torrent isMagnet] && [[NSFileManager defaultManager] fileExistsAtPath: [torrent torrentLocation]])
    {
        NSSavePanel * panel = [NSSavePanel savePanel];
        [panel setAllowedFileTypes: [NSArray arrayWithObjects: @"org.bittorrent.torrent", @"torrent", nil]];
        [panel setExtensionHidden: NO];

        [panel beginSheetForDirectory: nil file: [torrent name] modalForWindow: fWindow modalDelegate: self
            didEndSelector: @selector(saveTorrentCopySheetClosed:returnCode:contextInfo:) contextInfo: torrents];
    }
    else
    {
        if (![torrent isMagnet])
        {
            NSAlert * alert = [[NSAlert alloc] init];
            [alert addButtonWithTitle: NSLocalizedString(@"OK", "Torrent file copy alert -> button")];
            [alert setMessageText: [NSString stringWithFormat: NSLocalizedString(@"Copy of \"%@\" Cannot Be Created",
                                    "Torrent file copy alert -> title"), [torrent name]]];
            [alert setInformativeText: [NSString stringWithFormat:
                    NSLocalizedString(@"The torrent file (%@) cannot be found.", "Torrent file copy alert -> message"),
                                        [torrent torrentLocation]]];
            [alert setAlertStyle: NSWarningAlertStyle];

            [alert runModal];
            [alert release];
        }

        [torrents removeObjectAtIndex: 0];
        [self copyTorrentFileForTorrents: torrents];
    }
}

- (void) saveTorrentCopySheetClosed: (NSSavePanel *) panel returnCode: (NSInteger) code contextInfo: (NSMutableArray *) torrents
{
    //copy torrent to new location with name of data file
    if (code == NSOKButton)
        [[torrents objectAtIndex: 0] copyTorrentFileTo: [panel filename]];

    [torrents removeObjectAtIndex: 0];
    [self performSelectorOnMainThread: @selector(copyTorrentFileForTorrents:) withObject: torrents waitUntilDone: NO];
}

- (void) copyMagnetLinks: (id) sender
{
    NSArray * torrents = [fTableView selectedTorrents];

    if ([torrents count] <= 0)
        return;

    NSMutableArray * links = [NSMutableArray arrayWithCapacity: [torrents count]];
    for (Torrent * torrent in torrents)
        [links addObject: [torrent magnetLink]];

    NSString * text = [links componentsJoinedByString: @"\n"];

    NSPasteboard * pb = [NSPasteboard generalPasteboard];
    if ([NSApp isOnSnowLeopardOrBetter])
    {
        [pb clearContents];
        [pb writeObjects: [NSArray arrayWithObject: text]];
    }
    else
    {
        [pb declareTypes: [NSArray arrayWithObject: NSStringPboardType] owner: nil];
        [pb setString: text forType: NSStringPboardType];
    }
}

- (void) revealFile: (id) sender
{
    NSArray * selected = [fTableView selectedTorrents];
    if ([NSApp isOnSnowLeopardOrBetter])
    {
        NSMutableArray * paths = [NSMutableArray arrayWithCapacity: [selected count]];
        for (Torrent * torrent in selected)
        {
            NSString * location = [torrent dataLocation];
            if (location)
                [paths addObject: [NSURL fileURLWithPath: location]];
        }

        if ([paths count] > 0)
            [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs: paths];
    }
    else
    {
        for (Torrent * torrent in selected)
        {
            NSString * location = [torrent dataLocation];
            if (location)
                [[NSWorkspace sharedWorkspace] selectFile: location inFileViewerRootedAtPath: nil];
        }
    }
}

- (void) announceSelectedTorrents: (id) sender
{
    for (Torrent * torrent in [fTableView selectedTorrents])
    {
        if ([torrent canManualAnnounce])
            [torrent manualAnnounce];
    }
}

- (void) verifySelectedTorrents: (id) sender
{
    [self verifyTorrents: [fTableView selectedTorrents]];
}

- (void) verifyTorrents: (NSArray *) torrents
{
    for (Torrent * torrent in torrents)
        [torrent resetCache];

    [self applyFilter];
}

- (void) showPreferenceWindow: (id) sender
{
    NSWindow * window = [fPrefsController window];
    if (![window isVisible])
        [window center];

    [window makeKeyAndOrderFront: nil];
}

- (void) showAboutWindow: (id) sender
{
    [[AboutWindowController aboutController] showWindow: nil];
}

- (void) showInfo: (id) sender
{
    if ([[fInfoController window] isVisible])
        [fInfoController close];
    else
    {
        [fInfoController updateInfoStats];
        [[fInfoController window] orderFront: nil];

        if ([fInfoController canQuickLook]
            && [QLPreviewPanelSL sharedPreviewPanelExists] && [[QLPreviewPanelSL sharedPreviewPanel] isVisible])
            [[QLPreviewPanelSL sharedPreviewPanel] reloadData];

    }

    [[fWindow toolbar] validateVisibleItems];
}

- (void) resetInfo
{
    [fInfoController setInfoForTorrents: [fTableView selectedTorrents]];

    if ([NSApp isOnSnowLeopardOrBetter] && [QLPreviewPanelSL sharedPreviewPanelExists]
        && [[QLPreviewPanelSL sharedPreviewPanel] isVisible])
        [[QLPreviewPanelSL sharedPreviewPanel] reloadData];
}

- (void) setInfoTab: (id) sender
{
    if (sender == fNextInfoTabItem)
        [fInfoController setNextTab];
    else
        [fInfoController setPreviousTab];
}

- (void) showMessageWindow: (id) sender
{
    if (!fMessageController)
        fMessageController = [[MessageWindowController alloc] init];
    [fMessageController showWindow: nil];
}

- (void) showStatsWindow: (id) sender
{
    [[StatsWindowController statsWindow: fLib] showWindow: nil];
}

- (void) updateUI
{
    [fTorrents makeObjectsPerformSelector: @selector(update)];

    //pull the upload and download speeds - most consistent by using current stats
    CGFloat dlRate = 0.0, ulRate = 0.0;
    BOOL completed = NO;
    for (Torrent * torrent in fTorrents)
    {
        dlRate += [torrent downloadRate];
        ulRate += [torrent uploadRate];

        completed |= [torrent isFinishedSeeding];
    }

    if (![NSApp isHidden])
    {
        if ([fWindow isVisible])
        {
            [self sortTorrents];

            [fStatusBar updateWithDownload: dlRate upload: ulRate];

            [fClearCompletedButton setHidden: !completed];
        }

        //update non-constant parts of info window
        if ([[fInfoController window] isVisible])
            [fInfoController updateInfoStats];
    }

    //badge dock
    [fBadger updateBadgeWithDownload: dlRate upload: ulRate];
}

- (void) setBottomCountText: (BOOL) filtering
{
    NSString * totalTorrentsString;
    NSUInteger totalCount = [fTorrents count];
    if (totalCount != 1)
        totalTorrentsString = [NSString stringWithFormat: NSLocalizedString(@"%@ transfers", "Status bar transfer count"),
                                [NSString formattedUInteger: totalCount]];
    else
        totalTorrentsString = NSLocalizedString(@"1 transfer", "Status bar transfer count");

    if (filtering)
    {
        NSUInteger count = [fTableView numberOfRows]; //have to factor in collapsed rows
        if (count > 0 && ![[fDisplayedTorrents objectAtIndex: 0] isKindOfClass: [Torrent class]])
            count -= [fDisplayedTorrents count];

        totalTorrentsString = [NSString stringWithFormat: NSLocalizedString(@"%@ of %@", "Status bar transfer count"),
                                [NSString formattedUInteger: count], totalTorrentsString];
    }

    [fTotalTorrentsField setStringValue: totalTorrentsString];
}

- (void) updateTorrentsInQueue
{
    NSUInteger desiredDownloadActive = [fDefaults boolForKey: @"Queue"] ? [self numToStartFromQueue: YES] : NSUIntegerMax,
                desiredSeedActive = [fDefaults boolForKey: @"QueueSeed"] ? [self numToStartFromQueue: NO] : NSUIntegerMax;

    for (Torrent * torrent in fTorrents)
    {
        if (desiredDownloadActive == 0 && desiredSeedActive == 0)
            break;

        if (![torrent isActive] && ![torrent isChecking] && [torrent waitingToStart])
        {
            if (![torrent allDownloaded])
            {
                if (desiredDownloadActive > 0)
                {
                    tr_inf( "restarting download torrent in mac queue" );
                    [torrent startTransfer];
                    if ([torrent isActive])
                        --desiredDownloadActive;
                    [torrent update];
                }
            }
            else
            {
                if (desiredSeedActive > 0)
                {
                    tr_inf( "restarting seed torrent in mac queue" );
                    [torrent startTransfer];
                    if ([torrent isActive])
                        --desiredSeedActive;
                    [torrent update];
                }
            }
        }
    }

    [self updateUI];
    [self applyFilter];
    [[fWindow toolbar] validateVisibleItems];
    [self updateTorrentHistory];
}

- (NSUInteger) numToStartFromQueue: (BOOL) downloadQueue
{
    if (![fDefaults boolForKey: downloadQueue ? @"Queue" : @"QueueSeed"])
        return 0;

    NSUInteger desired = [fDefaults integerForKey: downloadQueue ? @"QueueDownloadNumber" : @"QueueSeedNumber"];

    for (Torrent * torrent in fTorrents)
    {
        if (desired == 0)
            break;

        if ([torrent isChecking])
            --desired;
        else if ([torrent isActive] && ![torrent isStalled] && ![torrent isError])
        {
            if ([torrent allDownloaded] != downloadQueue)
                --desired;
        }
        else;
    }

    return desired;
}

- (void) torrentFinishedDownloading: (NSNotification *) notification
{
    Torrent * torrent = [notification object];

    if ([[[notification userInfo] objectForKey: @"WasRunning"] boolValue])
    {
        if (!fSoundPlaying && [fDefaults boolForKey: @"PlayDownloadSound"])
        {
            NSSound * sound;
            if ((sound = [NSSound soundNamed: [fDefaults stringForKey: @"DownloadSound"]]))
            {
                [sound setDelegate: self];
                fSoundPlaying = YES;
                [sound play];
            }
        }

        NSMutableDictionary * clickContext = [NSMutableDictionary dictionaryWithObject: GROWL_DOWNLOAD_COMPLETE forKey: @"Type"];

        NSString * location = [torrent dataLocation];
        if (location)
            [clickContext setObject: location forKey: @"Location"];

        [GrowlApplicationBridge notifyWithTitle: NSLocalizedString(@"Download Complete", "Growl notification title")
                                    description: [torrent name] notificationName: GROWL_DOWNLOAD_COMPLETE
                                    iconData: nil priority: 0 isSticky: NO clickContext: clickContext];

        if (![fWindow isMainWindow])
            [fBadger addCompletedTorrent: torrent];

        //bounce download stack
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName: @"com.apple.DownloadFileFinished"
            object: [torrent dataLocation]];

        if ([torrent isActive] && [fDefaults boolForKey: @"QueueSeed"] && [self numToStartFromQueue: NO] == 0)
        {
            [torrent stopTransfer];
            [torrent setWaitToStart: YES];
        }
    }

    [self updateTorrentsInQueue];
}

- (void) torrentRestartedDownloading: (NSNotification *) notification
{
    Torrent * torrent = [notification object];
    if ([torrent isActive] && [fDefaults boolForKey: @"Queue"] && [self numToStartFromQueue: YES] == 0)
    {
        [torrent stopTransfer];
        [torrent setWaitToStart: YES];
    }

    [self updateTorrentsInQueue];
}

- (void) torrentFinishedSeeding: (NSNotification *) notification
{
    Torrent * torrent = [notification object];

    [self updateTorrentsInQueue];

    if ([[fTableView selectedTorrents] containsObject: torrent])
    {
        [fInfoController updateInfoStats];
        [fInfoController updateOptions];
    }

    if (!fSoundPlaying && [fDefaults boolForKey: @"PlaySeedingSound"])
    {
        NSSound * sound;
        if ((sound = [NSSound soundNamed: [fDefaults stringForKey: @"SeedingSound"]]))
        {
            [sound setDelegate: self];
            fSoundPlaying = YES;
            [sound play];
        }
    }

    NSMutableDictionary * clickContext = [NSMutableDictionary dictionaryWithObject: GROWL_SEEDING_COMPLETE forKey: @"Type"];

    NSString * location = [torrent dataLocation];
    if (location)
        [clickContext setObject: location forKey: @"Location"];

    [GrowlApplicationBridge notifyWithTitle: NSLocalizedString(@"Seeding Complete", "Growl notification title")
                        description: [torrent name] notificationName: GROWL_SEEDING_COMPLETE
                        iconData: nil priority: 0 isSticky: NO clickContext: clickContext];
}

- (void) updateTorrentHistory
{
    NSMutableArray * history = [NSMutableArray arrayWithCapacity: [fTorrents count]];

    for (Torrent * torrent in fTorrents)
        [history addObject: [torrent history]];

    [history writeToFile: [NSHomeDirectory() stringByAppendingPathComponent: TRANSFER_PLIST] atomically: YES];
}

- (void) setSort: (id) sender
{
    NSString * sortType;
    switch ([sender tag])
    {
        case SORT_ORDER_TAG:
            sortType = SORT_ORDER;
            [fDefaults setBool: NO forKey: @"SortReverse"];
            break;
        case SORT_DATE_TAG:
            sortType = SORT_DATE;
            break;
        case SORT_NAME_TAG:
            sortType = SORT_NAME;
            break;
        case SORT_PROGRESS_TAG:
            sortType = SORT_PROGRESS;
            break;
        case SORT_STATE_TAG:
            sortType = SORT_STATE;
            break;
        case SORT_TRACKER_TAG:
            sortType = SORT_TRACKER;
            break;
        case SORT_ACTIVITY_TAG:
            sortType = SORT_ACTIVITY;
            break;
        case SORT_SIZE_TAG:
            sortType = SORT_SIZE;
            break;
        default:
            NSAssert1(NO, @"Unknown sort tag received: %d", [sender tag]);
            return;
    }

    [fDefaults setObject: sortType forKey: @"Sort"];
    [self applyFilter]; //better than calling sortTorrents because it will even apply to queue order
}

- (void) setSortByGroup: (id) sender
{
    BOOL sortByGroup = ![fDefaults boolForKey: @"SortByGroup"];
    [fDefaults setBool: sortByGroup forKey: @"SortByGroup"];

    //expand all groups
    if (sortByGroup)
        [fTableView removeAllCollapsedGroups];

    [self applyFilter];
}

- (void) setSortReverse: (id) sender
{
    const BOOL setReverse = [sender tag] == SORT_DESC_TAG;
    if (setReverse != [fDefaults boolForKey: @"SortReverse"])
    {
        [fDefaults setBool: setReverse forKey: @"SortReverse"];
        [self sortTorrents];
    }
}

- (void) sortTorrents
{
    NSArray * selectedValues = [fTableView selectedValues];

    [self sortTorrentsIgnoreSelected]; //actually sort

    [fTableView selectValues: selectedValues];
}

- (void) sortTorrentsIgnoreSelected
{
    NSString * sortType = [fDefaults stringForKey: @"Sort"];

    if (![sortType isEqualToString: SORT_ORDER])
    {
        const BOOL asc = ![fDefaults boolForKey: @"SortReverse"];

        NSArray * descriptors;
        NSSortDescriptor * nameDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"name" ascending: asc
                                                selector: @selector(compareFinder:)] autorelease];

        if ([sortType isEqualToString: SORT_STATE])
        {
            NSSortDescriptor * stateDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"stateSortKey" ascending: !asc] autorelease],
                            * progressDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"progress" ascending: !asc] autorelease],
                            * ratioDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"ratio" ascending: !asc] autorelease];

            descriptors = [[NSArray alloc] initWithObjects: stateDescriptor, progressDescriptor, ratioDescriptor,
                                                                nameDescriptor, nil];
        }
        else if ([sortType isEqualToString: SORT_PROGRESS])
        {
            NSSortDescriptor * progressDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"progress" ascending: asc] autorelease],
                            * ratioProgressDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"progressStopRatio"
                                                            ascending: asc] autorelease],
                            * ratioDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"ratio" ascending: asc] autorelease];

            descriptors = [[NSArray alloc] initWithObjects: progressDescriptor, ratioProgressDescriptor, ratioDescriptor,
                                                                nameDescriptor, nil];
        }
        else if ([sortType isEqualToString: SORT_TRACKER])
        {
            NSSortDescriptor * trackerDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"trackerSortKey" ascending: asc
                                                    selector: @selector(localizedCaseInsensitiveCompare:)] autorelease];

            descriptors = [[NSArray alloc] initWithObjects: trackerDescriptor, nameDescriptor, nil];
        }
        else if ([sortType isEqualToString: SORT_ACTIVITY])
        {
            NSSortDescriptor * rateDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"totalRate" ascending: !asc] autorelease];
            NSSortDescriptor * activityDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"dateActivityOrAdd" ascending: !asc]
                                                        autorelease];

            descriptors = [[NSArray alloc] initWithObjects: rateDescriptor, activityDescriptor, nameDescriptor, nil];
        }
        else if ([sortType isEqualToString: SORT_DATE])
        {
            NSSortDescriptor * dateDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"dateAdded" ascending: asc] autorelease];

            descriptors = [[NSArray alloc] initWithObjects: dateDescriptor, nameDescriptor, nil];
        }
        else if ([sortType isEqualToString: SORT_SIZE])
        {
            NSSortDescriptor * sizeDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"size" ascending: asc] autorelease];

            descriptors = [[NSArray alloc] initWithObjects: sizeDescriptor, nameDescriptor, nil];
        }
        else
            descriptors = [[NSArray alloc] initWithObjects: nameDescriptor, nil];

        //actually sort
        if ([fDefaults boolForKey: @"SortByGroup"])
        {
            for (TorrentGroup * group in fDisplayedTorrents)
                [[group torrents] sortUsingDescriptors: descriptors];
        }
        else
            [fDisplayedTorrents sortUsingDescriptors: descriptors];

        [descriptors release];
    }

    [fTableView reloadData];
}

- (void) applyFilter
{
    //get all the torrents in the table
    NSMutableArray * previousTorrents;
    if ([fDisplayedTorrents count] > 0 && [[fDisplayedTorrents objectAtIndex: 0] isKindOfClass: [TorrentGroup class]])
    {
        previousTorrents = [NSMutableArray array];

        for (TorrentGroup * group in fDisplayedTorrents)
            [previousTorrents addObjectsFromArray: [group torrents]];
    }
    else
        previousTorrents = fDisplayedTorrents;

    NSArray * selectedValues = [fTableView selectedValues];

    NSUInteger active = 0, downloading = 0, seeding = 0, paused = 0;
    NSString * filterType = [fDefaults stringForKey: @"Filter"];
    BOOL filterActive = NO, filterDownload = NO, filterSeed = NO, filterPause = NO, filterStatus = YES;
    if ([filterType isEqualToString: FILTER_ACTIVE])
        filterActive = YES;
    else if ([filterType isEqualToString: FILTER_DOWNLOAD])
        filterDownload = YES;
    else if ([filterType isEqualToString: FILTER_SEED])
        filterSeed = YES;
    else if ([filterType isEqualToString: FILTER_PAUSE])
        filterPause = YES;
    else
        filterStatus = NO;

    const NSInteger groupFilterValue = [fDefaults integerForKey: @"FilterGroup"];
    const BOOL filterGroup = groupFilterValue != GROUP_FILTER_ALL_TAG;

    NSString * searchString = [fFilterBar searchString];
    if (searchString && [searchString isEqualToString: @""])
        searchString = nil;
    const BOOL filterTracker = searchString && [[fDefaults stringForKey: @"FilterSearchType"] isEqualToString: FILTER_TYPE_TRACKER];

    NSMutableArray * allTorrents = [NSMutableArray arrayWithCapacity: [fTorrents count]];

    //get count of each type
    for (Torrent * torrent in fTorrents)
    {
        //check status
        if ([torrent isActive] && ![torrent isCheckingWaiting])
        {
            const BOOL isActive = ![torrent isStalled];
            if (isActive)
                ++active;

            if ([torrent isSeeding])
            {
                ++seeding;
                if (filterStatus && !((filterActive && isActive) || filterSeed))
                    continue;
            }
            else
            {
                ++downloading;
                if (filterStatus && !((filterActive && isActive) || filterDownload))
                    continue;
            }
        }
        else
        {
            ++paused;
            if (filterStatus && !filterPause)
                continue;
        }

        //checkGroup
        if (filterGroup)
            if ([torrent groupValue] != groupFilterValue)
                continue;

        //check text field
        if (searchString)
        {
            if (filterTracker)
            {
                BOOL removeTextField = YES;
                for (NSString * tracker in [torrent allTrackersFlat])
                {
                    if ([tracker rangeOfString: searchString options:
                            (NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)].location != NSNotFound)
                    {
                        removeTextField = NO;
                        break;
                    }
                }

                if (removeTextField)
                    continue;
            }
            else
            {
                if ([[torrent name] rangeOfString: searchString options:
                        (NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)].location == NSNotFound)
                    continue;
            }
        }

        [allTorrents addObject: torrent];
    }

    //set button tooltips
    if (fFilterBar)
        [fFilterBar setCountAll: [fTorrents count] active: active downloading: downloading seeding: seeding paused: paused];

    //clear display cache for not-shown torrents
    [previousTorrents removeObjectsInArray: allTorrents];
    for (Torrent * torrent in previousTorrents)
        [torrent setPreviousFinishedPieces: nil];

    //place torrents into groups
    const BOOL groupRows = [fDefaults boolForKey: @"SortByGroup"];
    if (groupRows)
    {
        NSMutableArray * oldTorrentGroups = [NSMutableArray array];
        if ([fDisplayedTorrents count] > 0 && [[fDisplayedTorrents objectAtIndex: 0] isKindOfClass: [TorrentGroup class]])
            [oldTorrentGroups addObjectsFromArray: fDisplayedTorrents];

        [fDisplayedTorrents removeAllObjects];

        NSSortDescriptor * groupDescriptor = [[[NSSortDescriptor alloc] initWithKey: @"groupOrderValue" ascending: YES] autorelease];
        [allTorrents sortUsingDescriptors: [NSArray arrayWithObject: groupDescriptor]];

        TorrentGroup * group = nil;
        NSInteger lastGroupValue = -2, currentOldGroupIndex = 0;
        for (Torrent * torrent in allTorrents)
        {
            const NSInteger groupValue = [torrent groupValue];
            if (groupValue != lastGroupValue)
            {
                lastGroupValue = groupValue;

                group = nil;

                //try to see if the group already exists
                for (; currentOldGroupIndex < [oldTorrentGroups count]; ++currentOldGroupIndex)
                {
                    TorrentGroup * currentGroup = [oldTorrentGroups objectAtIndex: currentOldGroupIndex];
                    const NSInteger currentGroupValue = [currentGroup groupIndex];
                    if (currentGroupValue == groupValue)
                    {
                        group = currentGroup;
                        [[currentGroup torrents] removeAllObjects];

                        ++currentOldGroupIndex;
                    }

                    if (currentGroupValue >= groupValue)
                        break;
                }

                if (!group)
                    group = [[[TorrentGroup alloc] initWithGroup: groupValue] autorelease];
                [fDisplayedTorrents addObject: group];
            }

            NSAssert(group != nil, @"No group object to add torrents to");
            [[group torrents] addObject: torrent];
        }
    }
    else
        [fDisplayedTorrents setArray: allTorrents];

    //actually sort
    [self sortTorrentsIgnoreSelected];

    //reset expanded/collapsed rows
    if (groupRows)
    {
        for (TorrentGroup * group in fDisplayedTorrents)
        {
            if ([fTableView isGroupCollapsed: [group groupIndex]])
                [fTableView collapseItem: group];
            else
                [fTableView expandItem: group];
        }
    }

    [fTableView selectValues: selectedValues];
    [self resetInfo]; //if group is already selected, but the torrents in it change

    [self setBottomCountText: groupRows || filterStatus || filterGroup || searchString];

    [self setWindowSizeToFit];
}

- (void) switchFilter: (id) sender
{
    [fFilterBar switchFilter: sender == fNextFilterItem];
}

- (void) menuNeedsUpdate: (NSMenu *) menu
{
    if (menu == fGroupsSetMenu || menu == fGroupsSetContextMenu)
    {
        for (NSInteger i = [menu numberOfItems]-1; i >= 0; i--)
            [menu removeItemAtIndex: i];

        NSMenu * groupMenu = [[GroupsController groups] groupMenuWithTarget: self action: @selector(setGroup:) isSmall: NO];

        const NSInteger groupMenuCount = [groupMenu numberOfItems];
        for (NSInteger i = 0; i < groupMenuCount; i++)
        {
            NSMenuItem * item = [[groupMenu itemAtIndex: 0] retain];
            [groupMenu removeItemAtIndex: 0];
            [menu addItem: item];
            [item release];
        }
    }
    else if (menu == fUploadMenu || menu == fDownloadMenu)
    {
        if ([menu numberOfItems] > 3)
            return;

        const NSInteger speedLimitActionValue[] = { 5, 10, 20, 30, 40, 50, 75, 100, 150, 200, 250, 500, 750, 1000, 1500, 2000, -1 };

        NSMenuItem * item;
        for (NSInteger i = 0; speedLimitActionValue[i] != -1; i++)
        {
            item = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: NSLocalizedString(@"%d KB/s",
                    "Action menu -> upload/download limit"), speedLimitActionValue[i]] action: @selector(setQuickLimitGlobal:)
                    keyEquivalent: @""];
            [item setTarget: self];
            [item setRepresentedObject: [NSNumber numberWithInt: speedLimitActionValue[i]]];
            [menu addItem: item];
            [item release];
        }
    }
    else if (menu == fRatioStopMenu)
    {
        if ([menu numberOfItems] > 3)
            return;

        const float ratioLimitActionValue[] = { 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, -1 };

        NSMenuItem * item;
        for (NSInteger i = 0; ratioLimitActionValue[i] != -1; i++)
        {
            item = [[NSMenuItem alloc] initWithTitle: [NSString localizedStringWithFormat: @"%.2f", ratioLimitActionValue[i]]
                    action: @selector(setQuickRatioGlobal:) keyEquivalent: @""];
            [item setTarget: self];
            [item setRepresentedObject: [NSNumber numberWithFloat: ratioLimitActionValue[i]]];
            [menu addItem: item];
            [item release];
        }
    }
    else;
}

- (void) setGroup: (id) sender
{
    for (Torrent * torrent in [fTableView selectedTorrents])
    {
        [fTableView removeCollapsedGroup: [torrent groupValue]]; //remove old collapsed group

        [torrent setGroupValue: [sender tag]];
    }

    [self applyFilter];
    [self updateUI];
    [self updateTorrentHistory];
}

- (void) toggleSpeedLimit: (id) sender
{
    [fDefaults setBool: ![fDefaults boolForKey: @"SpeedLimit"] forKey: @"SpeedLimit"];
    [self speedLimitChanged: sender];
}

- (void) speedLimitChanged: (id) sender
{
    tr_sessionUseAltSpeed(fLib, [fDefaults boolForKey: @"SpeedLimit"]);
    [fStatusBar updateSpeedFieldsToolTips];
}

//dict has been retained
- (void) altSpeedToggledCallbackIsLimited: (NSDictionary *) dict
{
    const BOOL isLimited = [[dict objectForKey: @"Active"] boolValue];

    [fDefaults setBool: isLimited forKey: @"SpeedLimit"];
    [fStatusBar updateSpeedFieldsToolTips];

    if (![[dict objectForKey: @"ByUser"] boolValue])
        [GrowlApplicationBridge notifyWithTitle: isLimited
                ? NSLocalizedString(@"Speed Limit Auto Enabled", "Growl notification title")
                : NSLocalizedString(@"Speed Limit Auto Disabled", "Growl notification title")
            description: NSLocalizedString(@"Bandwidth settings changed", "Growl notification description")
            notificationName: GROWL_AUTO_SPEED_LIMIT iconData: nil priority: 0 isSticky: NO clickContext: nil];

    [dict release];
}

- (void) setLimitGlobalEnabled: (id) sender
{
    BOOL upload = [sender menu] == fUploadMenu;
    [fDefaults setBool: sender == (upload ? fUploadLimitItem : fDownloadLimitItem) forKey: upload ? @"CheckUpload" : @"CheckDownload"];

    [fPrefsController applySpeedSettings: nil];
}

- (void) setQuickLimitGlobal: (id) sender
{
    BOOL upload = [sender menu] == fUploadMenu;
    [fDefaults setInteger: [[sender representedObject] intValue] forKey: upload ? @"UploadLimit" : @"DownloadLimit"];
    [fDefaults setBool: YES forKey: upload ? @"CheckUpload" : @"CheckDownload"];

    [fPrefsController updateLimitFields];
    [fPrefsController applySpeedSettings: nil];
}

- (void) setRatioGlobalEnabled: (id) sender
{
    [fDefaults setBool: sender == fCheckRatioItem forKey: @"RatioCheck"];

    [fPrefsController applyRatioSetting: nil];
}

- (void) setQuickRatioGlobal: (id) sender
{
    [fDefaults setBool: YES forKey: @"RatioCheck"];
    [fDefaults setFloat: [[sender representedObject] floatValue] forKey: @"RatioLimit"];

    [fPrefsController updateRatioStopField];
}

- (void) sound: (NSSound *) sound didFinishPlaying: (BOOL) finishedPlaying
{
    fSoundPlaying = NO;
}

- (void) watcher: (id<UKFileWatcher>) watcher receivedNotification: (NSString *) notification forPath: (NSString *) path
{
    if ([notification isEqualToString: UKFileWatcherWriteNotification])
    {
        if (![fDefaults boolForKey: @"AutoImport"] || ![fDefaults stringForKey: @"AutoImportDirectory"])
            return;

        if (fAutoImportTimer)
        {
            if ([fAutoImportTimer isValid])
                [fAutoImportTimer invalidate];
            [fAutoImportTimer release];
            fAutoImportTimer = nil;
        }

        //check again in 10 seconds in case torrent file wasn't complete
        fAutoImportTimer = [[NSTimer scheduledTimerWithTimeInterval: 10.0 target: self
            selector: @selector(checkAutoImportDirectory) userInfo: nil repeats: NO] retain];

        [self checkAutoImportDirectory];
    }
}

- (void) changeAutoImport
{
    if (fAutoImportTimer)
    {
        if ([fAutoImportTimer isValid])
            [fAutoImportTimer invalidate];
        [fAutoImportTimer release];
        fAutoImportTimer = nil;
    }

    if (fAutoImportedNames)
    {
        [fAutoImportedNames release];
        fAutoImportedNames = nil;
    }

    [self checkAutoImportDirectory];
}

- (void) checkAutoImportDirectory
{
    NSString * path;
    if (![fDefaults boolForKey: @"AutoImport"] || !(path = [fDefaults stringForKey: @"AutoImportDirectory"]))
        return;

    path = [path stringByExpandingTildeInPath];

    NSArray * importedNames;
    if (!(importedNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: path error: NULL]))
        return;

    //only check files that have not been checked yet
    NSMutableArray * newNames = [importedNames mutableCopy];

    if (fAutoImportedNames)
        [newNames removeObjectsInArray: fAutoImportedNames];
    else
        fAutoImportedNames = [[NSMutableArray alloc] init];
    [fAutoImportedNames setArray: importedNames];

    for (NSString * file in newNames)
    {
        if ([file hasPrefix: @"."])
            continue;

        NSString * fullFile = [path stringByAppendingPathComponent: file];

        if (!([[[NSWorkspace sharedWorkspace] typeOfFile: fullFile error: NULL] isEqualToString: @"org.bittorrent.torrent"]
                || [[fullFile pathExtension] caseInsensitiveCompare: @"torrent"] == NSOrderedSame))
            continue;

        tr_ctor * ctor = tr_ctorNew(fLib);
        tr_ctorSetMetainfoFromFile(ctor, [fullFile UTF8String]);

        switch (tr_torrentParse(ctor, NULL))
        {
            case TR_PARSE_OK:
                [self openFiles: [NSArray arrayWithObject: fullFile] addType: ADD_AUTO forcePath: nil];

                [GrowlApplicationBridge notifyWithTitle: NSLocalizedString(@"Torrent File Auto Added", "Growl notification title")
                    description: file notificationName: GROWL_AUTO_ADD iconData: nil priority: 0 isSticky: NO
                    clickContext: nil];
                break;

            case TR_PARSE_ERR:
                [fAutoImportedNames removeObject: file];
                break;

            case TR_PARSE_DUPLICATE: //let's ignore this (but silence a warning)
                break;
        }

        tr_ctorFree(ctor);
    }

    [newNames release];
}

- (void) beginCreateFile: (NSNotification *) notification
{
    if (![fDefaults boolForKey: @"AutoImport"])
        return;

    NSString * location = [notification object],
            * path = [fDefaults stringForKey: @"AutoImportDirectory"];

    if (location && path && [[[location stringByDeletingLastPathComponent] stringByExpandingTildeInPath]
                                    isEqualToString: [path stringByExpandingTildeInPath]])
        [fAutoImportedNames addObject: [location lastPathComponent]];
}

- (NSInteger) outlineView: (NSOutlineView *) outlineView numberOfChildrenOfItem: (id) item
{
    if (item)
        return [[item torrents] count];
    else
        return [fDisplayedTorrents count];
}

- (id) outlineView: (NSOutlineView *) outlineView child: (NSInteger) index ofItem: (id) item
{
    if (item)
        return [[item torrents] objectAtIndex: index];
    else
        return [fDisplayedTorrents objectAtIndex: index];
}

- (BOOL) outlineView: (NSOutlineView *) outlineView isItemExpandable: (id) item
{
    return ![item isKindOfClass: [Torrent class]];
}

- (id) outlineView: (NSOutlineView *) outlineView objectValueForTableColumn: (NSTableColumn *) tableColumn byItem: (id) item
{
    if ([item isKindOfClass: [Torrent class]]) {
        if (tableColumn)
            return nil;
        return [item hashString];
    }
    else
    {
        NSString * ident = [tableColumn identifier];
        if ([ident isEqualToString: @"Group"])
        {
            NSInteger group = [item groupIndex];
            return group != -1 ? [[GroupsController groups] nameForIndex: group]
                                : NSLocalizedString(@"No Group", "Group table row");
        }
        else if ([ident isEqualToString: @"Color"])
        {
            NSInteger group = [item groupIndex];
            return [[GroupsController groups] imageForIndex: group];
        }
        else if ([ident isEqualToString: @"DL Image"])
            return [NSImage imageNamed: @"DownArrowGroupTemplate.png"];
        else if ([ident isEqualToString: @"UL Image"])
            return [NSImage imageNamed: [fDefaults boolForKey: @"DisplayGroupRowRatio"]
                                        ? @"YingYangGroupTemplate.png" : @"UpArrowGroupTemplate.png"];
        else
        {
            TorrentGroup * group = (TorrentGroup *)item;

            if ([fDefaults boolForKey: @"DisplayGroupRowRatio"])
                return [NSString stringForRatio: [group ratio]];
            else
            {
                CGFloat rate = [ident isEqualToString: @"UL"] ? [group uploadRate] : [group downloadRate];
                return [NSString stringForSpeed: rate];
            }
        }
    }
}

- (BOOL) outlineView: (NSOutlineView *) outlineView writeItems: (NSArray *) items toPasteboard: (NSPasteboard *) pasteboard
{
    //only allow reordering of rows if sorting by order
    if ([fDefaults boolForKey: @"SortByGroup"] || [[fDefaults stringForKey: @"Sort"] isEqualToString: SORT_ORDER])
    {
        NSMutableIndexSet * indexSet = [NSMutableIndexSet indexSet];
        for (id torrent in items)
        {
            if (![torrent isKindOfClass: [Torrent class]])
                return NO;

            [indexSet addIndex: [fTableView rowForItem: torrent]];
        }

        [pasteboard declareTypes: [NSArray arrayWithObject: TORRENT_TABLE_VIEW_DATA_TYPE] owner: self];
        [pasteboard setData: [NSKeyedArchiver archivedDataWithRootObject: indexSet] forType: TORRENT_TABLE_VIEW_DATA_TYPE];
        return YES;
    }
    return NO;
}

- (NSDragOperation) outlineView: (NSOutlineView *) outlineView validateDrop: (id < NSDraggingInfo >) info proposedItem: (id) item
    proposedChildIndex: (NSInteger) index
{
    NSPasteboard * pasteboard = [info draggingPasteboard];
    if ([[pasteboard types] containsObject: TORRENT_TABLE_VIEW_DATA_TYPE])
    {
        if ([fDefaults boolForKey: @"SortByGroup"])
        {
            if (!item)
                return NSDragOperationNone;

            if ([[fDefaults stringForKey: @"Sort"] isEqualToString: SORT_ORDER])
            {
                if ([item isKindOfClass: [Torrent class]])
                {
                    TorrentGroup * group = [fTableView parentForItem: item];
                    index = [[group torrents] indexOfObject: item] + 1;
                    item = group;
                }
            }
            else
            {
                if ([item isKindOfClass: [Torrent class]])
                    item = [fTableView parentForItem: item];
                index = NSOutlineViewDropOnItemIndex;
            }
        }
        else
        {
            if (item)
            {
                index = [fTableView rowForItem: item] + 1;
                item = nil;
            }
        }

        [fTableView setDropItem: item dropChildIndex: index];
        return NSDragOperationGeneric;
    }

    return NSDragOperationNone;
}

- (BOOL) outlineView: (NSOutlineView *) outlineView acceptDrop: (id < NSDraggingInfo >) info item: (id) item
    childIndex: (NSInteger) newRow
{
    NSPasteboard * pasteboard = [info draggingPasteboard];
    if ([[pasteboard types] containsObject: TORRENT_TABLE_VIEW_DATA_TYPE])
    {
        //remember selected rows
        NSArray * selectedValues = [fTableView selectedValues];

        NSIndexSet * indexes = [NSKeyedUnarchiver unarchiveObjectWithData: [pasteboard dataForType: TORRENT_TABLE_VIEW_DATA_TYPE]];

        //get the torrents to move
        NSMutableArray * movingTorrents = [NSMutableArray arrayWithCapacity: [indexes count]];
        for (NSUInteger i = [indexes firstIndex]; i != NSNotFound; i = [indexes indexGreaterThanIndex: i])
            [movingTorrents addObject: [fTableView itemAtRow: i]];

        //reset groups
        if (item)
        {
            //change groups
            NSInteger groupValue = [item groupIndex];
            for (Torrent * torrent in movingTorrents)
            {
                //have to reset objects here to avoid weird crash
                [[[fTableView parentForItem: torrent] torrents] removeObject: torrent];
                [[item torrents] addObject: torrent];

                [torrent setGroupValue: groupValue];
            }
            //part 2 of avoiding weird crash
            [fTableView reloadItem: nil reloadChildren: YES];
        }

        //reorder queue order
        if (newRow != NSOutlineViewDropOnItemIndex)
        {
            //find torrent to place under
            NSArray * groupTorrents = item ? [item torrents] : fDisplayedTorrents;
            Torrent * topTorrent = nil;
            for (NSInteger i = newRow-1; i >= 0; i--)
            {
                Torrent * tempTorrent = [groupTorrents objectAtIndex: i];
                if (![movingTorrents containsObject: tempTorrent])
                {
                    topTorrent = tempTorrent;
                    break;
                }
            }

            //remove objects to reinsert
            [fTorrents removeObjectsInArray: movingTorrents];

            //insert objects at new location
            NSUInteger insertIndex = topTorrent ? [fTorrents indexOfObject: topTorrent] + 1 : 0;
            NSIndexSet * insertIndexes = [NSIndexSet indexSetWithIndexesInRange: NSMakeRange(insertIndex, [movingTorrents count])];
            [fTorrents insertObjects: movingTorrents atIndexes: insertIndexes];
        }

        [self applyFilter];
        [fTableView selectValues: selectedValues];
    }

    return YES;
}

- (void) torrentTableViewSelectionDidChange: (NSNotification *) notification
{
    [self resetInfo];
    [[fWindow toolbar] validateVisibleItems];
}

- (NSDragOperation) draggingEntered: (id <NSDraggingInfo>) info
{
    NSPasteboard * pasteboard = [info draggingPasteboard];
    if ([[pasteboard types] containsObject: NSFilenamesPboardType])
    {
        //check if any torrent files can be added
        BOOL torrent = NO;
        NSArray * files = [pasteboard propertyListForType: NSFilenamesPboardType];
        for (NSString * file in files)
        {
            if ([[[NSWorkspace sharedWorkspace] typeOfFile: file error: NULL] isEqualToString: @"org.bittorrent.torrent"]
                    || [[file pathExtension] caseInsensitiveCompare: @"torrent"] == NSOrderedSame)
            {
                torrent = YES;
                tr_ctor * ctor = tr_ctorNew(fLib);
                tr_ctorSetMetainfoFromFile(ctor, [file UTF8String]);
                if (tr_torrentParse(ctor, NULL) == TR_PARSE_OK)
                {
                    if (!fOverlayWindow)
                        fOverlayWindow = [[DragOverlayWindow alloc] initWithLib: fLib forWindow: fWindow];
                    [fOverlayWindow setTorrents: files];

                    return NSDragOperationCopy;
                }
                tr_ctorFree(ctor);
            }
        }

        //create a torrent file if a single file
        if (!torrent && [files count] == 1)
        {
            if (!fOverlayWindow)
                fOverlayWindow = [[DragOverlayWindow alloc] initWithLib: fLib forWindow: fWindow];
            [fOverlayWindow setFile: [[files objectAtIndex: 0] lastPathComponent]];

            return NSDragOperationCopy;
        }
    }
    else if ([[pasteboard types] containsObject: NSURLPboardType])
    {
        if (!fOverlayWindow)
            fOverlayWindow = [[DragOverlayWindow alloc] initWithLib: fLib forWindow: fWindow];
        [fOverlayWindow setURL: [[NSURL URLFromPasteboard: pasteboard] relativeString]];

        return NSDragOperationCopy;
    }
    else;

    return NSDragOperationNone;
}

- (void) draggingExited: (id <NSDraggingInfo>) info
{
    if (fOverlayWindow)
        [fOverlayWindow fadeOut];
}

- (BOOL) performDragOperation: (id <NSDraggingInfo>) info
{
    if (fOverlayWindow)
        [fOverlayWindow fadeOut];

    NSPasteboard * pasteboard = [info draggingPasteboard];
    if ([[pasteboard types] containsObject: NSFilenamesPboardType])
    {
        BOOL torrent = NO, accept = YES;

        //create an array of files that can be opened
        NSArray * files = [pasteboard propertyListForType: NSFilenamesPboardType];
        NSMutableArray * filesToOpen = [NSMutableArray arrayWithCapacity: [files count]];
        for (NSString * file in files)
        {
            if ([[[NSWorkspace sharedWorkspace] typeOfFile: file error: NULL] isEqualToString: @"org.bittorrent.torrent"]
                    || [[file pathExtension] caseInsensitiveCompare: @"torrent"] == NSOrderedSame)
            {
                torrent = YES;
                tr_ctor * ctor = tr_ctorNew(fLib);
                tr_ctorSetMetainfoFromFile(ctor, [file UTF8String]);
                if (tr_torrentParse(ctor, NULL) == TR_PARSE_OK)
                    [filesToOpen addObject: file];
                tr_ctorFree(ctor);
            }
        }

        if ([filesToOpen count] > 0)
            [self application: NSApp openFiles: filesToOpen];
        else
        {
            if (!torrent && [files count] == 1)
                [CreatorWindowController createTorrentFile: fLib forFile: [files objectAtIndex: 0]];
            else
                accept = NO;
        }

        return accept;
    }
    else if ([[pasteboard types] containsObject: NSURLPboardType])
    {
        NSURL * url;
        if ((url = [NSURL URLFromPasteboard: pasteboard]))
        {
            [self openURL: [url absoluteString]];
            return YES;
        }
    }
    else;

    return NO;
}

- (void) toggleSmallView: (id) sender
{
    BOOL makeSmall = ![fDefaults boolForKey: @"SmallView"];
    [fDefaults setBool: makeSmall forKey: @"SmallView"];

    [fTableView setUsesAlternatingRowBackgroundColors: !makeSmall];

    [fTableView setRowHeight: makeSmall ? ROW_HEIGHT_SMALL : ROW_HEIGHT_REGULAR];

    [fTableView noteHeightOfRowsWithIndexesChanged: [NSIndexSet indexSetWithIndexesInRange: NSMakeRange(0, [fTableView numberOfRows])]];

    //resize for larger min height if not set to auto size
    if (![fDefaults boolForKey: @"AutoSize"])
    {
        const NSSize contentSize = [[fWindow contentView] frame].size;

        NSSize contentMinSize = [fWindow contentMinSize];
        contentMinSize.height = [self minWindowContentSizeAllowed];
        [fWindow setContentMinSize: contentMinSize];

        //make sure the window already isn't too small
        if (!makeSmall && contentSize.height < contentMinSize.height)
        {
            NSRect frame = [fWindow frame];
            CGFloat heightChange = contentMinSize.height - contentSize.height;
            frame.size.height += heightChange;
            frame.origin.y -= heightChange;

            [fWindow setFrame: frame display: YES];
        }
    }
    else
        [self setWindowSizeToFit];
}

- (void) togglePiecesBar: (id) sender
{
    [fDefaults setBool: ![fDefaults boolForKey: @"PiecesBar"] forKey: @"PiecesBar"];
    [fTableView togglePiecesBar];
}

- (void) toggleAvailabilityBar: (id) sender
{
    [fDefaults setBool: ![fDefaults boolForKey: @"DisplayProgressBarAvailable"] forKey: @"DisplayProgressBarAvailable"];
    [fTableView display];
}

- (void) toggleStatusString: (id) sender
{
    if ([fDefaults boolForKey: @"SmallView"])
        [fDefaults setBool: ![fDefaults boolForKey: @"DisplaySmallStatusRegular"] forKey: @"DisplaySmallStatusRegular"];
    else
        [fDefaults setBool: ![fDefaults boolForKey: @"DisplayStatusProgressSelected"] forKey: @"DisplayStatusProgressSelected"];

    [fTableView reloadData];
}

- (NSRect) windowFrameByAddingHeight: (CGFloat) height checkLimits: (BOOL) check
{
    NSScrollView * scrollView = [fTableView enclosingScrollView];

    //convert pixels to points
    NSRect windowFrame = [fWindow frame];
    NSSize windowSize = [scrollView convertSize: windowFrame.size fromView: nil];
    windowSize.height += height;

    if (check)
    {
        //we can't call minSize, since it might be set to the current size (auto size)
        const CGFloat minHeight = [self minWindowContentSizeAllowed]
                                    + (NSHeight([fWindow frame]) - NSHeight([[fWindow contentView] frame])); //contentView to window

        if (windowSize.height < minHeight)
            windowSize.height =minHeight;
        else
        {
            NSSize maxSize = [scrollView convertSize: [[fWindow screen] visibleFrame].size fromView: nil];
            if (!fStatusBar)
                maxSize.height -= STATUS_BAR_HEIGHT;
            if (!fFilterBar)
                maxSize.height -= FILTER_BAR_HEIGHT;
            if (windowSize.height > maxSize.height)
                windowSize.height = maxSize.height;
        }
    }

    //convert points to pixels
    windowSize = [scrollView convertSize: windowSize toView: nil];

    windowFrame.origin.y -= (windowSize.height - windowFrame.size.height);
    windowFrame.size.height = windowSize.height;
    return windowFrame;
}

- (void) toggleStatusBar: (id) sender
{
    const BOOL show = fStatusBar == nil;
    [self showStatusBar: show animate: YES];
    [fDefaults setBool: show forKey: @"StatusBar"];
}

//doesn't save shown state
- (void) showStatusBar: (BOOL) show animate: (BOOL) animate
{
    const BOOL prevShown = fStatusBar != nil;
    if (show == prevShown)
        return;

    if (show)
    {
        fStatusBar = [[StatusBarController alloc] initWithLib: fLib];

        NSView * contentView = [fWindow contentView];
        const NSSize windowSize = [contentView convertSize: [fWindow frame].size fromView: nil];

        NSRect statusBarFrame = [[fStatusBar view] frame];
        statusBarFrame.size.width = windowSize.width;
        [[fStatusBar view] setFrame: statusBarFrame];

        [contentView addSubview: [fStatusBar view]];
        [[fStatusBar view] setFrameOrigin: NSMakePoint(0.0, NSMaxY([contentView frame]))];
    }

    NSRect frame;
    CGFloat heightChange = [[fStatusBar view] frame].size.height;
    if (!show)
        heightChange *= -1;

    //allow bar to show even if not enough room
    if (show && ![fDefaults boolForKey: @"AutoSize"])
    {
        frame = [self windowFrameByAddingHeight: heightChange checkLimits: NO];
        CGFloat change = [[fWindow screen] visibleFrame].size.height - frame.size.height;
        if (change < 0.0)
        {
            frame = [fWindow frame];
            frame.size.height += change;
            frame.origin.y -= change;
            [fWindow setFrame: frame display: NO animate: NO];
        }
    }

    [self updateUI];

    NSScrollView * scrollView = [fTableView enclosingScrollView];

    //set views to not autoresize
    const NSUInteger statsMask = [[fStatusBar view] autoresizingMask];
    [[fStatusBar view] setAutoresizingMask: NSViewNotSizable];
    NSUInteger filterMask;
    if (fFilterBar)
    {
        filterMask = [[fFilterBar view] autoresizingMask];
        [[fFilterBar view] setAutoresizingMask: NSViewNotSizable];
    }
    const NSUInteger scrollMask = [scrollView autoresizingMask];
    [scrollView setAutoresizingMask: NSViewNotSizable];

    frame = [self windowFrameByAddingHeight: heightChange checkLimits: NO];
    [fWindow setFrame: frame display: YES animate: animate];

    //re-enable autoresize
    [[fStatusBar view] setAutoresizingMask: statsMask];
    if (fFilterBar)
        [[fFilterBar view] setAutoresizingMask: filterMask];
    [scrollView setAutoresizingMask: scrollMask];

    if (!show)
    {
        [[fStatusBar view] removeFromSuperviewWithoutNeedingDisplay];
        [fStatusBar release];
        fStatusBar = nil;
    }

    if ([fDefaults boolForKey: @"AutoSize"])
        [self setWindowMinMaxToCurrent];
    else
    {
        //change min size
        NSSize minSize = [fWindow contentMinSize];
        minSize.height += heightChange;
        [fWindow setContentMinSize: minSize];
    }
}

- (void) toggleFilterBar: (id) sender
{
    const BOOL show = fFilterBar == nil;

    [self showFilterBar: show animate: YES];
    [fDefaults setBool: show forKey: @"FilterBar"];
    [[fWindow toolbar] validateVisibleItems];

    //disable filtering when hiding
    if (!show)
    {
        [[NSUserDefaults standardUserDefaults] setObject: FILTER_NONE forKey: @"Filter"];
        [[NSUserDefaults standardUserDefaults] setInteger: GROUP_FILTER_ALL_TAG forKey: @"FilterGroup"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey: @"FilterSearchString"];
    }

    [self applyFilter]; //do even if showing to ensure tooltips are updated
}

//doesn't save shown state
- (void) showFilterBar: (BOOL) show animate: (BOOL) animate
{
    const BOOL prevShown = fFilterBar != nil;
    if (show == prevShown)
        return;

    if (show)
    {
        fFilterBar = [[FilterBarController alloc] init];

        NSView * contentView = [fWindow contentView];
        const NSSize windowSize = [contentView convertSize: [fWindow frame].size fromView: nil];

        NSRect filterBarFrame = [[fFilterBar view] frame];
        filterBarFrame.size.width = windowSize.width;
        [[fFilterBar view] setFrame: filterBarFrame];

        if (fStatusBar)
            [contentView addSubview: [fFilterBar view] positioned: NSWindowBelow relativeTo: [fStatusBar view]];
        else
            [contentView addSubview: [fFilterBar view]];
        const CGFloat originY = fStatusBar ? NSMinY([[fStatusBar view] frame]) : NSMaxY([contentView frame]);
        [[fFilterBar view] setFrameOrigin: NSMakePoint(0.0, originY)];
    }
    else
        [fWindow makeFirstResponder: fTableView];

    CGFloat heightChange = NSHeight([[fFilterBar view] frame]);
    if (!show)
        heightChange *= -1;

    //allow bar to show even if not enough room
    if (show && ![fDefaults boolForKey: @"AutoSize"])
    {
        NSRect frame = [self windowFrameByAddingHeight: heightChange checkLimits: NO];
        const CGFloat change = NSHeight([[fWindow screen] visibleFrame]) - NSHeight(frame);
        if (change < 0.0)
        {
            frame = [fWindow frame];
            frame.size.height += change;
            frame.origin.y -= change;
            [fWindow setFrame: frame display: NO animate: NO];
        }
    }

    NSScrollView * scrollView = [fTableView enclosingScrollView];

    //set views to not autoresize
    const NSUInteger filterMask = [[fFilterBar view] autoresizingMask];
    const NSUInteger scrollMask = [scrollView autoresizingMask];
    [[fFilterBar view] setAutoresizingMask: NSViewNotSizable];
    [scrollView setAutoresizingMask: NSViewNotSizable];

    const NSRect frame = [self windowFrameByAddingHeight: heightChange checkLimits: NO];
    [fWindow setFrame: frame display: YES animate: animate];

    //re-enable autoresize
    [[fFilterBar view] setAutoresizingMask: filterMask];
    [scrollView setAutoresizingMask: scrollMask];

    if (!show)
    {
        [[fFilterBar view] removeFromSuperviewWithoutNeedingDisplay];
        [fFilterBar release];
        fFilterBar = nil;
    }

    if ([fDefaults boolForKey: @"AutoSize"])
        [self setWindowMinMaxToCurrent];
    else
    {
        //change min size
        NSSize minSize = [fWindow contentMinSize];
        minSize.height += heightChange;
        [fWindow setContentMinSize: minSize];
    }
}

- (void) focusFilterField
{
    if (!fFilterBar)
        [self toggleFilterBar: self];
    [fFilterBar focusSearchField];
}

#warning change from id to QLPreviewPanel
- (BOOL) acceptsPreviewPanelControl: (id) panel
{
    return !fQuitting;
}

- (void) beginPreviewPanelControl: (id) panel
{
    fPreviewPanel = [panel retain];
    [fPreviewPanel setDelegate: self];
    [fPreviewPanel setDataSource: self];
}

- (void) endPreviewPanelControl: (id) panel
{
    [fPreviewPanel release];
    fPreviewPanel = nil;
}

- (NSArray *) quickLookableTorrents
{
    NSArray * selectedTorrents = [fTableView selectedTorrents];
    NSMutableArray * qlArray = [NSMutableArray arrayWithCapacity: [selectedTorrents count]];

    for (Torrent * torrent in selectedTorrents)
        if (([torrent isFolder] || [torrent isComplete]) && [torrent dataLocation])
            [qlArray addObject: torrent];

    return qlArray;
}

- (NSInteger) numberOfPreviewItemsInPreviewPanel: (id) panel
{
    if ([fInfoController canQuickLook])
        return [[fInfoController quickLookURLs] count];
    else
        return [[self quickLookableTorrents] count];
}

- (id /*<QLPreviewItem>*/) previewPanel: (id) panel previewItemAtIndex: (NSInteger) index
{
    if ([fInfoController canQuickLook])
        return [[fInfoController quickLookURLs] objectAtIndex: index];
    else
        return [[self quickLookableTorrents] objectAtIndex: index];
}

- (BOOL) previewPanel: (id) panel handleEvent: (NSEvent *) event
{
    /*if ([event type] == NSKeyDown)
    {
        [super keyDown: event];
        return YES;
    }*/

    return NO;
}

- (NSRect) previewPanel: (id) panel sourceFrameOnScreenForPreviewItem: (id /*<QLPreviewItem>*/) item
{
    if ([fInfoController canQuickLook])
        return [fInfoController quickLookSourceFrameForPreviewItem: item];
    else
    {
        if (![fWindow isVisible])
            return NSZeroRect;

        const NSInteger row = [fTableView rowForItem: item];
        if (row == -1)
            return NSZeroRect;

        NSRect frame = [fTableView iconRectForRow: row];

        if (!NSIntersectsRect([fTableView visibleRect], frame))
            return NSZeroRect;

        frame.origin = [fTableView convertPoint: frame.origin toView: nil];
        frame.origin = [fWindow convertBaseToScreen: frame.origin];
        frame.origin.y -= frame.size.height;
        return frame;
    }
}

- (ButtonToolbarItem *) standardToolbarButtonWithIdentifier: (NSString *) ident
{
    ButtonToolbarItem * item = [[ButtonToolbarItem alloc] initWithItemIdentifier: ident];

    NSButton * button = [[NSButton alloc] init];
    [button setBezelStyle: NSTexturedRoundedBezelStyle];
    [button setStringValue: @""];

    [item setView: button];
    [button release];

    const NSSize buttonSize = NSMakeSize(36.0, 25.0);
    [item setMinSize: buttonSize];
    [item setMaxSize: buttonSize];

    return [item autorelease];
}

- (NSToolbarItem *) toolbar: (NSToolbar *) toolbar itemForItemIdentifier: (NSString *) ident willBeInsertedIntoToolbar: (BOOL) flag
{
    if ([ident isEqualToString: TOOLBAR_CREATE])
    {
        ButtonToolbarItem * item = [self standardToolbarButtonWithIdentifier: ident];

        [item setLabel: NSLocalizedString(@"Create", "Create toolbar item -> label")];
        [item setPaletteLabel: NSLocalizedString(@"Create Torrent File", "Create toolbar item -> palette label")];
        [item setToolTip: NSLocalizedString(@"Create torrent file", "Create toolbar item -> tooltip")];
        [item setImage: [NSImage imageNamed: @"ToolbarCreateTemplate.png"]];
        [item setTarget: self];
        [item setAction: @selector(createFile:)];
        [item setAutovalidates: NO];

        return item;
    }
    else if ([ident isEqualToString: TOOLBAR_OPEN_FILE])
    {
        ButtonToolbarItem * item = [self standardToolbarButtonWithIdentifier: ident];

        [item setLabel: NSLocalizedString(@"Open", "Open toolbar item -> label")];
        [item setPaletteLabel: NSLocalizedString(@"Open Torrent Files", "Open toolbar item -> palette label")];
        [item setToolTip: NSLocalizedString(@"Open torrent files", "Open toolbar item -> tooltip")];
        [item setImage: [NSImage imageNamed: @"ToolbarOpenTemplate.png"]];
        [item setTarget: self];
        [item setAction: @selector(openShowSheet:)];
        [item setAutovalidates: NO];

        return item;
    }
    else if ([ident isEqualToString: TOOLBAR_OPEN_WEB])
    {
        ButtonToolbarItem * item = [self standardToolbarButtonWithIdentifier: ident];

        [item setLabel: NSLocalizedString(@"Open Address", "Open address toolbar item -> label")];
        [item setPaletteLabel: NSLocalizedString(@"Open Torrent Address", "Open address toolbar item -> palette label")];
        [item setToolTip: NSLocalizedString(@"Open torrent web address", "Open address toolbar item -> tooltip")];
        [item setImage: [NSImage imageNamed: @"ToolbarOpenWebTemplate.png"]];
        [item setTarget: self];
        [item setAction: @selector(openURLShowSheet:)];
        [item setAutovalidates: NO];

        return item;
    }
    else if ([ident isEqualToString: TOOLBAR_REMOVE])
    {
        ButtonToolbarItem * item = [self standardToolbarButtonWithIdentifier: ident];

        [item setLabel: NSLocalizedString(@"Remove", "Remove toolbar item -> label")];
        [item setPaletteLabel: NSLocalizedString(@"Remove Selected", "Remove toolbar item -> palette label")];
        [item setToolTip: NSLocalizedString(@"Remove selected transfers", "Remove toolbar item -> tooltip")];
        [item setImage: [NSImage imageNamed: @"ToolbarRemoveTemplate.png"]];
        [item setTarget: self];
        [item setAction: @selector(removeNoDelete:)];
        [item setVisibilityPriority: NSToolbarItemVisibilityPriorityHigh];

        return item;
    }
    else if ([ident isEqualToString: TOOLBAR_INFO])
    {
        ButtonToolbarItem * item = [self standardToolbarButtonWithIdentifier: ident];
        [[(NSButton *)[item view] cell] setShowsStateBy: NSContentsCellMask]; //blue when enabled

        [item setLabel: NSLocalizedString(@"Inspector", "Inspector toolbar item -> label")];
        [item setPaletteLabel: NSLocalizedString(@"Toggle Inspector", "Inspector toolbar item -> palette label")];
        [item setToolTip: NSLocalizedString(@"Toggle the torrent inspector", "Inspector toolbar item -> tooltip")];
        [item setImage: [NSImage imageNamed: @"ToolbarInfoTemplate.png"]];
        [item setTarget: self];
        [item setAction: @selector(showInfo:)];

        return item;
    }
    else if ([ident isEqualToString: TOOLBAR_PAUSE_RESUME_ALL])
    {
        GroupToolbarItem * groupItem = [[GroupToolbarItem alloc] initWithItemIdentifier: ident];

        NSSegmentedControl * segmentedControl = [[NSSegmentedControl alloc] initWithFrame: NSZeroRect];
        [segmentedControl setCell: [[[ToolbarSegmentedCell alloc] init] autorelease]];
        [groupItem setView: segmentedControl];
        NSSegmentedCell * segmentedCell = (NSSegmentedCell *)[segmentedControl cell];

        [segmentedControl setSegmentCount: 2];
        [segmentedCell setTrackingMode: NSSegmentSwitchTrackingMomentary];

        const NSSize groupSize = NSMakeSize(72.0, 25.0);
        [groupItem setMinSize: groupSize];
        [groupItem setMaxSize: groupSize];

        [groupItem setLabel: NSLocalizedString(@"Apply All", "All toolbar item -> label")];
        [groupItem setPaletteLabel: NSLocalizedString(@"Pause / Resume All", "All toolbar item -> palette label")];
        [groupItem setTarget: self];
        [groupItem setAction: @selector(allToolbarClicked:)];

        [groupItem setIdentifiers: [NSArray arrayWithObjects: TOOLBAR_PAUSE_ALL, TOOLBAR_RESUME_ALL, nil]];

        [segmentedCell setTag: TOOLBAR_PAUSE_TAG forSegment: TOOLBAR_PAUSE_TAG];
        [segmentedControl setImage: [NSImage imageNamed: @"ToolbarPauseAllTemplate.png"] forSegment: TOOLBAR_PAUSE_TAG];
        [segmentedCell setToolTip: NSLocalizedString(@"Pause all transfers",
                                    "All toolbar item -> tooltip") forSegment: TOOLBAR_PAUSE_TAG];

        [segmentedCell setTag: TOOLBAR_RESUME_TAG forSegment: TOOLBAR_RESUME_TAG];
        [segmentedControl setImage: [NSImage imageNamed: @"ToolbarResumeAllTemplate.png"] forSegment: TOOLBAR_RESUME_TAG];
        [segmentedCell setToolTip: NSLocalizedString(@"Resume all transfers",
                                    "All toolbar item -> tooltip") forSegment: TOOLBAR_RESUME_TAG];

        [groupItem createMenu: [NSArray arrayWithObjects: NSLocalizedString(@"Pause All", "All toolbar item -> label"),
                                        NSLocalizedString(@"Resume All", "All toolbar item -> label"), nil]];

        [segmentedControl release];

        [groupItem setVisibilityPriority: NSToolbarItemVisibilityPriorityHigh];

        return [groupItem autorelease];
    }
    else if ([ident isEqualToString: TOOLBAR_PAUSE_RESUME_SELECTED])
    {
        GroupToolbarItem * groupItem = [[GroupToolbarItem alloc] initWithItemIdentifier: ident];

        NSSegmentedControl * segmentedControl = [[NSSegmentedControl alloc] initWithFrame: NSZeroRect];
        [segmentedControl setCell: [[[ToolbarSegmentedCell alloc] init] autorelease]];
        [groupItem setView: segmentedControl];
        NSSegmentedCell * segmentedCell = (NSSegmentedCell *)[segmentedControl cell];

        [segmentedControl setSegmentCount: 2];
        [segmentedCell setTrackingMode: NSSegmentSwitchTrackingMomentary];

        const NSSize groupSize = NSMakeSize(72.0, 25.0);
        [groupItem setMinSize: groupSize];
        [groupItem setMaxSize: groupSize];

        [groupItem setLabel: NSLocalizedString(@"Apply Selected", "Selected toolbar item -> label")];
        [groupItem setPaletteLabel: NSLocalizedString(@"Pause / Resume Selected", "Selected toolbar item -> palette label")];
        [groupItem setTarget: self];
        [groupItem setAction: @selector(selectedToolbarClicked:)];

        [groupItem setIdentifiers: [NSArray arrayWithObjects: TOOLBAR_PAUSE_SELECTED, TOOLBAR_RESUME_SELECTED, nil]];

        [segmentedCell setTag: TOOLBAR_PAUSE_TAG forSegment: TOOLBAR_PAUSE_TAG];
        [segmentedControl setImage: [NSImage imageNamed: @"ToolbarPauseSelectedTemplate.png"] forSegment: TOOLBAR_PAUSE_TAG];
        [segmentedCell setToolTip: NSLocalizedString(@"Pause selected transfers",
                                    "Selected toolbar item -> tooltip") forSegment: TOOLBAR_PAUSE_TAG];

        [segmentedCell setTag: TOOLBAR_RESUME_TAG forSegment: TOOLBAR_RESUME_TAG];
        [segmentedControl setImage: [NSImage imageNamed: @"ToolbarResumeSelectedTemplate.png"] forSegment: TOOLBAR_RESUME_TAG];
        [segmentedCell setToolTip: NSLocalizedString(@"Resume selected transfers",
                                    "Selected toolbar item -> tooltip") forSegment: TOOLBAR_RESUME_TAG];

        [groupItem createMenu: [NSArray arrayWithObjects: NSLocalizedString(@"Pause Selected", "Selected toolbar item -> label"),
                                        NSLocalizedString(@"Resume Selected", "Selected toolbar item -> label"), nil]];

        [segmentedControl release];

        [groupItem setVisibilityPriority: NSToolbarItemVisibilityPriorityHigh];

        return [groupItem autorelease];
    }
    else if ([ident isEqualToString: TOOLBAR_FILTER])
    {
        ButtonToolbarItem * item = [self standardToolbarButtonWithIdentifier: ident];
        [[(NSButton *)[item view] cell] setShowsStateBy: NSContentsCellMask]; //blue when enabled

        [item setLabel: NSLocalizedString(@"Filter", "Filter toolbar item -> label")];
        [item setPaletteLabel: NSLocalizedString(@"Toggle Filter", "Filter toolbar item -> palette label")];
        [item setToolTip: NSLocalizedString(@"Toggle the filter bar", "Filter toolbar item -> tooltip")];
        [item setImage: [NSImage imageNamed: @"ToolbarFilterTemplate.png"]];
        [item setTarget: self];
        [item setAction: @selector(toggleFilterBar:)];

        return item;
    }
    else if ([ident isEqualToString: TOOLBAR_QUICKLOOK])
    {
        ButtonToolbarItem * item = [self standardToolbarButtonWithIdentifier: ident];
        [[(NSButton *)[item view] cell] setShowsStateBy: NSContentsCellMask]; //blue when enabled

        [item setLabel: NSLocalizedString(@"Quick Look", "QuickLook toolbar item -> label")];
        [item setPaletteLabel: NSLocalizedString(@"Quick Look", "QuickLook toolbar item -> palette label")];
        [item setToolTip: NSLocalizedString(@"Quick Look", "QuickLook toolbar item -> tooltip")];
        [item setImage: [NSImage imageNamed: NSImageNameQuickLookTemplate]];
        [item setTarget: self];
        [item setAction: @selector(toggleQuickLook:)];
        [item setVisibilityPriority: NSToolbarItemVisibilityPriorityLow];

        return item;
    }
    else
        return nil;
}

- (void) allToolbarClicked: (id) sender
{
    NSInteger tagValue = [sender isKindOfClass: [NSSegmentedControl class]]
                    ? [(NSSegmentedCell *)[sender cell] tagForSegment: [sender selectedSegment]] : [sender tag];
    switch (tagValue)
    {
        case TOOLBAR_PAUSE_TAG:
            [self stopAllTorrents: sender];
            break;
        case TOOLBAR_RESUME_TAG:
            [self resumeAllTorrents: sender];
            break;
    }
}

- (void) selectedToolbarClicked: (id) sender
{
    NSInteger tagValue = [sender isKindOfClass: [NSSegmentedControl class]]
                    ? [(NSSegmentedCell *)[sender cell] tagForSegment: [sender selectedSegment]] : [sender tag];
    switch (tagValue)
    {
        case TOOLBAR_PAUSE_TAG:
            [self stopSelectedTorrents: sender];
            break;
        case TOOLBAR_RESUME_TAG:
            [self resumeSelectedTorrents: sender];
            break;
    }
}

- (NSArray *) toolbarAllowedItemIdentifiers: (NSToolbar *) toolbar
{
    return [NSArray arrayWithObjects:
            TOOLBAR_CREATE, TOOLBAR_OPEN_FILE, TOOLBAR_OPEN_WEB, TOOLBAR_REMOVE,
            TOOLBAR_PAUSE_RESUME_SELECTED, TOOLBAR_PAUSE_RESUME_ALL,
            TOOLBAR_QUICKLOOK, TOOLBAR_FILTER, TOOLBAR_INFO,
            NSToolbarSeparatorItemIdentifier,
            NSToolbarSpaceItemIdentifier,
            NSToolbarFlexibleSpaceItemIdentifier,
            NSToolbarCustomizeToolbarItemIdentifier, nil];
}

- (NSArray *) toolbarDefaultItemIdentifiers: (NSToolbar *) toolbar
{
    return [NSArray arrayWithObjects:
            TOOLBAR_CREATE, TOOLBAR_OPEN_FILE, TOOLBAR_REMOVE, NSToolbarSpaceItemIdentifier,
            TOOLBAR_PAUSE_RESUME_ALL, NSToolbarFlexibleSpaceItemIdentifier,
            TOOLBAR_QUICKLOOK, TOOLBAR_FILTER, TOOLBAR_INFO, nil];
}

- (BOOL) validateToolbarItem: (NSToolbarItem *) toolbarItem
{
    NSString * ident = [toolbarItem itemIdentifier];

    //enable remove item
    if ([ident isEqualToString: TOOLBAR_REMOVE])
        return [fTableView numberOfSelectedRows] > 0;

    //enable pause all item
    if ([ident isEqualToString: TOOLBAR_PAUSE_ALL])
    {
        for (Torrent * torrent in fTorrents)
            if ([torrent isActive] || [torrent waitingToStart])
                return YES;
        return NO;
    }

    //enable resume all item
    if ([ident isEqualToString: TOOLBAR_RESUME_ALL])
    {
        for (Torrent * torrent in fTorrents)
            if (![torrent isActive] && ![torrent waitingToStart])
                return YES;
        return NO;
    }

    //enable pause item
    if ([ident isEqualToString: TOOLBAR_PAUSE_SELECTED])
    {
        for (Torrent * torrent in [fTableView selectedTorrents])
            if ([torrent isActive] || [torrent waitingToStart])
                return YES;
        return NO;
    }

    //enable resume item
    if ([ident isEqualToString: TOOLBAR_RESUME_SELECTED])
    {
        for (Torrent * torrent in [fTableView selectedTorrents])
            if (![torrent isActive] && ![torrent waitingToStart])
                return YES;
        return NO;
    }

    //set info item
    if ([ident isEqualToString: TOOLBAR_INFO])
    {
        [(NSButton *)[toolbarItem view] setState: [[fInfoController window] isVisible]];
        return YES;
    }

    //set filter item
    if ([ident isEqualToString: TOOLBAR_FILTER])
    {
        [(NSButton *)[toolbarItem view] setState: fFilterBar != nil];
        return YES;
    }

    //set quick look item
    if ([ident isEqualToString: TOOLBAR_QUICKLOOK])
    {
        [(NSButton *)[toolbarItem view] setState: [NSApp isOnSnowLeopardOrBetter] && [QLPreviewPanelSL sharedPreviewPanelExists]
                                                    && [[QLPreviewPanelSL sharedPreviewPanel] isVisible]];
        return [NSApp isOnSnowLeopardOrBetter];
    }

    return YES;
}

- (BOOL) validateMenuItem: (NSMenuItem *) menuItem
{
    SEL action = [menuItem action];

    if (action == @selector(toggleSpeedLimit:))
    {
        [menuItem setState: [fDefaults boolForKey: @"SpeedLimit"] ? NSOnState : NSOffState];
        return YES;
    }

    //only enable some items if it is in a context menu or the window is useable
    BOOL canUseTable = [fWindow isKeyWindow] || [[menuItem menu] supermenu] != [NSApp mainMenu];

    //enable open items
    if (action == @selector(openShowSheet:) || action == @selector(openURLShowSheet:))
        return [fWindow attachedSheet] == nil;

    //enable sort options
    if (action == @selector(setSort:))
    {
        NSString * sortType;
        switch ([menuItem tag])
        {
            case SORT_ORDER_TAG:
                sortType = SORT_ORDER;
                break;
            case SORT_DATE_TAG:
                sortType = SORT_DATE;
                break;
            case SORT_NAME_TAG:
                sortType = SORT_NAME;
                break;
            case SORT_PROGRESS_TAG:
                sortType = SORT_PROGRESS;
                break;
            case SORT_STATE_TAG:
                sortType = SORT_STATE;
                break;
            case SORT_TRACKER_TAG:
                sortType = SORT_TRACKER;
                break;
            case SORT_ACTIVITY_TAG:
                sortType = SORT_ACTIVITY;
                break;
            case SORT_SIZE_TAG:
                sortType = SORT_SIZE;
                break;
            default:
                NSAssert1(NO, @"Unknown sort tag received: %d", [menuItem tag]);
        }

        [menuItem setState: [sortType isEqualToString: [fDefaults stringForKey: @"Sort"]] ? NSOnState : NSOffState];
        return [fWindow isVisible];
    }

    if (action == @selector(setGroup:))
    {
        BOOL checked = NO;

        NSInteger index = [menuItem tag];
        for (Torrent * torrent in [fTableView selectedTorrents])
            if (index == [torrent groupValue])
            {
                checked = YES;
                break;
            }

        [menuItem setState: checked ? NSOnState : NSOffState];
        return canUseTable && [fTableView numberOfSelectedRows] > 0;
    }

    if (action == @selector(toggleSmallView:))
    {
        [menuItem setState: [fDefaults boolForKey: @"SmallView"] ? NSOnState : NSOffState];
        return [fWindow isVisible];
    }

    if (action == @selector(togglePiecesBar:))
    {
        [menuItem setState: [fDefaults boolForKey: @"PiecesBar"] ? NSOnState : NSOffState];
        return [fWindow isVisible];
    }

    if (action == @selector(toggleStatusString:))
    {
        if ([fDefaults boolForKey: @"SmallView"])
        {
            [menuItem setTitle: NSLocalizedString(@"Remaining Time", "Action menu -> status string toggle")];
            [menuItem setState: ![fDefaults boolForKey: @"DisplaySmallStatusRegular"] ? NSOnState : NSOffState];
        }
        else
        {
            [menuItem setTitle: NSLocalizedString(@"Status of Selected Files", "Action menu -> status string toggle")];
            [menuItem setState: [fDefaults boolForKey: @"DisplayStatusProgressSelected"] ? NSOnState : NSOffState];
        }

        return [fWindow isVisible];
    }

    if (action == @selector(toggleAvailabilityBar:))
    {
        [menuItem setState: [fDefaults boolForKey: @"DisplayProgressBarAvailable"] ? NSOnState : NSOffState];
        return [fWindow isVisible];
    }

    if (action == @selector(setLimitGlobalEnabled:))
    {
        BOOL upload = [menuItem menu] == fUploadMenu;
        BOOL limit = menuItem == (upload ? fUploadLimitItem : fDownloadLimitItem);
        if (limit)
            [menuItem setTitle: [NSString stringWithFormat: NSLocalizedString(@"Limit (%d KB/s)",
                                    "Action menu -> upload/download limit"),
                                    [fDefaults integerForKey: upload ? @"UploadLimit" : @"DownloadLimit"]]];

        [menuItem setState: [fDefaults boolForKey: upload ? @"CheckUpload" : @"CheckDownload"] ? limit : !limit];
        return YES;
    }

    if (action == @selector(setRatioGlobalEnabled:))
    {
        BOOL check = menuItem == fCheckRatioItem;
        if (check)
            [menuItem setTitle: [NSString localizedStringWithFormat: NSLocalizedString(@"Stop at Ratio (%.2f)",
                                    "Action menu -> ratio stop"), [fDefaults floatForKey: @"RatioLimit"]]];

        [menuItem setState: [fDefaults boolForKey: @"RatioCheck"] ? check : !check];
        return YES;
    }

    //enable show info
    if (action == @selector(showInfo:))
    {
        NSString * title = [[fInfoController window] isVisible] ? NSLocalizedString(@"Hide Inspector", "View menu -> Inspector")
                            : NSLocalizedString(@"Show Inspector", "View menu -> Inspector");
        [menuItem setTitle: title];

        return YES;
    }

    //enable prev/next inspector tab
    if (action == @selector(setInfoTab:))
        return [[fInfoController window] isVisible];

    //enable toggle status bar
    if (action == @selector(toggleStatusBar:))
    {
        NSString * title = !fStatusBar ? NSLocalizedString(@"Show Status Bar", "View menu -> Status Bar")
                            : NSLocalizedString(@"Hide Status Bar", "View menu -> Status Bar");
        [menuItem setTitle: title];

        return [fWindow isVisible];
    }

    //enable toggle filter bar
    if (action == @selector(toggleFilterBar:))
    {
        NSString * title = !fFilterBar ? NSLocalizedString(@"Show Filter Bar", "View menu -> Filter Bar")
                            : NSLocalizedString(@"Hide Filter Bar", "View menu -> Filter Bar");
        [menuItem setTitle: title];

        return [fWindow isVisible];
    }

    //enable prev/next filter button
    if (action == @selector(switchFilter:))
        return [fWindow isVisible] && fFilterBar;

    //enable reveal in finder
    if (action == @selector(revealFile:))
        return canUseTable && [fTableView numberOfSelectedRows] > 0;

    //enable remove items
    if (action == @selector(removeNoDelete:) || action == @selector(removeDeleteData:))
    {
        BOOL warning = NO;

        for (Torrent * torrent in [fTableView selectedTorrents])
        {
            if ([torrent isActive])
            {
                if ([fDefaults boolForKey: @"CheckRemoveDownloading"] ? ![torrent isSeeding] : YES)
                {
                    warning = YES;
                    break;
                }
            }
        }

        //append or remove ellipsis when needed
        NSString * title = [menuItem title], * ellipsis = [NSString ellipsis];
        if (warning && [fDefaults boolForKey: @"CheckRemove"])
        {
            if (![title hasSuffix: ellipsis])
                [menuItem setTitle: [title stringByAppendingEllipsis]];
        }
        else
        {
            if ([title hasSuffix: ellipsis])
                [menuItem setTitle: [title substringToIndex: [title rangeOfString: ellipsis].location]];
        }

        return canUseTable && [fTableView numberOfSelectedRows] > 0;
    }

    //remove all completed transfers item
    if (action == @selector(clearCompleted:))
    {
        //append or remove ellipsis when needed
        NSString * title = [menuItem title], * ellipsis = [NSString ellipsis];
        if ([fDefaults boolForKey: @"WarningRemoveCompleted"])
        {
            if (![title hasSuffix: ellipsis])
                [menuItem setTitle: [title stringByAppendingEllipsis]];
        }
        else
        {
            if ([title hasSuffix: ellipsis])
                [menuItem setTitle: [title substringToIndex: [title rangeOfString: ellipsis].location]];
        }

        for (Torrent * torrent in fTorrents)
            if ([torrent isFinishedSeeding])
                return YES;
        return NO;
    }

    //enable pause all item
    if (action == @selector(stopAllTorrents:))
    {
        for (Torrent * torrent in fTorrents)
            if ([torrent isActive] || [torrent waitingToStart])
                return YES;
        return NO;
    }

    //enable resume all item
    if (action == @selector(resumeAllTorrents:))
    {
        for (Torrent * torrent in fTorrents)
            if (![torrent isActive] && ![torrent waitingToStart] && ![torrent isFinishedSeeding])
                return YES;
        return NO;
    }

    //enable resume all waiting item
    if (action == @selector(resumeWaitingTorrents:))
    {
        if (![fDefaults boolForKey: @"Queue"] && ![fDefaults boolForKey: @"QueueSeed"])
            return NO;

        for (Torrent * torrent in fTorrents)
            if (![torrent isActive] && [torrent waitingToStart])
                return YES;
        return NO;
    }

    //enable resume selected waiting item
    if (action == @selector(resumeSelectedTorrentsNoWait:))
    {
        if (!canUseTable)
            return NO;

        for (Torrent * torrent in [fTableView selectedTorrents])
            if (![torrent isActive])
                return YES;
        return NO;
    }

    //enable pause item
    if (action == @selector(stopSelectedTorrents:))
    {
        if (!canUseTable)
            return NO;

        for (Torrent * torrent in [fTableView selectedTorrents])
            if ([torrent isActive] || [torrent waitingToStart])
                return YES;
        return NO;
    }

    //enable resume item
    if (action == @selector(resumeSelectedTorrents:))
    {
        if (!canUseTable)
            return NO;

        for (Torrent * torrent in [fTableView selectedTorrents])
            if (![torrent isActive] && ![torrent waitingToStart])
                return YES;
        return NO;
    }

    //enable manual announce item
    if (action == @selector(announceSelectedTorrents:))
    {
        if (!canUseTable)
            return NO;

        for (Torrent * torrent in [fTableView selectedTorrents])
            if ([torrent canManualAnnounce])
                return YES;
        return NO;
    }

    //enable reset cache item
    if (action == @selector(verifySelectedTorrents:))
    {
        if (!canUseTable)
            return NO;

        for (Torrent * torrent in [fTableView selectedTorrents])
            if (![torrent isMagnet])
                return YES;
        return NO;
    }

    //enable move torrent file item
    if (action == @selector(moveDataFilesSelected:))
        return canUseTable && [fTableView numberOfSelectedRows] > 0;

    //enable copy torrent file item
    if (action == @selector(copyTorrentFiles:))
    {
        if (!canUseTable)
            return NO;

        for (Torrent * torrent in [fTableView selectedTorrents])
            if (![torrent isMagnet])
                return YES;
        return NO;
    }

    //enable copy torrent file item
    if (action == @selector(copyMagnetLinks:))
        return canUseTable && [fTableView numberOfSelectedRows] > 0;

    //enable reverse sort item
    if (action == @selector(setSortReverse:))
    {
        const BOOL isReverse = [menuItem tag] == SORT_DESC_TAG;
        [menuItem setState: (isReverse == [fDefaults boolForKey: @"SortReverse"]) ? NSOnState : NSOffState];
        return ![[fDefaults stringForKey: @"Sort"] isEqualToString: SORT_ORDER];
    }

    //enable group sort item
    if (action == @selector(setSortByGroup:))
    {
        [menuItem setState: [fDefaults boolForKey: @"SortByGroup"] ? NSOnState : NSOffState];
        return YES;
    }

    if (action == @selector(toggleQuickLook:))
    {
        const BOOL visible = [NSApp isOnSnowLeopardOrBetter] && [QLPreviewPanelSL sharedPreviewPanelExists]
                                && [[QLPreviewPanelSL sharedPreviewPanel] isVisible];
        //text consistent with Finder
        NSString * title = !visible ? NSLocalizedString(@"Quick Look", "View menu -> Quick Look")
                                    : NSLocalizedString(@"Close Quick Look", "View menu -> Quick Look");
        [menuItem setTitle: title];

        return [NSApp isOnSnowLeopardOrBetter];
    }

    return YES;
}

- (void) sleepCallback: (natural_t) messageType argument: (void *) messageArgument
{
    switch (messageType)
    {
        case kIOMessageSystemWillSleep:
            //if there are any running transfers, wait 15 seconds for them to stop
            for (Torrent * torrent in fTorrents)
                if ([torrent isActive])
                {
                    //stop all transfers (since some are active) before going to sleep and remember to resume when we wake up
                    for (Torrent * torrent in fTorrents)
                        [torrent sleep];
                    sleep(15);
                    break;
                }

            IOAllowPowerChange(fRootPort, (long) messageArgument);
            break;

        case kIOMessageCanSystemSleep:
            if ([fDefaults boolForKey: @"SleepPrevent"])
            {
                //prevent idle sleep unless no torrents are active
                for (Torrent * torrent in fTorrents)
                    if ([torrent isActive] && ![torrent isStalled] && ![torrent isError])
                    {
                        IOCancelPowerChange(fRootPort, (long) messageArgument);
                        return;
                    }
            }

            IOAllowPowerChange(fRootPort, (long) messageArgument);
            break;

        case kIOMessageSystemHasPoweredOn:
            //resume sleeping transfers after we wake up
            for (Torrent * torrent in fTorrents)
                [torrent wakeUp];
            break;
    }
}

- (NSMenu *) applicationDockMenu: (NSApplication *) sender
{
    NSInteger seeding = 0, downloading = 0;
    for (Torrent * torrent in fTorrents)
    {
        if ([torrent isSeeding])
            seeding++;
        else if ([torrent isActive])
            downloading++;
        else;
    }

    NSMenuItem * seedingItem = [fDockMenu itemWithTag: DOCK_SEEDING_TAG],
            * downloadingItem = [fDockMenu itemWithTag: DOCK_DOWNLOADING_TAG];

    BOOL hasSeparator = seedingItem || downloadingItem;

    if (seeding > 0)
    {
        NSString * title = [NSString stringWithFormat: NSLocalizedString(@"%d Seeding", "Dock item - Seeding"), seeding];
        if (!seedingItem)
        {
            seedingItem = [[[NSMenuItem alloc] initWithTitle: title action: nil keyEquivalent: @""] autorelease];
            [seedingItem setTag: DOCK_SEEDING_TAG];
            [fDockMenu insertItem: seedingItem atIndex: 0];
        }
        else
            [seedingItem setTitle: title];
    }
    else
    {
        if (seedingItem)
            [fDockMenu removeItem: seedingItem];
    }

    if (downloading > 0)
    {
        NSString * title = [NSString stringWithFormat: NSLocalizedString(@"%d Downloading", "Dock item - Downloading"), downloading];
        if (!downloadingItem)
        {
            downloadingItem = [[[NSMenuItem alloc] initWithTitle: title action: nil keyEquivalent: @""] autorelease];
            [downloadingItem setTag: DOCK_DOWNLOADING_TAG];
            [fDockMenu insertItem: downloadingItem atIndex: seeding > 0 ? 1 : 0];
        }
        else
            [downloadingItem setTitle: title];
    }
    else
    {
        if (downloadingItem)
            [fDockMenu removeItem: downloadingItem];
    }

    if (seeding > 0 || downloading > 0)
    {
        if (!hasSeparator)
            [fDockMenu insertItem: [NSMenuItem separatorItem] atIndex: (seeding > 0 && downloading > 0) ? 2 : 1];
    }
    else
    {
        if (hasSeparator)
            [fDockMenu removeItemAtIndex: 0];
    }

    return fDockMenu;
}

- (NSRect) windowWillUseStandardFrame: (NSWindow *) window defaultFrame: (NSRect) defaultFrame
{
    //if auto size is enabled, the current frame shouldn't need to change
    NSRect frame = [fDefaults boolForKey: @"AutoSize"] ? [window frame] : [self sizedWindowFrame];

    frame.size.width = [fDefaults boolForKey: @"SmallView"] ? [fWindow minSize].width : WINDOW_REGULAR_WIDTH;
    return frame;
}

- (void) setWindowSizeToFit
{
    if ([fDefaults boolForKey: @"AutoSize"])
    {
        NSScrollView * scrollView = [fTableView enclosingScrollView];

        [scrollView setHasVerticalScroller: NO];
        [fWindow setFrame: [self sizedWindowFrame] display: YES animate: YES];
        [scrollView setHasVerticalScroller: YES];

        //hack to ensure scrollbars don't disappear after resizing
        if (![NSApp isOnSnowLeopardOrBetter])
        {
            [scrollView setAutohidesScrollers: NO];
            [scrollView setAutohidesScrollers: YES];
        }

        [self setWindowMinMaxToCurrent];
    }
}

- (NSRect) sizedWindowFrame
{
    NSInteger groups = ([fDisplayedTorrents count] > 0 && ![[fDisplayedTorrents objectAtIndex: 0] isKindOfClass: [Torrent class]])
                    ? [fDisplayedTorrents count] : 0;

    CGFloat heightChange = (GROUP_SEPARATOR_HEIGHT + [fTableView intercellSpacing].height) * groups
                        + ([fTableView rowHeight] + [fTableView intercellSpacing].height) * ([fTableView numberOfRows] - groups)
                        - NSHeight([[fTableView enclosingScrollView] frame]);

    return [self windowFrameByAddingHeight: heightChange checkLimits: YES];
}

- (void) updateForAutoSize
{
    if ([fDefaults boolForKey: @"AutoSize"])
        [self setWindowSizeToFit];
    else
    {
        NSSize contentMinSize = [fWindow contentMinSize];
        contentMinSize.height = [self minWindowContentSizeAllowed];

        [fWindow setContentMinSize: contentMinSize];

        NSSize contentMaxSize = [fWindow contentMaxSize];
        contentMaxSize.height = FLT_MAX;
        [fWindow setContentMaxSize: contentMaxSize];
    }
}

- (void) setWindowMinMaxToCurrent
{
    const CGFloat height = NSHeight([[fWindow contentView] frame]);

    NSSize minSize = [fWindow contentMinSize],
            maxSize = [fWindow contentMaxSize];
    minSize.height = height;
    maxSize.height = height;

    [fWindow setContentMinSize: minSize];
    [fWindow setContentMaxSize: maxSize];
}

- (CGFloat) minWindowContentSizeAllowed
{
    CGFloat contentMinHeight = NSHeight([[fWindow contentView] frame]) - NSHeight([[fTableView enclosingScrollView] frame])
                                + [fTableView rowHeight] + [fTableView intercellSpacing].height;
    return contentMinHeight;
}

- (void) updateForExpandCollape
{
    [self setWindowSizeToFit];
    [self setBottomCountText: YES];
}

- (void) showMainWindow: (id) sender
{
    [fWindow makeKeyAndOrderFront: nil];
}

- (void) windowDidBecomeMain: (NSNotification *) notification
{
    [fBadger clearCompleted];
    [self updateUI];
}

- (void) applicationWillUnhide: (NSNotification *) notification
{
    [self updateUI];
}

- (void) toggleQuickLook: (id) sender
{
    if (![NSApp isOnSnowLeopardOrBetter])
        return;

    if ([[QLPreviewPanelSL sharedPreviewPanel] isVisible])
        [[QLPreviewPanelSL sharedPreviewPanel] orderOut: nil];
    else
        [[QLPreviewPanelSL sharedPreviewPanel] makeKeyAndOrderFront: nil];
}

- (void) linkHomepage: (id) sender
{
    [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: WEBSITE_URL]];
}

- (void) linkForums: (id) sender
{
    [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: FORUM_URL]];
}

- (void) linkTrac: (id) sender
{
    [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: TRAC_URL]];
}

- (void) linkDonate: (id) sender
{
    [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: DONATE_URL]];
}

- (void) updaterWillRelaunchApplication: (SUUpdater *) updater
{
    fQuitRequested = YES;
}

- (NSDictionary *) registrationDictionaryForGrowl
{
    NSArray * notifications = [NSArray arrayWithObjects: GROWL_DOWNLOAD_COMPLETE, GROWL_SEEDING_COMPLETE,
                                                            GROWL_AUTO_ADD, GROWL_AUTO_SPEED_LIMIT, nil];
    return [NSDictionary dictionaryWithObjectsAndKeys: notifications, GROWL_NOTIFICATIONS_ALL,
                                notifications, GROWL_NOTIFICATIONS_DEFAULT, nil];
}

- (void) growlNotificationWasClicked: (id) clickContext
{
    if (!clickContext || ![clickContext isKindOfClass: [NSDictionary class]])
        return;

    NSString * type = [clickContext objectForKey: @"Type"], * location;
    if (([type isEqualToString: GROWL_DOWNLOAD_COMPLETE] || [type isEqualToString: GROWL_SEEDING_COMPLETE])
            && (location = [clickContext objectForKey: @"Location"]))
    {
        if ([NSApp isOnSnowLeopardOrBetter])
        {
            NSURL * file = [NSURL fileURLWithPath: location];
            [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs: [NSArray arrayWithObject: file]];
        }
        else
            [[NSWorkspace sharedWorkspace] selectFile: location inFileViewerRootedAtPath: nil];
    }
}

- (void) rpcCallback: (tr_rpc_callback_type) type forTorrentStruct: (struct tr_torrent *) torrentStruct
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    //get the torrent
    Torrent * torrent = nil;
    if (torrentStruct != NULL && (type != TR_RPC_TORRENT_ADDED && type != TR_RPC_SESSION_CHANGED && type != TR_RPC_SESSION_CLOSE))
    {
        for (torrent in fTorrents)
            if (torrentStruct == [torrent torrentStruct])
            {
                [torrent retain];
                break;
            }

        if (!torrent)
        {
            [pool drain];

            NSLog(@"No torrent found matching the given torrent struct from the RPC callback!");
            return;
        }
    }

    switch (type)
    {
        case TR_RPC_TORRENT_ADDED:
            [self performSelectorOnMainThread: @selector(rpcAddTorrentStruct:) withObject:
                [[NSValue valueWithPointer: torrentStruct] retain] waitUntilDone: NO];
            break;

        case TR_RPC_TORRENT_STARTED:
        case TR_RPC_TORRENT_STOPPED:
            [self performSelectorOnMainThread: @selector(rpcStartedStoppedTorrent:) withObject: torrent waitUntilDone: NO];
            break;

        case TR_RPC_TORRENT_REMOVING:
            [self performSelectorOnMainThread: @selector(rpcRemoveTorrent:) withObject: torrent waitUntilDone: NO];
            break;

        case TR_RPC_TORRENT_TRASHING:
            [self performSelectorOnMainThread: @selector(rpcRemoveTorrentDeleteData:) withObject: torrent waitUntilDone: NO];
            break;

        case TR_RPC_TORRENT_CHANGED:
            [self performSelectorOnMainThread: @selector(rpcChangedTorrent:) withObject: torrent waitUntilDone: NO];
            break;

        case TR_RPC_TORRENT_MOVED:
            [self performSelectorOnMainThread: @selector(rpcMovedTorrent:) withObject: torrent waitUntilDone: NO];
            break;

        case TR_RPC_SESSION_CHANGED:
            [fPrefsController performSelectorOnMainThread: @selector(rpcUpdatePrefs) withObject: nil waitUntilDone: NO];
            break;

        case TR_RPC_SESSION_CLOSE:
            fQuitRequested = YES;
            [NSApp performSelectorOnMainThread: @selector(terminate:) withObject: self waitUntilDone: NO];
            break;

        default:
            NSAssert1(NO, @"Unknown RPC command received: %d", type);
            [torrent release];
    }

    [pool drain];
}

- (void) rpcAddTorrentStruct: (NSValue *) torrentStructPtr
{
    tr_torrent * torrentStruct = (tr_torrent *)[torrentStructPtr pointerValue];
    [torrentStructPtr release];

    NSString * location = nil;
    if (tr_torrentGetDownloadDir(torrentStruct) != NULL)
        location = [NSString stringWithUTF8String: tr_torrentGetDownloadDir(torrentStruct)];

    Torrent * torrent = [[Torrent alloc] initWithTorrentStruct: torrentStruct location: location lib: fLib];

    [torrent update];
    [fTorrents addObject: torrent];
    [torrent release];

    [self updateTorrentsInQueue];
}

- (void) rpcRemoveTorrent: (Torrent *) torrent
{
    [self confirmRemoveTorrents: [[NSArray arrayWithObject: torrent] retain] deleteData: NO];
    [torrent release];
}

- (void) rpcRemoveTorrentDeleteData: (Torrent *) torrent
{
    [self confirmRemoveTorrents: [[NSArray arrayWithObject: torrent] retain] deleteData: YES];
    [torrent release];
}

- (void) rpcStartedStoppedTorrent: (Torrent *) torrent
{
    [torrent update];
    [torrent release];

    [self updateUI];
    [self applyFilter];
    [self updateTorrentHistory];
}

- (void) rpcChangedTorrent: (Torrent *) torrent
{
    [torrent update];

    if ([[fTableView selectedTorrents] containsObject: torrent])
    {
        [fInfoController updateInfoStats]; //this will reload the file table
        [fInfoController updateOptions];
    }

    [torrent release];
}

- (void) rpcMovedTorrent: (Torrent *) torrent
{
    [torrent update];
    [torrent updateTimeMachineExclude];

    if ([[fTableView selectedTorrents] containsObject: torrent])
        [fInfoController updateInfoStats];

    [torrent release];
}

@end
