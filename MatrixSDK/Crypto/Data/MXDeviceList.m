/*
 Copyright 2017 Vector Creations Ltd

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

#import "MXDeviceList.h"

#ifdef MX_CRYPTO

#import "MXCrypto_Private.h"

#import "MXDeviceListOperationsPool.h"

// Helper to transform a NSNumber stored in a NSDictionary to MXDeviceTrackingStatus
#define MXDeviceTrackingStatusFromNSNumber(aNSNumberObject) ((MXDeviceTrackingStatus)[aNSNumberObject integerValue])


@interface MXDeviceList ()
{
    MXCrypto *crypto;

    // Users we are tracking device status for.
    // userId -> MXDeviceTrackingStatus*
    NSMutableDictionary<NSString*, NSNumber*> *deviceTrackingStatus;

    /**
     The pool which the http request is currenlty being processed.
     (nil if there is no current request).

     Note that currentPoolQuery.usersIds corresponds to the inProgressUsersWithNewDevices
     ivar we used before.
     */
    MXDeviceListOperationsPool *currentQueryPool;

    /**
     When currentPoolQuery is already being processed, all download
     requests go in this pool which will be launched once currentPoolQuery is
     complete.
     */
    MXDeviceListOperationsPool *nextQueryPool;
}
@end


@implementation MXDeviceList

- (id)initWithCrypto:(MXCrypto *)theCrypto
{
    self = [super init];
    if (self)
    {
        crypto = theCrypto;

        // Retrieve tracking status from the store
        deviceTrackingStatus = [NSMutableDictionary dictionaryWithDictionary:[crypto.store deviceTrackingStatus]];

        for (NSString *userId in deviceTrackingStatus)
        {
            // if a download was in progress when we got shut down, it isn't any more.
            if (MXDeviceTrackingStatusFromNSNumber(deviceTrackingStatus[userId]) == MXDeviceTrackingStatusDownloadInProgress)
            {
                deviceTrackingStatus[userId] = @(MXDeviceTrackingStatusPendingDownload);
            }
        }
    }
    return self;
}

- (MXHTTPOperation*)downloadKeys:(NSArray<NSString*>*)userIds forceDownload:(BOOL)forceDownload
                         success:(void (^)(MXUsersDevicesMap<MXDeviceInfo*> *usersDevicesInfoMap))success
                         failure:(void (^)(NSError *error))failure
{
    NSLog(@"[MXDeviceList] downloadKeys(forceDownload: %tu) : %@", forceDownload, userIds);

    NSMutableArray *usersToDownload = [NSMutableArray array];
    BOOL doANewQuery = NO;

    for (NSString *userId in userIds)
    {
        MXDeviceTrackingStatus trackingStatus = MXDeviceTrackingStatusFromNSNumber(deviceTrackingStatus[userId]);

        if ([currentQueryPool.userIds containsObject:userId]) // equivalent to (trackingStatus == MXDeviceTrackingStatusDownloadInProgress)
        {
            // already a key download in progress/queued for this user; its results
            // will be good enough for us.
            [usersToDownload addObject:userId];
        }
        else if (forceDownload || trackingStatus != MXDeviceTrackingStatusUpToDate)
        {
            [usersToDownload addObject:userId];
            doANewQuery = YES;
        }
    }

    MXDeviceListOperation *operation;

    if (usersToDownload.count)
    {
        for (NSString *userId in usersToDownload)
        {
            deviceTrackingStatus[userId] = @(MXDeviceTrackingStatusDownloadInProgress);
        }

        operation = [[MXDeviceListOperation alloc] initWithUserIds:usersToDownload success:^(NSArray<NSString *> *succeededUserIds, NSArray<NSString *> *failedUserIds) {

            NSLog(@"[MXDeviceList] downloadKeys -> DONE");

            for (NSString *userId in succeededUserIds)
            {
                MXDeviceTrackingStatus trackingStatus = MXDeviceTrackingStatusFromNSNumber(deviceTrackingStatus[userId]);
                if (trackingStatus == MXDeviceTrackingStatusDownloadInProgress)
                {
                    // we didn't get any new invalidations since this download started:
                    // this user's device list is now up to date.
                    deviceTrackingStatus[userId] = @(MXDeviceTrackingStatusUpToDate);
                }
            }

            [self persistDeviceTrackingStatus];

            if (success)
            {
                MXUsersDevicesMap<MXDeviceInfo *> *usersDevicesInfoMap = [self devicesForUsers:userIds];
                success(usersDevicesInfoMap);
            }

        } failure:failure];

        if (doANewQuery)
        {
            NSLog(@"[MXDeviceList] downloadKeys: waiting for next key query");

            [self startOrQueueDeviceQuery:operation];
        }
        else
        {

            NSLog(@"[MXDeviceList] downloadKeys: waiting for in-flight query to complete");
            
            [operation addToPool:currentQueryPool];
        }
    }
    else
    {
        if (success)
        {
            success([self devicesForUsers:userIds]);
        }
    }

    return operation;
}

- (NSArray<MXDeviceInfo *> *)storedDevicesForUser:(NSString *)userId
{
    return [crypto.store devicesForUser:userId].allValues;
}

- (MXDeviceInfo *)deviceWithIdentityKey:(NSString *)senderKey forUser:(NSString *)userId andAlgorithm:(NSString *)algorithm
{
    if (![algorithm isEqualToString:kMXCryptoOlmAlgorithm]
        && ![algorithm isEqualToString:kMXCryptoMegolmAlgorithm])
    {
        // We only deal in olm keys
        return nil;
    }

    for (MXDeviceInfo *device in [self storedDevicesForUser:userId])
    {
        for (NSString *keyId in device.keys)
        {
            if ([keyId hasPrefix:@"curve25519:"])
            {
                NSString *deviceKey = device.keys[keyId];
                if ([senderKey isEqualToString:deviceKey])
                {
                    return device;
                }
            }
        }
    }

    // Doesn't match a known device
    return nil;
}

- (void)startTrackingDeviceList:(NSString*)userId
{
    MXDeviceTrackingStatus trackingStatus = MXDeviceTrackingStatusFromNSNumber(deviceTrackingStatus[userId]);

    if (!trackingStatus)
    {
        NSLog(@"[MXDeviceList] Now tracking device list for %@", userId);
        deviceTrackingStatus[userId] = @(MXDeviceTrackingStatusPendingDownload);
    }
    // we don't yet persist the tracking status, since there may be a lot
    // of calls; instead we wait for the forthcoming
    // refreshOutdatedDeviceLists.
}

- (void)invalidateUserDeviceList:(NSString *)userId
{
    MXDeviceTrackingStatus trackingStatus = MXDeviceTrackingStatusFromNSNumber(deviceTrackingStatus[userId]);

    if (trackingStatus)
    {
        NSLog(@"[MXDeviceList] Marking device list outdated for %@", userId);
        deviceTrackingStatus[userId] = @(MXDeviceTrackingStatusPendingDownload);
    }
    // we don't yet persist the tracking status, since there may be a lot
    // of calls; instead we wait for the forthcoming
    // refreshOutdatedDeviceLists.
}

- (void)invalidateAllDeviceLists;
{
    for (NSString *userId in deviceTrackingStatus.allKeys)
    {
        [self invalidateUserDeviceList:userId];
    }
}

- (void)refreshOutdatedDeviceLists
{
    NSMutableArray *users = [NSMutableArray array];
    for (NSString *userId in deviceTrackingStatus)
    {
        MXDeviceTrackingStatus trackingStatus = MXDeviceTrackingStatusFromNSNumber(deviceTrackingStatus[userId]);
        if (trackingStatus == MXDeviceTrackingStatusPendingDownload)
        {
            [users addObject:userId];
        }
    }

    if (users)
    {
        // we didn't persist the tracking status during
        // invalidateUserDeviceList, so do it now.
        [self persistDeviceTrackingStatus];

        MXDeviceListOperation *operation = [[MXDeviceListOperation alloc] initWithUserIds:users success:^(NSArray<NSString *> *succeededUserIds, NSArray<NSString *> *failedUserIds) {

            NSLog(@"[MXDeviceList] refreshOutdatedDeviceLists: %@", succeededUserIds);

            if (failedUserIds.count)
            {
                NSLog(@"[MXDeviceList] refreshOutdatedDeviceLists. Error updating device keys for users %@", failedUserIds);

                // TODO: What to do with failed devices?
                // For now, ignore them like matrix-js-sdk
            }

        } failure:^(NSError *error) {

            NSLog(@"[MXDeviceList] refreshOutdatedDeviceLists: ERROR updating device keys for users %@", users);
            for (NSString *userId in users)
            {
                deviceTrackingStatus[userId] = @(MXDeviceTrackingStatusPendingDownload);
            }

            [self persistDeviceTrackingStatus];
        } ];

        [self startOrQueueDeviceQuery:operation];
    }
}

- (void)persistDeviceTrackingStatus
{
    [crypto.store storeDeviceTrackingStatus:deviceTrackingStatus];
}

/**
 Get the stored device keys for a list of user ids.

 @param userIds the list of users to list keys for.
 @return users devices.
*/
- (MXUsersDevicesMap<MXDeviceInfo*> *)devicesForUsers:(NSArray<NSString*>*)userIds
{
    MXUsersDevicesMap<MXDeviceInfo*> *usersDevicesInfoMap = [[MXUsersDevicesMap alloc] init];

    for (NSString *userId in userIds)
    {
        // Retrive the data from the store
        NSDictionary<NSString*, MXDeviceInfo*> *devices = [crypto.store devicesForUser:userId];
        if (devices)
        {
            [usersDevicesInfoMap setObjects:devices forUser:userId];
        }
    }

    return usersDevicesInfoMap;
}

- (void)startOrQueueDeviceQuery:(MXDeviceListOperation *)operation
{
    if (!currentQueryPool)
    {
        // No pool is currently being queried
        if (nextQueryPool)
        {
            // Launch the query for the existing next pool
            currentQueryPool = nextQueryPool;
            nextQueryPool = nil;
        }
        else
        {
            // Create a new pool to query right now
            currentQueryPool = [[MXDeviceListOperationsPool alloc] initWithCrypto:crypto];
        }

        [operation addToPool:currentQueryPool];
        [self startCurrentPoolQuery];
    }
    else
    {
        // Append the device list operation to the next pool
        if (!nextQueryPool)
        {
            nextQueryPool = [[MXDeviceListOperationsPool alloc] initWithCrypto:crypto];
        }
        [operation addToPool:nextQueryPool];
    }
}

- (void)startCurrentPoolQuery
{
    NSLog(@"startCurrentPoolQuery: %@: %@", currentQueryPool, currentQueryPool.userIds);

    if (currentQueryPool.userIds)
    {
        NSString *token = _lastKnownSyncToken;

        // Add token
        [currentQueryPool downloadKeys:token complete:^(NSDictionary<NSString *,NSDictionary *> *failedUserIds) {

            NSLog(@"startCurrentPoolQuery -> DONE. failedUserIds: %@", failedUserIds);

            if (token)
            {
                [crypto.store storeDeviceSyncToken:token];
            }

            currentQueryPool = nil;
            if (nextQueryPool)
            {
                currentQueryPool = nextQueryPool;
                nextQueryPool = nil;
                [self startCurrentPoolQuery];
            }
        }];
    }
}

@end

#endif
