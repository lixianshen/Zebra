//
//  ZBDownloadManager.m
//  Zebra
//
//  Created by Wilson Styres on 4/14/19.
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

#import "ZBDownloadManager.h"
#import "UICKeyChainStore.h"
#import <ZBDevice.h>
#import <ZBLog.h>

#import <ZBAppDelegate.h>
#import <Packages/Helpers/ZBPackage.h>
#import <Sources/Helpers/ZBBaseSource.h>
#import <Sources/Helpers/ZBSource.h>
#import <Sources/Helpers/ZBSourceManager.h>

#import <bzlib.h>
#import <zlib.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <compression.h>

@interface ZBDownloadManager () {
    BOOL ignore;
    int failedTasks;
    NSMutableDictionary <NSNumber *, ZBPackage *> *packageTasksMap;
    NSMutableDictionary <NSNumber *, ZBBaseSource *> *sourceTasksMap;
}
@end

@implementation ZBDownloadManager

@synthesize downloadDelegate;
@synthesize session;

#pragma mark - Initializers

- (id)init {
    self = [super init];
    
    if (self) {
        packageTasksMap = [NSMutableDictionary new];
        sourceTasksMap = [NSMutableDictionary new];
    }
    
    return self;
}

- (id)initWithDownloadDelegate:(id <ZBDownloadDelegate>)delegate {
    self = [self init];
    
    if (self) {
        downloadDelegate = delegate;
    }
    
    return self;
}

#pragma mark - Downloading Sources

- (void)downloadSources:(NSArray <ZBBaseSource *> *_Nonnull)sources useCaching:(BOOL)useCaching {
    self->ignore = !useCaching;
    [downloadDelegate startedDownloads];
    
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSDictionary *headers = [self headers];
    if (headers == NULL) {
        [self postStatusUpdate:[NSString stringWithFormat:@"%@\n", NSLocalizedString(@"Could not determine device information.", @"")] atLevel:ZBLogLevelError];
        return;
    }
    configuration.HTTPAdditionalHeaders = headers;
    
    session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    for (ZBBaseSource *source in sources) {
        NSURLSessionTask *releaseTask = [session downloadTaskWithURL:source.releaseURL];
        
        source.releaseTaskIdentifier = releaseTask.taskIdentifier;
        [sourceTasksMap setObject:source forKey:@(releaseTask.taskIdentifier)];
        [releaseTask resume];
        
        [self downloadPackagesFileWithExtension:@"xz" fromRepo:source ignoreCaching:ignore];
        
        [downloadDelegate startedSourceDownload:source];
    }
}

- (void)downloadPackagesFileWithExtension:(NSString *_Nullable)extension fromRepo:(ZBBaseSource *)source ignoreCaching:(BOOL)ignore {
    self->ignore = ignore;
    
    NSString *filename = extension ? [NSString stringWithFormat:@"Packages.%@", extension] : @"Packages";
    NSURL *url = [source.packagesDirectoryURL URLByAppendingPathComponent:filename];
    
    NSMutableURLRequest *packagesRequest = [[NSMutableURLRequest alloc] initWithURL:url];
    if (!ignore) {
        [packagesRequest setValue:[self lastModifiedDateForFile:[self saveNameForURL:url]] forHTTPHeaderField:@"If-Modified-Since"];
    }
    
    NSURLSessionTask *packagesTask = [session downloadTaskWithRequest:packagesRequest];
    
    source.packagesTaskIdentifier = packagesTask.taskIdentifier;
    [sourceTasksMap setObject:source forKey:@(packagesTask.taskIdentifier)];
    [packagesTask resume];
}

#pragma mark - Downloading Packages

- (void)downloadPackage:(ZBPackage *)package {
    [self downloadPackages:@[package]];
}

- (void)downloadPackages:(NSArray <ZBPackage *> *)packages {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.HTTPAdditionalHeaders = [self headers];
    
    session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    for (ZBPackage *package in packages) {
        ZBSource *source = [package repo];
        NSString *filename = [package filename];
        
        if (source == NULL || filename == NULL) {
            if ([downloadDelegate respondsToSelector:@selector(postStatusUpdate:atLevel:)]) {
                [downloadDelegate postStatusUpdate:[NSString stringWithFormat:@"%@ %@ (%@)\n", NSLocalizedString(@"Could not find a download URL for", @""), package.name, package.identifier] atLevel:ZBLogLevelWarning];
            }
            ++failedTasks;
            continue;
        }
        
        NSString *baseURL = [source repositoryURI];
        NSURL *url = [NSURL URLWithString:filename];
        
        NSArray *comps = [baseURL componentsSeparatedByString:@"dists"];
        NSURL *base = [NSURL URLWithString:comps[0]];
        
        if (url && url.host && url.scheme) {
            NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url];
            [downloadTask resume];
            
            [packageTasksMap setObject:package forKey:@(downloadTask.taskIdentifier)];
            [downloadDelegate startedPackageDownload:package];
        } else if (package.sileoDownload) {
            [self realLinkWithPackage:package withCompletion:^(NSString *url) {
                NSURLSessionDownloadTask *downloadTask = [self->session downloadTaskWithURL:[NSURL URLWithString:url]];
                [downloadTask resume];
                
                [self->packageTasksMap setObject:package forKey:@(downloadTask.taskIdentifier)];
                [self->downloadDelegate startedPackageDownload:package];
            }];
        } else {
            NSURLSessionTask *downloadTask = [session downloadTaskWithURL:[base URLByAppendingPathComponent:filename]];
            [downloadTask resume];
            
            [self->packageTasksMap setObject:package forKey:@(downloadTask.taskIdentifier)];
            [downloadDelegate startedPackageDownload:package];
        }
    }
    
    if (failedTasks == packages.count) {
        failedTasks = 0;
        [self->downloadDelegate finishedAllDownloads:@{}];
    }
}

- (void)realLinkWithPackage:(ZBPackage *)package withCompletion:(void (^)(NSString *url))completionHandler{
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    UICKeyChainStore *keychain = [UICKeyChainStore keyChainStoreWithService:[ZBAppDelegate bundleID] accessGroup:nil];
    NSDictionary *test = @{ @"token": keychain[[keychain stringForKey:[package repo].repositoryURI]],
                            @"udid": [ZBDevice UDID],
                            @"device": [ZBDevice deviceModelID],
                            @"version": package.version,
                            @"repo": [NSString stringWithFormat:@"https://%@", [package repo].repositoryURI] };
    NSData *requestData = [NSJSONSerialization dataWithJSONObject:test options:(NSJSONWritingOptions)0 error:nil];
    
    NSMutableURLRequest *request = [NSMutableURLRequest new];
    [request setURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@package/%@/authorize_download", [keychain stringForKey:[package repo].repositoryURI], package.identifier]]];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Zebra/%@ iOS/%@ (%@)", PACKAGE_VERSION, [[UIDevice currentDevice] systemVersion], [ZBDevice deviceType]] forHTTPHeaderField:@"User-Agent"];
    [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)[requestData length]] forHTTPHeaderField:@"Content-Length"];
    [request setHTTPBody: requestData];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
            ZBLog(@"[Zebra] Real package data: %@", json);
            if ([json valueForKey:@"url"]) {
                NSString *returnString = json[@"url"];
                completionHandler(returnString);
            }
            
        }
        if (error) {
            NSLog(@"[Zebra] Error: %@", error.localizedDescription);
        }
    }] resume];
    
}

#pragma mark - Handling Downloaded Files

- (void)task:(NSURLSessionTask *_Nonnull)task completedDownloadedForFile:(NSString *_Nullable)path fromSource:(ZBBaseSource *_Nonnull)source withError:(NSError *_Nullable)error {
    if (error) { //An error occured, we should handle it accordingly
        if (task.taskIdentifier == source.releaseTaskIdentifier) { //This is a Release file that failed. We don't really care that much about the Release file (since we can funciton without one) but we should at least *warn* the user so that they might bug the repo maintainer :)
            NSString *description = [NSString stringWithFormat:@"Could not download Release file from %@. Reason: %@", source.repositoryURI, error.localizedDescription]; //TODO: Localize
            
            source.releaseTaskCompleted = YES;
            source.releaseFilePath = NULL;
            [self postStatusUpdate:description atLevel:ZBLogLevelWarning];
        }
        else if (task.taskIdentifier == source.packagesTaskIdentifier) { //This is a packages file that failed, we should be able to try again with a Packages.gz or a Packages file
            NSURL *url = [[task originalRequest] URL];
            if (![url pathExtension]) { //No path extension, Packages file download failed :(
                NSString *filename = [[task response] suggestedFilename];
                if ([filename pathExtension] != NULL) {
                    filename = [filename stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@".%@", [filename pathExtension]] withString:@""]; //Remove path extension
                }
                
                NSString *description = [NSString stringWithFormat:@"Could not download Packages file from %@. Reason: %@", source.repositoryURI, error.localizedDescription]; //TODO: Localize
                
                source.packagesTaskCompleted = YES;
                source.packagesFilePath = NULL;
                
                [self postStatusUpdate:description atLevel:ZBLogLevelError];
                [self cancelTasksForSource:source];
                
                [downloadDelegate finishedSourceDownload:source withErrors:@[error]];
            }
            else { //Tries to download another filetype
                NSArray *options = @[@"xz", @"bz2", @"gz", @"lzma"];
                NSUInteger nextIndex = [options indexOfObject:[url pathExtension]] + 1;
                if (nextIndex < [options count]) {
                    [self downloadPackagesFileWithExtension:[options objectAtIndex:nextIndex] fromRepo:source ignoreCaching:ignore];
                }
                else { //Should never happen but lets catch the error just in case
                    NSString *description = [NSString stringWithFormat:@"Could not download Packages file from %@. Reason: %@", source.repositoryURI, error.localizedDescription]; //TODO: Localize
                    
                    source.packagesTaskCompleted = YES;
                    source.packagesFilePath = NULL;
                    
                    [self postStatusUpdate:description atLevel:ZBLogLevelError];
                    [self cancelTasksForSource:source];
                    
                    [downloadDelegate finishedSourceDownload:source withErrors:@[error]];
                }
            }
        }
        else { //Since we cannot determine which task this is, we need to cancel the entire repo download :( (luckily this should never happen)
            NSString *description = [NSString stringWithFormat:@"Could not download one or more files from %@. Reason: %@", source.repositoryURI, error.localizedDescription]; //TODO: Localize
            
            source.packagesTaskCompleted = YES;
            source.packagesFilePath = NULL;
            source.releaseTaskCompleted = YES;
            source.releaseFilePath = NULL;
            
            [self postStatusUpdate:description atLevel:ZBLogLevelError];
            [self cancelTasksForSource:source];
            
            [downloadDelegate finishedSourceDownload:source withErrors:@[error]];
        }
    }
    else {
        if (task.taskIdentifier == source.packagesTaskIdentifier) {
            source.packagesTaskCompleted = YES;
            source.packagesFilePath = path;
        }
        else if (task.taskIdentifier == source.releaseTaskIdentifier) {
            source.releaseTaskCompleted = YES;
            source.releaseFilePath = path;
        }
        
        if (source.releaseTaskCompleted && source.packagesTaskCompleted) {
            [downloadDelegate finishedSourceDownload:source withErrors:NULL];
        }
    }
    
    //Remove task identifiers
    if (task.taskIdentifier == source.packagesTaskIdentifier) {
        source.packagesTaskIdentifier = -1;
    }
    else if (task.taskIdentifier == source.releaseTaskIdentifier) {
        source.releaseTaskIdentifier = -1;
    }
    
    [sourceTasksMap removeObjectForKey:@(task.taskIdentifier)];
    
    if (![sourceTasksMap count]) {
        [downloadDelegate finishedAllDownloads];
    }
}

- (void)handleDownloadedFile:(NSString *)path forPackage:(ZBPackage *)package withError:(NSError *)error {
    NSLog(@"Final Path: %@ Package: %@", path, package);
}

- (void)moveFileFromLocation:(NSURL *)location to:(NSString *)finalPath completion:(void (^)(NSError *error))completion {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    BOOL movedFileSuccess = NO;
    NSError *fileManagerError;
    if ([fileManager fileExistsAtPath:finalPath]) {
        movedFileSuccess = [fileManager removeItemAtPath:finalPath error:&fileManagerError];
        
        if (!movedFileSuccess && completion) {
            completion(fileManagerError);
            return;
        }
    }
    
    movedFileSuccess = [fileManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:finalPath] error:&fileManagerError];
    
    if (completion) {
        completion(fileManagerError);
    }
}

- (void)cancelAllTasksForSession:(NSURLSession *)session {
    [session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if (!dataTasks || !dataTasks.count) {
            return;
        }
        for (NSURLSessionTask *task in dataTasks) {
            [task cancel];
        }
    }];
    [packageTasksMap removeAllObjects];
    [sourceTasksMap removeAllObjects];
    [session invalidateAndCancel];
}

- (void)stopAllDownloads {
    [self cancelAllTasksForSession:session];
}

- (BOOL)isSessionOutOfTasks:(NSURLSession *)sesh {
    __block BOOL outOfTasks = NO;
    [sesh getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        outOfTasks = dataTasks.count == 0;
    }];
    
    return outOfTasks;
}

#pragma mark - Helper Methods

- (BOOL)checkForInvalidRepo:(NSString *)baseURL {
    NSURL *url = [NSURL URLWithString:baseURL];
    NSString *host = [url host];
    
    if ([ZBDevice isCheckrain]) { //checkra1n
        return ([host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"electrarepo64.coolstar.org"] || [host isEqualToString:@"repo.chimera.sh"]);
    }
    if ([ZBDevice isChimera]) { // chimera
        return ([host isEqualToString:@"checkra.in"] || [host isEqualToString:@"apt.bingner.com"] || [host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"electrarepo64.coolstar.org"]);
    }
    if ([ZBDevice isUncover]) { // uncover
        return ([host isEqualToString:@"checkra.in"] || [host isEqualToString:@"repo.chimera.sh"] || [host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"electrarepo64.coolstar.org"]);
    }
    if ([ZBDevice isElectra]) { // electra
        return ([host isEqualToString:@"checkra.in"] || [host isEqualToString:@"repo.chimera.sh"] || [host isEqualToString:@"apt.saurik.com"] || [host isEqualToString:@"apt.bingner.com"]);
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/Cydia.app"]) { // cydia
        return ([host isEqualToString:@"checkra.in"] || [host isEqualToString:@"repo.chimera.sh"] || [host isEqualToString:@"electrarepo64.coolstar.org"] || [host isEqualToString:@"apt.bingner.com"]);
    }
    
    return NO;
}

- (NSString *)guessMIMETypeForFile:(NSString *)path {
    NSString *filename = [path lastPathComponent];
    
    NSString *pathExtension = [[filename lastPathComponent] pathExtension];
    if (pathExtension != NULL && ![pathExtension isEqualToString:@""]) {
        NSString *extension = [filename pathExtension];
        
        if ([extension isEqualToString:@"txt"]) { //Likely Packages.txt or Release.txt
            return @"text/plain";
        }
        else if ([extension containsString:@"deb"]) { //A deb
            return @"application/x-deb";
        }
        else if ([extension isEqualToString:@"bz2"]) { //.bz2
            return @"application/x-bzip2";
        }
        else if ([extension isEqualToString:@"gz"]) { //.gz
            return @"application/x-gzip";
        }
        else if ([extension isEqualToString:@"xz"]) { //.xz
            return @"application/x-xz";
        }
        else if ([extension isEqualToString:@"lzma"]) { //.lzma
            return @"application/x-lzma";
        }
    }
    // We're going to assume this is a Release or uncompressed Packages file
    return @"text/plain";
}

- (NSString *)saveNameForURL:(NSURL *)url {
    NSString *filename = [url lastPathComponent]; //Releases
    NSString *schemeless = [[[[url URLByDeletingLastPathComponent] absoluteString] stringByReplacingOccurrencesOfString:[url scheme] withString:@""] substringFromIndex:3]; //Removes scheme and ://
    NSString *baseFilename = [schemeless stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [baseFilename stringByAppendingString:filename];
}

#pragma mark - Session Headers

- (NSDictionary *)headers {
    NSString *version = [[UIDevice currentDevice] systemVersion];
    NSString *udid = [ZBDevice UDID];
    NSString *machineIdentifier = [ZBDevice machineID];
    
    return @{@"X-Cydia-ID" : udid, @"User-Agent" : @"Telesphoreo APT-HTTP/1.0.592", @"X-Firmware": version, @"X-Unique-ID" : udid, @"X-Machine" : machineIdentifier};
}

- (NSString *)lastModifiedDateForFile:(NSString *)filename {
    NSString *path = [[ZBAppDelegate listsLocation] stringByAppendingPathComponent:filename];
    
    NSError *fileError;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&fileError];
    NSDate *date = fileError != nil ? [NSDate distantPast] : [attributes fileModificationDate];
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    NSTimeZone *gmt = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    [formatter setTimeZone:gmt];
    [formatter setDateFormat:@"E, d MMM yyyy HH:mm:ss"];
    
    return [NSString stringWithFormat:@"%@ GMT", [formatter stringFromDate:date]];
}

#pragma mark - URL Session Delegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSURLResponse *response = [downloadTask response];
    NSInteger responseCode = [(NSHTTPURLResponse *)response statusCode];
    
    if (responseCode == 304) {
        //Since we should never get a 304 for a deb, we can assume this is from a repo.
        ZBBaseSource *source = [sourceTasksMap objectForKey:@(downloadTask.taskIdentifier)];
        
        [self task:downloadTask completedDownloadedForFile:NULL fromSource:source withError:NULL];
        return;
    }
    
    NSString *MIMEType = [response MIMEType];
    NSArray *acceptableMIMETypes = @[@"text/plain", @"application/x-xz", @"application/x-bzip2", @"application/x-gzip", @"application/x-lzma", @"application/x-deb", @"application/x-debian-package"];
    NSUInteger index = [acceptableMIMETypes indexOfObject:MIMEType];
    if (index == NSNotFound) {
        MIMEType = [self guessMIMETypeForFile:[[response URL] absoluteString]];
        index = [acceptableMIMETypes indexOfObject:MIMEType];
    }
    
    BOOL downloadFailed = (responseCode != 200 && responseCode != 304);
    switch (index) {
        case 0: { //Uncompressed Packages file or a Release file
            ZBBaseSource *source = [sourceTasksMap objectForKey:@(downloadTask.taskIdentifier)];
            if (source) {
                if (downloadFailed) {
                    NSString *suggestedFilename = [response suggestedFilename];
                    NSError *error = [self errorForHTTPStatusCode:responseCode forFile:suggestedFilename];
                    
                    [self task:downloadTask completedDownloadedForFile:[[response URL] absoluteString] fromSource:source withError:error];
                }
                else {
                    NSString *suggestedFilename = [response suggestedFilename];
                    if ([suggestedFilename pathExtension] != NULL) {
                        suggestedFilename = [suggestedFilename stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@".%@", [suggestedFilename pathExtension]] withString:@""]; //Remove path extension from Packages or Release
                    }
                    
                    //Move the file to the save name location
                    NSString *listsPath = [ZBAppDelegate listsLocation];
                    NSString *saveName = [self saveNameForURL:[response URL]];
                    NSString *finalPath = [listsPath stringByAppendingPathComponent:saveName];
                    [self moveFileFromLocation:location to:finalPath completion:^(NSError *error) {
                        [self task:downloadTask completedDownloadedForFile:finalPath fromSource:source withError:error];
                    }];
                }
            }
            else {
                NSLog(@"[Zebra] Unable to determine ZBBaseRepo associated with %lu. This should be looked into.", (unsigned long)downloadTask.taskIdentifier);
            }
            break;
        }
        case 1:
        case 2:
        case 3:
        case 4: { //Compressed packages file (.xz, .bz2, .gz, or .lzma)
            ZBBaseSource *source = [sourceTasksMap objectForKey:@(downloadTask.taskIdentifier)];
            if (source) {
                if (downloadFailed) {
                    NSString *suggestedFilename = [response suggestedFilename];
                    NSError *error = [self errorForHTTPStatusCode:responseCode forFile:suggestedFilename];
                    
                    [self task:downloadTask completedDownloadedForFile:[[response URL] absoluteString] fromSource:source withError:error];
                }
                else {
                    //Move the file to the save name location
                    NSString *listsPath = [ZBAppDelegate listsLocation];
                    NSString *saveName = [self saveNameForURL:[response URL]];
                    NSString *finalPath = [listsPath stringByAppendingPathComponent:saveName];
                    [self moveFileFromLocation:location to:finalPath completion:^(NSError *error) {
                        if (error) {
                            [self task:downloadTask completedDownloadedForFile:finalPath fromSource:source withError:error];
                        }
                        else {
                            NSError *error;
                            NSString *decompressedFilePath;
                            @try {
                                decompressedFilePath = [self decompressFile:finalPath compressionType:MIMEType];
                            } @catch (NSException *exception) {
                                NSString *description = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason];
                                error = [NSError errorWithDomain:NSPOSIXErrorDomain code:1337 userInfo:@{NSLocalizedDescriptionKey: description}];
                            } @finally {
                                [self task:downloadTask completedDownloadedForFile:decompressedFilePath fromSource:source withError:error];
                            }
                        }
                    }];
                }
            }
            else {
                NSLog(@"[Zebra] Unable to determine ZBBaseRepo associated with %lu.", (unsigned long)downloadTask.taskIdentifier);
            }
            break;
        }
        case 5:
        case 6: { //Package.deb
            ZBPackage *package = [packageTasksMap objectForKey:@(downloadTask.taskIdentifier)];
            NSLog(@"[Zebra] Successfully downloaded file for %@", package);
            
            //forward to handler
            break;
        }
        default: { //We couldn't determine the file
            NSString *text = [NSString stringWithFormat:NSLocalizedString(@"Could not parse %@ from %@", @""), [response suggestedFilename], [response URL]];
            [downloadDelegate postStatusUpdate:text atLevel:ZBLogLevelError];
            break;
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *taskIdentifier = @(task.taskIdentifier);
    if (error) {
        ZBPackage *package = packageTasksMap[taskIdentifier];
        if (package) {
            [downloadDelegate finishedPackageDownload:package withError:error];
        }
        else { //This should be a repo
            ZBBaseSource *source = [sourceTasksMap objectForKey:@(task.taskIdentifier)];
            [self task:task completedDownloadedForFile:NULL fromSource:source withError:error];
        }
    }
    [packageTasksMap removeObjectForKey:@(task.taskIdentifier)];
    [sourceTasksMap removeObjectForKey:@(task.taskIdentifier)];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite == -1) {
        return;
    }
    ZBPackage *package = packageTasksMap[@(downloadTask.taskIdentifier)];
    if (package) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->downloadDelegate progressUpdate:((double)totalBytesWritten / totalBytesExpectedToWrite) forPackage:package];
            });
        });
    }
}

#pragma mark - Logging

- (void)postStatusUpdate:(NSString *)update atLevel:(ZBLogLevel)level {
    if (downloadDelegate && [downloadDelegate respondsToSelector:@selector(postStatusUpdate:atLevel:)]) {
        [downloadDelegate postStatusUpdate:update atLevel:level];
    }
}

- (NSString *)decompressFile:(NSString *)path compressionType:(NSString *_Nullable)compressionType {
    if (!compressionType) {
        compressionType = [self guessMIMETypeForFile:path];
    }
    
    NSArray *availableTypes = @[@"application/x-gzip", @"application/x-bzip2", @"application/x-xz", @"application/x-lzma"];
    switch ([availableTypes indexOfObject:compressionType]) {
        case 0: {
            NSData *data = [NSData dataWithContentsOfFile:path];
            
            z_stream stream;
            stream.zalloc = Z_NULL;
            stream.zfree = Z_NULL;
            stream.avail_in = (uint)data.length;
            stream.next_in = (Bytef *)data.bytes;
            stream.total_out = 0;
            stream.avail_out = 0;
            
            NSMutableData *output = nil;
            if (inflateInit2(&stream, 47) == Z_OK) {
                int status = Z_OK;
                output = [NSMutableData dataWithCapacity:data.length * 2];
                while (status == Z_OK) {
                    if (stream.total_out >= output.length) {
                        output.length += data.length / 2;
                    }
                    stream.next_out = (uint8_t *)output.mutableBytes + stream.total_out;
                    stream.avail_out = (uInt)(output.length - stream.total_out);
                    status = inflate (&stream, Z_SYNC_FLUSH);
                }
                if (inflateEnd(&stream) == Z_OK && status == Z_STREAM_END) {
                    output.length = stream.total_out;
                }
            }
            
            [output writeToFile:[path stringByDeletingPathExtension] atomically:NO];
            
            NSError *removeError;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
            if (removeError) {
                @throw [NSException exceptionWithName:removeError.localizedDescription reason:removeError.localizedRecoverySuggestion userInfo:nil];
            }
            
            return [path stringByDeletingPathExtension];
        }
        case 1: {
            FILE *f = fopen([path UTF8String], "r");
            FILE *output = fopen([[path stringByDeletingPathExtension] UTF8String], "w");
            
            int bzError = BZ_OK;
            char buf[4096];
            
            BZFILE *bzf = BZ2_bzReadOpen(&bzError, f, 0, 0, NULL, 0);
            if (bzError != BZ_OK) {
                BZ2_bzReadClose(&bzError, bzf);
                fclose(f);
                fclose(output);
                
                @throw [self bz2ExceptionForCode:bzError file:path];
            }
            
            while (bzError == BZ_OK) {
                int nread = BZ2_bzRead(&bzError, bzf, buf, sizeof buf);
                if (bzError == BZ_OK || bzError == BZ_STREAM_END) {
                    size_t nwritten = fwrite(buf, 1, nread, output);
                    if (nwritten != (size_t)nread) {
                        BZ2_bzReadClose(&bzError, bzf);
                        fclose(f);
                        fclose(output);
                        
                        @throw [NSException exceptionWithName:@"Short Write" reason:@"Did not write enough information to output" userInfo:nil];
                    }
                }
                else {
                    BZ2_bzReadClose(&bzError, bzf);
                    fclose(f);
                    fclose(output);
                    
                    @throw [self bz2ExceptionForCode:bzError file:path];
                }
            }
            
            BZ2_bzReadClose(&bzError, bzf);
            fclose(f);
            fclose(output);
            
            NSError *removeError;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
            if (removeError) {
                @throw [NSException exceptionWithName:removeError.localizedDescription reason:removeError.localizedRecoverySuggestion userInfo:nil];
            }
            
            return [path stringByDeletingPathExtension]; //Should be our unzipped file
        }
        case 2:
        case 3: {
            compression_stream stream;
            compression_status status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA);
            if (status == COMPRESSION_STATUS_ERROR) {
                @throw [NSException exceptionWithName:@"Compression Status Error" reason:@"Not a proper .XZ or .LZMA archive" userInfo:nil];
            }

            NSData *compressedData = [NSData dataWithContentsOfFile:path];
            stream.src_ptr = compressedData.bytes;
            stream.src_size = compressedData.length;

            size_t destinationBufferSize = 4096;
            uint8_t *destinationBuffer = malloc(destinationBufferSize);
            stream.dst_ptr = destinationBuffer;
            stream.dst_size = destinationBufferSize;
            
            NSMutableData *decompressedData = [NSMutableData new];

            do {
                status = compression_stream_process(&stream, 0);
                
                switch (status) {
                    case COMPRESSION_STATUS_OK:
                        if (stream.dst_size == 0) {
                            [decompressedData appendBytes:destinationBuffer length:destinationBufferSize];
                            
                            stream.dst_ptr = destinationBuffer;
                            stream.dst_size = destinationBufferSize;
                        }
                        break;
                        
                    case COMPRESSION_STATUS_END:
                        if (stream.dst_ptr > destinationBuffer) {
                            [decompressedData appendBytes:destinationBuffer length:stream.dst_ptr - destinationBuffer];
                        }
                        break;
                        
                    case COMPRESSION_STATUS_ERROR:
                        @throw [NSException exceptionWithName:@"Compression Status Error" reason:@"Not a proper .XZ or .LZMA archive" userInfo:nil];
                        break;
                        
                    default:
                        break;
                }
            } while (status == COMPRESSION_STATUS_OK);

            compression_stream_destroy(&stream);
            [decompressedData writeToFile:[path stringByDeletingPathExtension] atomically:YES];
            
            NSError *removeError;
            [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
            if (removeError) {
                @throw [NSException exceptionWithName:removeError.localizedDescription reason:removeError.localizedRecoverySuggestion userInfo:nil];
            }
            
            return [path stringByDeletingPathExtension];
        }
        default: { //Decompression of this file is not supported (ideally this should never happen but we'll keep it in case we support more compression types in the future)
            return path;
        }
    }
}

- (NSException *)bz2ExceptionForCode:(int)bzError file:(NSString *)file {
    NSDictionary *userInfo = @{@"Failing-File": file};
    switch (bzError) {
        case BZ_CONFIG_ERROR:
            return [NSException exceptionWithName:@"Configuration Error" reason:@"The bzip2 library has been mis-compiled." userInfo:userInfo];
        case BZ_PARAM_ERROR:
            return [NSException exceptionWithName:@"Parameter Error" reason:@"One of the configured parameters is incorrect." userInfo:userInfo];
        case BZ_IO_ERROR:
            return [NSException exceptionWithName:@"IO Error" reason:@"Error reading from compressed file." userInfo:userInfo];
        case BZ_MEM_ERROR:
            return [NSException exceptionWithName:@"Memory Error" reason:@"Insufficient memory is available." userInfo:userInfo];
        case BZ_UNEXPECTED_EOF:
            return [NSException exceptionWithName:@"Unexpected EOF" reason:@"The compressed file ended before the logical end-of-stream was detected" userInfo:userInfo];
        case BZ_DATA_ERROR:
            return [NSException exceptionWithName:@"Data Error" reason:@"A Data Integrity Error was detected in the compressed stream" userInfo:userInfo];
        case BZ_DATA_ERROR_MAGIC:
            return [NSException exceptionWithName:@"Data Error" reason:@"Compressed stream is not a bzip2 data file." userInfo:userInfo];
        default:
            return [NSException exceptionWithName:@"Unknown BZ2 error" reason:[NSString stringWithFormat:@"bzError: %d", bzError] userInfo:userInfo];
    }
}

- (NSError *)errorForHTTPStatusCode:(NSUInteger)statusCode forFile:(NSString *)file {
    NSString *reasonPhrase = (__bridge_transfer NSString *)CFHTTPMessageCopyResponseStatusLine(CFHTTPMessageCreateResponse(kCFAllocatorDefault, statusCode, NULL, kCFHTTPVersion1_1));
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:statusCode userInfo:@{NSLocalizedDescriptionKey: [reasonPhrase stringByAppendingFormat:@": %@\n", file]}];
    
    return error;
}

- (void)cancelTasksForSource:(ZBBaseSource *)source {
    [session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> * _Nonnull tasks) {
        for (NSURLSessionTask *task in tasks) {
            if (task.taskIdentifier == source.packagesTaskIdentifier || task.taskIdentifier == source.releaseTaskIdentifier) {
                [task cancel];
            }
        }
    }];
}

@end
