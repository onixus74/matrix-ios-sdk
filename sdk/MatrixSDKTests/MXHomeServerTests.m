/*
 Copyright 2014 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import "MXHomeServer.h"

#define MX_HOMESERVER_URL @"http://matrix.org"

@interface MXHomeServerTests : XCTestCase
{
    MXHomeServer *homeServer;
}

@end

@implementation MXHomeServerTests

- (void)setUp {
    [super setUp];

    homeServer = [[MXHomeServer alloc] initWithHomeServer:MX_HOMESERVER_URL];
}

- (void)tearDown {
    homeServer = nil;

    [super tearDown];
}

- (void)testInit {
    XCTAssert(nil != homeServer, @"Valid init");
    XCTAssert([homeServer.homeserver isEqualToString:MX_HOMESERVER_URL], @"Pass");
}

- (void)testPublicRooms {

    XCTestExpectation *expectation = [self expectationWithDescription:@"asyncTest"];

    // Use the hs running at matrix.org as we know there are public rooms there
    homeServer = [[MXHomeServer alloc] initWithHomeServer:@"http://matrix.org"];
    [homeServer publicRooms:^(NSArray *rooms) {

        XCTAssert(0 < rooms.count, @"Valid init");

        BOOL bMatrixHQRoom;
        for (MXPublicRoom *room in rooms)
        {
            // Find the Matrix HQ room by its ID
            if ([room.room_id isEqualToString:@"!cURbafjkfsMDVwdRDQ:matrix.org"])
            {
                bMatrixHQRoom = YES;
            }
        }

        XCTAssert(bMatrixHQRoom, @"Matrix HQ must be listed in public rooms");

        [expectation fulfill];

    } failure:^(MXError *error) {
        XCTAssert(NO, @"Error");
        [expectation fulfill];

    }];

    [self waitForExpectationsWithTimeout:1 handler:^(NSError *error) {
    }];
}

@end