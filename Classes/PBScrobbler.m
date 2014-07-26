

#import "PBScrobbler.h"

@implementation PBScrobbler

#pragma mark -

-(id)init{

    self = [super init];
    
    if (self) {
    RKLogConfigureByName("RestKit/*", RKLogLevelCritical);
    
    [self configureMapping];
    
    [self authenticate];

    submissionsCount = [[[NSUserDefaults standardUserDefaults] objectForKey:@"totalScrobbled"] longValue];

    [self registerForNotifications];

    self.shouldTerminate = NO;
    }
    return self;
}

-(void)dealloc{

    [self unregisterForNotifications];
}

#pragma mark -

-(void)didScrobble{

    submissionsCount++;
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithUnsignedLong:submissionsCount] forKey: @"totalScrobbled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
}

-(void)couldNotScrobbleMediaItem:(PBMediaItem *)mediaItem{

    if (!mediaItem.timestamp) {
        return;
    }
//    NSLog(@"Saving %@ to store..", mediaItem);
    
    NSError *error;
    if (![temporaryItemsContext saveToPersistentStore:&error]) {
        self.shouldTerminate = YES;
    }
}

#pragma mark -

-(PBMediaItem *)mediaItemWithInfo:(NSDictionary *)info includingTimestamp:(BOOL)shouldIncludeTimestamp{
    
    PBMediaItem *mediaItem = [NSEntityDescription insertNewObjectForEntityForName:@"MediaItem" inManagedObjectContext:temporaryItemsContext];
    
    mediaItem.title = [info objectForKey:(__bridge NSString *)kMRMediaRemoteNowPlayingInfoTitle];
    mediaItem.artist = [info objectForKey:(__bridge NSString *)kMRMediaRemoteNowPlayingInfoArtist];
    
    if (shouldIncludeTimestamp)
        mediaItem.timestamp = [NSNumber numberWithDouble:[[info objectForKey:(__bridge NSDate *)kMRMediaRemoteNowPlayingInfoTimestamp] timeIntervalSince1970]];
    
    if ([info objectForKey:(__bridge NSString *)kMRMediaRemoteNowPlayingInfoAlbum]) {
        mediaItem.album = [info objectForKey:(__bridge NSString *)kMRMediaRemoteNowPlayingInfoAlbum];
    }
    
    if ([info objectForKey:(__bridge NSNumber *)kMRMediaRemoteNowPlayingInfoDuration]) {
        mediaItem.duration = [info objectForKey:(__bridge NSNumber *)kMRMediaRemoteNowPlayingInfoDuration];
    }
    return mediaItem;
    
}

-(BOOL)shouldIgnoreTrack:(NSDictionary *)info{
    
    if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_7_0) {
        if ([[info objectForKey:(__bridge NSNumber *)kMRMediaRemoteNowPlayingInfoRadioStationIdentifier] longValue] && ![[NSUserDefaults standardUserDefaults] boolForKey:@"scrobbleRadio"]) {
            //        1. If it is a radio track and we disallowed to scrobble these
            return YES;
        }
    }
    
    
    NSString *appString = [NSString stringWithFormat:@"ScrobbleDisabled-%@", [info objectForKey:@"nowPlayingApplication"]];
    if ([[NSUserDefaults standardUserDefaults] valueForKey:appString]) {
        //        2. If we disabled scrobbling for a certain application
        return YES;
    }
    
    return NO;
}

-(void)sendNowPlayingWithInfo:(NSDictionary *)info{
   
    if ([self shouldIgnoreTrack:info]) {
        return;
    }
    
    PBMediaItem *mediaItem = [self mediaItemWithInfo:info includingTimestamp:NO];
    NSDictionary *params = [LFSignatureConstructor generateParametersWithMediaItem:mediaItem withSession:session withMethod:@"track.updateNowPlaying"];

    [[RKObjectManager sharedManager] postObject:nil path:@"" parameters:params success:
     ^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
         
         for (id obj in mappingResult.array) {

             if ([obj isKindOfClass:[LFError class]]) {
                 NSLog(@"Error sending nowplaying: %@", [obj description]);
                 if ([[obj valueForKey:@"error"] integerValue] == 9) {
                     [self setAuthResponse:@"Error"];
                 }
             }
             else{
                 [self setState:SCROBBLER_NOWPLAYING];
             }
         }

     } failure:^(RKObjectRequestOperation *operation, NSError *error) {

         NSLog(@"Error sending nowplaying: %@", [error description]);
         [self setState:SCROBBLER_OFFLINE];
     }];
    
    [temporaryItemsContext deleteObject:mediaItem];
}

-(void)scrobbleTrackWithInfo:(NSDictionary *)info{

    
    if ([self shouldIgnoreTrack:info]) {
        return;
    }
    
    PBMediaItem *mediaItem = [self mediaItemWithInfo:info includingTimestamp:YES];
    
    if (!session) {
        [self couldNotScrobbleMediaItem:mediaItem];
        return;
    }

    [self scrobbleTrack:mediaItem];
}

-(void)scrobbleTrack:(PBMediaItem *)mediaItem{
    
    if (!mediaItem) {
        return;
    }
    
    NSDictionary *params = [LFSignatureConstructor generateParametersWithMediaItem:mediaItem withSession:session withMethod:@"track.scrobble"];

//    NSLog(@"Going to scrobble %@ with params %@", mediaItem, params);
    
    __block BOOL didSave = NO;
    [[RKObjectManager sharedManager] postObject:nil path:@"" parameters:params success:
     ^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
         for (id obj in mappingResult.array) {

             if ([obj isKindOfClass:[LFError class]]) {
                 NSLog(@"%@", [obj description]);
                 
                 if ([[obj valueForKey:@"error"] integerValue] == 9) {
                     [self setAuthResponse:@"Error"];
                 }
                 
                 if (!didSave)
                 [self couldNotScrobbleMediaItem:mediaItem];
                 didSave = YES;
             }
             if ([obj isKindOfClass:[PBMediaItem class]]) {
                 if (!didSave)
                 [self couldNotScrobbleMediaItem:obj];
            }
             
         }
         
         if (![mappingResult count]) {
             
             [temporaryItemsContext deleteObject:mediaItem];
             [self setState:SCROBBLER_SCROBBLING];
             [self didScrobble];
         }
         
     } failure:^(RKObjectRequestOperation *operation, NSError *error) {
         NSLog(@"Error scrobbling %@ - %@", mediaItem.artist, mediaItem.title);
         [self couldNotScrobbleMediaItem:mediaItem];
     }];
    
}

-(void)handleQueue{
    
    if (!session) {
        return;
    }

    NSManagedObjectContext *context = [RKManagedObjectStore defaultStore].persistentStoreManagedObjectContext;
    NSFetchRequest *request = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription entityForName:@"MediaItem" inManagedObjectContext:context];
    [request setEntity:entity];
    
    __block NSError *error;
    NSArray *mediaItems = [context  executeFetchRequest:request error:&error];
    
    if (![mediaItems count]) {
        return;
    }
    
    if ([mediaItems count] > 50) {
        mediaItems = [mediaItems subarrayWithRange:NSMakeRange(0, 50)];
    }
    
    NSDictionary *params = [LFSignatureConstructor generateParametersWithMediaItems:mediaItems withSession:session withMethod:@"track.scrobble"];
    
    [[RKObjectManager sharedManager] postObject:nil path:@"" parameters:params success:
     ^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {
         
   
         for (id obj in mappingResult.array) {
             
             if ([obj isKindOfClass:[LFError class]]) {
                 NSLog(@"%@", [obj description]);
                 if ([[obj valueForKey:@"error"] integerValue] == 9) {
                     [self setAuthResponse:@"Error"];
                 }
             }
             
             if ([obj isKindOfClass:[PBMediaItem class]]) {
                 for (PBMediaItem *mediaItem in mediaItems) {
                     [context deleteObject:mediaItem];
                     [context saveToPersistentStore:&error];
                 }
             }
         }
         
         if (![mappingResult.array count]) {
             
             [self setState:SCROBBLER_SCROBBLING];
             for (PBMediaItem *mediaItem in mediaItems) {
                 [context deleteObject:mediaItem];
                 [self didScrobble];
             }
             [queueObserver postDeletedTracks];
             [context saveToPersistentStore:&error];
         }
     }failure:^(RKObjectRequestOperation *operation, NSError *error) {
     }];
    
}

#pragma mark States

- (void)setState:(scrobbleState_t)state {

	[[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInt:state] forKey:@"scrobblerState"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    if (state != SCROBBLER_READY ||state != SCROBBLER_OFFLINE || state != SCROBBLER_AUTHENTICATING) {
        
        dispatch_queue_t backgrQueue = dispatch_queue_create("stateQueue", 0);
        double delayInSeconds = 15.0;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, backgrQueue, ^(void){
            [self setState:SCROBBLER_READY];
        });
    }
}

-(void)setAuthResponse:(NSString *)response{
    
    [[NSUserDefaults standardUserDefaults] setObject:response forKey:@"lastResult"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark Notifications

-(void)registerForNotifications{

    center = [NSNotificationCenter defaultCenter];
    observer = [[PBMediaRemoteNotificationObserver alloc] init];
    
    observer.delegate = self;
    
    [center addObserver:observer selector:@selector(trackDidChange) name:(__bridge NSString *)kMRMediaRemoteNowPlayingInfoDidChangeNotification object:nil];

    queueObserver = [[PBScrobblerQueueNotificationObserver alloc] init];
    
    [[[RKObjectManager sharedManager] HTTPClient] setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {

        if (status == AFNetworkReachabilityStatusReachableViaWiFi || (status == AFNetworkReachabilityStatusReachableViaWWAN && [[[NSUserDefaults standardUserDefaults] objectForKey:@"scrobbleOverEDGE"] boolValue])) {

            if (!session) {
                [self authenticate];
            }

            [self handleQueue];
        }
    }];
}

-(void)unregisterForNotifications{
    
    [observer unregisterForNotifications];
    [queueObserver unregisterForNotifications];
    [center removeObserver:self];
}

#pragma mark Authentication

-(void)authenticate{
    
    [self setState:SCROBBLER_AUTHENTICATING];

    FXKeychain *keychain = [[FXKeychain alloc] initWithService:@"pb.scrobbled" accessGroup:@"apple" accessibility:FXKeychainAccessibleAlways];
    NSString *login = [keychain objectForKey:@"login"];
    NSString *password = [keychain objectForKey:@"password"];

    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObjectsAndKeys:password, @"password", login, @"username", kLFAPIKey, @"api_key", @"auth.getMobileSession", @"method", nil];

    NSString *signature = [LFSignatureConstructor generateSignatureFromDictionary:params withSecret:kLFAPISecret];
    [params setObject:signature forKey:@"api_sig"];

    __block BOOL shouldReauth = NO;
    [[RKObjectManager sharedManager] postObject:nil path:@"" parameters:params success:^(RKObjectRequestOperation *operation, RKMappingResult *mappingResult) {

        for (id obj in mappingResult.array) {

            if ([obj isKindOfClass:[LFError class]]) {
                NSLog(@"%@", [obj description]);
                [self setAuthResponse:@"Error"];
                shouldReauth = YES;
            }

            if ([obj isKindOfClass:[LFSession class]]) {
                session = [obj copy];
                [self setState:SCROBBLER_READY];
                [self setAuthResponse:@"OK"];
            }
        }
    } failure:^(RKObjectRequestOperation *operation, NSError *error) {
        NSLog(@"%@", [error description]);
        [self setState:SCROBBLER_OFFLINE];
        [self setAuthResponse:@"No response"];
    }];
    [self retryAuthIn:120];
}

-(void)retryAuthIn:(double)seconds{
    
    double delayInSeconds = seconds;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self authenticate];
    });
}

#pragma mark Models

-(void)configureMapping{
    
    // This sets up mapping for: Last.fm errors, Last.fm sessions and a PBMediaItem mapping
    // in case server refuses it with code 5; otherwise there is no point in trying to resubmit
    // that scrobble (unless we can correct some info, which we won't do.)

    NSError *error;
    
    NSURL *baseURL = [NSURL URLWithString:@"https://ws.audioscrobbler.com/2.0/?format=json"];
    AFHTTPClient *client = [[AFHTTPClient alloc] initWithBaseURL:baseURL];

    RKObjectManager *manager = [[RKObjectManager alloc] initWithHTTPClient:client];

    RKObjectMapping *sessMapping = [RKObjectMapping mappingForClass:[LFSession class]];
    [sessMapping addAttributeMappingsFromArray:@[@"subscriber", @"name", @"key"]];
    RKObjectMapping *errorMapping = [RKObjectMapping mappingForClass:[LFError class]];
    [errorMapping addAttributeMappingsFromArray:@[@"message", @"error"]];

    RKResponseDescriptor *sessDescriptor = [RKResponseDescriptor responseDescriptorWithMapping:sessMapping method:RKRequestMethodPOST pathPattern:@"" keyPath:@"session" statusCodes:[NSIndexSet indexSetWithIndex:200]];
    RKResponseDescriptor *errDescriptor = [RKResponseDescriptor responseDescriptorWithMapping:errorMapping method:RKRequestMethodPOST pathPattern:@"" keyPath:@"" statusCodes:[NSIndexSet indexSetWithIndex:200]];

    [manager addResponseDescriptor:sessDescriptor];
    [manager addResponseDescriptor:errDescriptor];

    mkdir("/var/mobile/Library/scrobbled/", 0755);
    
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[[NSBundle mainBundle] URLForResource:@"Model" withExtension:@"momd"]];
    managedObjectStore = [[RKManagedObjectStore alloc] initWithManagedObjectModel:model];
    
    [manager setManagedObjectStore:managedObjectStore];
    [managedObjectStore createPersistentStoreCoordinator];

    NSString *storePath = [@"/var/mobile/Library/scrobbled" stringByAppendingPathComponent:@"Scrobbled.sqlite"];
    NSPersistentStore *store = [managedObjectStore addSQLitePersistentStoreAtPath:storePath fromSeedDatabaseAtPath:nil withConfiguration:nil options:nil error:&error];
    NSAssert(store, @"%@", [error description]);
    

    [managedObjectStore createManagedObjectContexts];
    
    self.savedItemsContext = managedObjectStore.mainQueueManagedObjectContext;
    
    temporaryItemsContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    RKManagedObjectStore *tempManagedObjectStore = [[RKManagedObjectStore alloc] initWithManagedObjectModel:model];
    [tempManagedObjectStore createPersistentStoreCoordinator];
    [tempManagedObjectStore addInMemoryPersistentStore:&error];
    [temporaryItemsContext setParentContext:self.savedItemsContext];
    
    managedObjectStore.managedObjectCache = [[RKInMemoryManagedObjectCache alloc] initWithManagedObjectContext:managedObjectStore.persistentStoreManagedObjectContext];

    manager.managedObjectStore = managedObjectStore;
    
    RKEntityMapping *entityMapping = [RKEntityMapping mappingForEntityForName:@"MediaItem" inManagedObjectStore:managedObjectStore];
    entityMapping.identificationAttributes = @[@"timestamp"];
    [entityMapping addAttributeMappingsFromDictionary:@{@"ignoredMessage.code":@"ignoredCode",
                                                        @"track.#text":@"title",
                                                        @"album.#text":@"album",
                                                        @"artist.#text":@"artist"}];
    entityMapping.forceCollectionMapping = YES;
    
    
    RKDynamicMapping *dynamicMapping = [[RKDynamicMapping alloc] init];
    [dynamicMapping addMatcher:[RKObjectMappingMatcher matcherWithPredicate:[NSPredicate predicateWithFormat:@"ignoredMessage.code == 5"] objectMapping:entityMapping]];
    
    [manager addResponseDescriptor:[RKResponseDescriptor responseDescriptorWithMapping:dynamicMapping method:RKRequestMethodPOST pathPattern:@"" keyPath:@"scrobbles.scrobble" statusCodes:[NSIndexSet indexSetWithIndex:200]]];
}

@end