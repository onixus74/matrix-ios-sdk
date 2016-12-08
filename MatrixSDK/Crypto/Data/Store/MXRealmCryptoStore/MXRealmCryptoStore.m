/*
 Copyright 2016 OpenMarket Ltd

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

#import "MXRealmCryptoStore.h"

#ifdef MX_CRYPTO

#import <Realm/Realm.h>


@interface MXReamDeviceInfo : RLMObject

@property NSData *deviceInfoData;

@property (nonatomic) NSString *deviceId;

@end

@implementation MXReamDeviceInfo

@end
RLM_ARRAY_TYPE(MXReamDeviceInfo)


@interface MXReamUser : RLMObject

@property (nonatomic) NSString *userId;

@property RLMArray<MXReamDeviceInfo *><MXReamDeviceInfo> *devices;

@end

@implementation MXReamUser

+ (NSString *)primaryKey
{
    return @"userId";
}

@end
RLM_ARRAY_TYPE(MXReamUser)


@interface MXRealmRoomAlgorithm : RLMObject

@property NSString *roomId;

@property NSString *algorithm;

@end

@implementation MXRealmRoomAlgorithm

+ (NSString *)primaryKey
{
    return @"roomId";
}

@end
RLM_ARRAY_TYPE(MXRealmRoomAlgorithm)


@interface MXRealmOlmSession : RLMObject

@property NSString *deviceKey;

@property NSData *olmSessionData;

@end

@implementation MXRealmOlmSession

@end
RLM_ARRAY_TYPE(MXRealmOlmSession)


@interface MXRealmOlmInboundGroupSession : RLMObject

@property NSString *sessionId;

@property NSString *senderKey;

@property NSData *olmInboundGroupSessionData;

@end

@implementation MXRealmOlmInboundGroupSession

@end
RLM_ARRAY_TYPE(MXRealmOlmInboundGroupSession)



@interface MXReamOlmAccount : RLMObject

//@property (readonly) OLMAccount *olmAccount;

@property NSData *olmAccountData;

/**
 The obtained user id.
 */
@property (nonatomic) NSString *userId;

/**
 The access token to create a MXRestClient.
 */
@property (nonatomic) NSString *deviceId;

/**
 The current version of the store.
 */
@property (nonatomic) NSNumber<RLMInt> *version;

/**
 */
@property (nonatomic) BOOL deviceAnnounced;

@property RLMArray<MXReamUser *><MXReamUser> *users;

@property RLMArray<MXRealmRoomAlgorithm *><MXRealmRoomAlgorithm> *roomsAlgorithms;

@property RLMArray<MXRealmOlmSession *><MXRealmOlmSession> *olmSessions;

@property RLMArray<MXRealmOlmInboundGroupSession *><MXRealmOlmInboundGroupSession> *olmInboundGroupSessions;

@end

@implementation MXReamOlmAccount

+ (NSString *)primaryKey
{
    return @"userId";
}

@end


@interface MXRealmCryptoStore ()
{
    RLMRealm *realm;

    MXReamOlmAccount *account;
}

@end

@implementation MXRealmCryptoStore

+ (void)initialize
{
    [RLMRealmConfiguration defaultConfiguration].deleteRealmIfMigrationNeeded = YES;
    [[NSFileManager defaultManager] removeItemAtURL:[RLMRealmConfiguration defaultConfiguration].fileURL error:nil];
}

+ (BOOL)hasDataForCredentials:(MXCredentials*)credentials
{
    RLMRealm *realm = [MXRealmCryptoStore realmForUser:credentials.userId];
    return (nil != [MXReamOlmAccount objectsInRealm:realm where:@"userId = %@", credentials.userId].firstObject);
}

+ (instancetype)createStoreWithCredentials:(MXCredentials*)credentials
{
    RLMRealm *realm = [MXRealmCryptoStore realmForUser:credentials.userId];

    MXReamOlmAccount *account = [[MXReamOlmAccount alloc] initWithValue:@{
                                                                          @"userId" : credentials.userId,
                                                                          }];
    account.deviceId = credentials.deviceId;


    [realm beginWriteTransaction];
    [realm addObject:account];
    [realm commitWriteTransaction];

    return [[MXRealmCryptoStore alloc] initWithCredentials:credentials];
}

+ (void)deleteStoreWithCredentials:(MXCredentials*)credentials
{
    RLMRealm *realm = [MXRealmCryptoStore realmForUser:credentials.userId];

    [realm transactionWithBlock:^{
        [realm deleteAllObjects];
    }];
}

- (instancetype)initWithCredentials:(MXCredentials *)credentials
{
    self = [super init];
    if (self)
    {
        realm = [MXRealmCryptoStore realmForUser:credentials.userId];

        account = [MXReamOlmAccount objectsInRealm:realm where:@"userId = %@", credentials.userId].firstObject;
        if (!account)
        {
            return nil;
        }

    }
    return self;
}

- (void)open:(void (^)())onComplete failure:(void (^)(NSError *error))failure
{
    onComplete();
}

- (void)storeDeviceId:(NSString*)deviceId
{
    [realm transactionWithBlock:^{
        account.deviceId = deviceId;
    }];
}

- (NSString*)deviceId
{
    return account.deviceId;
}

- (void)storeAccount:(OLMAccount*)olmAccount
{
    [realm transactionWithBlock:^{
        account.olmAccountData = [NSKeyedArchiver archivedDataWithRootObject:olmAccount];
    }];
}

- (OLMAccount*)account
{
    return [NSKeyedUnarchiver unarchiveObjectWithData:account.olmAccountData];
}

- (void)storeDeviceAnnounced
{
    [realm transactionWithBlock:^{
        account.deviceAnnounced = YES;
    }];
}

- (BOOL)deviceAnnounced
{
    return account.deviceAnnounced;
}

- (void)storeDeviceForUser:(NSString*)userId device:(MXDeviceInfo*)device
{
    [realm transactionWithBlock:^{

        MXReamUser *realmUser = [[account.users objectsWhere:@"userId = %@", userId] firstObject];
        if (!realmUser)
        {
            realmUser = [[MXReamUser alloc] initWithValue:@{
                                                            @"userId": userId,
                                                            }];

            [account.users addObject:realmUser];
        }

        MXReamDeviceInfo *realmDevice = [[realmUser.devices objectsWhere:@"deviceId = %@", device.deviceId] firstObject];
        if (!realmDevice)
        {
            realmDevice = [[MXReamDeviceInfo alloc] initWithValue:@{
                                                                    @"deviceId": device.deviceId,
                                                                    @"deviceInfoData": [NSKeyedArchiver archivedDataWithRootObject:device]
                                                                    }];
            [realmUser.devices addObject:realmDevice];
        }
        else
        {
            realmDevice.deviceInfoData = [NSKeyedArchiver archivedDataWithRootObject:device];
        }

    }];
}

- (MXDeviceInfo*)deviceWithDeviceId:(NSString*)deviceId forUser:(NSString*)userId
{
    MXReamUser *realmUser = [[account.users objectsWhere:@"userId = %@", userId] firstObject];

    MXReamDeviceInfo *realmDevice = [[realmUser.devices objectsWhere:@"deviceId = %@", deviceId] firstObject];

    return [NSKeyedUnarchiver unarchiveObjectWithData:realmDevice.deviceInfoData];
}

- (void)storeDevicesForUser:(NSString*)userId devices:(NSDictionary<NSString*, MXDeviceInfo*>*)devices
{
    MXReamUser *realmUser = [[account.users objectsWhere:@"userId = %@", userId] firstObject];
    if (!realmUser)
    {
        realmUser = [[MXReamUser alloc] initWithValue:@{
                                                        @"userId": userId,
                                                        }];
        [realm transactionWithBlock:^{
            [account.users addObject:realmUser];
        }];
    }

    // TODO
    for (NSString *deviceId in devices)
    {
        [self storeDeviceForUser:userId device:devices[deviceId]];
    }
}

- (NSDictionary<NSString*, MXDeviceInfo*>*)devicesForUser:(NSString*)userId
{
    NSMutableDictionary *devicesForUser;

    MXReamUser *realmUser = [[account.users objectsWhere:@"userId = %@", userId] firstObject];
    if (realmUser)
    {
        devicesForUser = [NSMutableDictionary dictionary];

        for (MXReamDeviceInfo *realmDevice in realmUser.devices)
        {
            devicesForUser[realmDevice.deviceId] = [NSKeyedUnarchiver unarchiveObjectWithData:realmDevice.deviceInfoData];
        }
    }

    return devicesForUser;
}

- (void)storeAlgorithmForRoom:(NSString*)roomId algorithm:(NSString*)algorithm
{
    if ([self algorithmForRoom:roomId])
    {
        NSLog(@"eded");
    }

    MXRealmRoomAlgorithm *roomAlgorithm = [[MXRealmRoomAlgorithm alloc] initWithValue:@{
                                                                              @"roomId": roomId,
                                                                              @"algorithm": algorithm
                                                                              }];

    [realm transactionWithBlock:^{
        [account.roomsAlgorithms addObject:roomAlgorithm];
    }];
}

- (NSString*)algorithmForRoom:(NSString*)roomId
{
    return [[account.roomsAlgorithms objectsWhere:@"roomId = %@", roomId] firstObject].algorithm;
}

- (void)storeSession:(OLMSession*)session forDevice:(NSString*)deviceKey
{
    MXRealmOlmSession *realmOlmSession = [[MXRealmOlmSession alloc] initWithValue:@{
                                                                                    @"deviceKey": deviceKey,
                                                                                    @"olmSessionData": [NSKeyedArchiver archivedDataWithRootObject:session]
                                                                                    }];

    [realm transactionWithBlock:^{
        [account.olmSessions addObject:realmOlmSession];
    }];
}

- (NSDictionary<NSString*, OLMSession*>*)sessionsWithDevice:(NSString*)deviceKey
{
    NSMutableDictionary<NSString*, OLMSession*> *sessionsWithDevice;

    RLMResults<MXRealmOlmSession *> *realmOlmSessions = [account.olmSessions objectsWhere:@"deviceKey = %@", deviceKey];
    for (MXRealmOlmSession *realmOlmSession in realmOlmSessions)
    {
        if (!sessionsWithDevice)
        {
            sessionsWithDevice = [NSMutableDictionary dictionary];
        }

        sessionsWithDevice[realmOlmSession.deviceKey] = [NSKeyedUnarchiver unarchiveObjectWithData:realmOlmSession.olmSessionData];
    }

    return sessionsWithDevice;
}

- (void)storeInboundGroupSession:(MXOlmInboundGroupSession*)session
{
    MXRealmOlmInboundGroupSession *realmSession = [[MXRealmOlmInboundGroupSession alloc] initWithValue:@{
                                                                                    @"sessionId": session.session.sessionIdentifier,
                                                                                    @"senderKey": session.senderKey,
                                                                                    @"olmInboundGroupSessionData": [NSKeyedArchiver archivedDataWithRootObject:session]
                                                                                    }];

    [realm transactionWithBlock:^{
        [account.olmInboundGroupSessions addObject:realmSession];
    }];
}

- (MXOlmInboundGroupSession*)inboundGroupSessionWithId:(NSString*)sessionId andSenderKey:(NSString*)senderKey
{
     MXRealmOlmInboundGroupSession *realmSession = [account.olmInboundGroupSessions objectsWhere:@"sessionId = %@ AND senderKey = %@", sessionId, senderKey].firstObject;

    return [NSKeyedUnarchiver unarchiveObjectWithData:realmSession.olmInboundGroupSessionData];
}

- (void)removeInboundGroupSessionWithId:(NSString*)sessionId andSenderKey:(NSString*)senderKey
{
    RLMResults<MXRealmOlmInboundGroupSession *> *realmSessions = [account.olmInboundGroupSessions objectsWhere:@"sessionId = %@ AND senderKey = %@", sessionId, senderKey];

    [realm transactionWithBlock:^{
        [realm deleteObjects:realmSessions];
    }];
}

#pragma mark - Private methods

+ (RLMRealm*)realmForUser:(NSString*)userId
{
    RLMRealmConfiguration *config = [RLMRealmConfiguration defaultConfiguration];

    // Use the default directory, but replace the filename with the username
    config.fileURL = [[[config.fileURL URLByDeletingLastPathComponent]
                       URLByAppendingPathComponent:userId]
                      URLByAppendingPathExtension:@"realm"];

    return [RLMRealm realmWithConfiguration:config error:nil];
}

@end

#endif
