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

#import "BonjourController.h"

@implementation BonjourController

BonjourController * fDefaultController = nil;
+ (BonjourController *) defaultController
{
    if (!fDefaultController)
        fDefaultController = [[BonjourController alloc] init];
    return fDefaultController;
}

- (void) dealloc
{
    [fService release];
    [super dealloc];
}

- (void) startWithPort: (NSInteger) port
{
    [self stop];

    NSString * serviceName = [NSString stringWithFormat: @"Transmission Web Interface (%@)", NSUserName()];

    fService = [[NSNetService alloc] initWithDomain: @"" type: @"_http._tcp." name: serviceName port: port];
    [fService setDelegate: self];

    [fService publish];
}

- (void) stop
{
    [fService stop];
    [fService release];
    fService = nil;
}

- (void) netService: (NSNetService *) sender didNotPublish: (NSDictionary *) errorDict
{
    NSLog(@"Failed to publish the web interface service on port %ld, with error: %@", [sender port], errorDict);
}

- (void) netService: (NSNetService *) sender didNotResolve: (NSDictionary *) errorDict
{
    NSLog(@"Failed to resolve the web interface service on port %ld, with error: %@", [sender port], errorDict);
}

@end
