/******************************************************************************
 * $Id$
 *
 * Copyright (c) 2006-2011 Transmission authors and contributors
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

typedef enum
{
    PORT_STATUS_CHECKING,
    PORT_STATUS_OPEN,
    PORT_STATUS_CLOSED,
    PORT_STATUS_ERROR
} port_status_t;

@interface PortChecker : NSObject
{
    id fDelegate;
    port_status_t fStatus;

    NSURLConnection * fConnection;
    NSMutableData * fPortProbeData;

    NSTimer * fTimer;
}

- (id) initForPort: (NSInteger) portNumber delay: (BOOL) delay withDelegate: (id) delegate;
- (void) cancelProbe;

- (port_status_t) status;

@end
