/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageManager.h"
#import <objc/message.h>

@interface SDWebImageCombinedOperation : NSObject <SDWebImageOperation>

@property (assign, nonatomic, getter = isCancelled) BOOL cancelled;
@property (copy, nonatomic) void (^cancelBlock)();

@end

@interface SDWebImageManager ()

@property (strong, nonatomic, readwrite) SDImageCache *imageCache;
@property (strong, nonatomic, readwrite) SDWebImageDownloader *imageDownloader;
@property (strong, nonatomic) NSMutableArray *failedURLs;
@property (strong, nonatomic) NSMutableArray *runningOperations;

@end

@implementation SDWebImageManager

+ (id)sharedManager
{
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{instance = self.new;});
    return instance;
}

- (id)init
{
    if ((self = [super init]))
    {
        _imageCache = [SDImageCache sharedImageCache];
        _imageDownloader = SDWebImageDownloader.new;
        _failedURLs = NSMutableArray.new;
        _runningOperations = NSMutableArray.new;
        _dispatchedOnMainThread = YES;
    }
    return self;
}


- (NSString *)cacheKeyForURL:(NSURL *)url
{
    if (self.cacheKeyFilter)
    {
        return self.cacheKeyFilter(url);
    }
    else
    {
        return [url absoluteString];
    }
}

- (id<SDWebImageOperation>)downloadWithURL:(NSURL *)url queue:(dispatch_queue_t)queue options:(SDWebImageOptions)options progress:(SDWebImageDownloaderProgressBlock)progressBlock completed:(SDWebImageCompletedWithFinishedBlock)completedBlock {
    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, XCode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    if ([url isKindOfClass:NSString.class])
    {
        url = [NSURL URLWithString:(NSString *)url];
    }

    // Prevents app crashing on argument type error like sending NSNull instead of NSURL
    if (![url isKindOfClass:NSURL.class])
    {
        url = nil;
    }

    __block SDWebImageCombinedOperation *operation = SDWebImageCombinedOperation.new;
    __weak SDWebImageCombinedOperation *weakOperation = operation;
    
    if (!url || !completedBlock || (!(options & SDWebImageRetryFailed) && [self.failedURLs containsObject:url]))
    {
        if (completedBlock) completedBlock(nil, nil, SDImageCacheTypeNone, NO);
        return operation;
    }

    @synchronized(self.runningOperations)
    {
        [self.runningOperations addObject:operation];
    }
    NSString *key = [self cacheKeyForURL:url];

    [self.imageCache queryDiskCacheForKey:key queue:queue done:^(UIImage *image, SDImageCacheType cacheType)
    {
        if (operation.isCancelled) return;

        if (image)
        {
            completedBlock(image, nil, cacheType, YES);
            @synchronized(self.runningOperations)
            {
                [self.runningOperations removeObject:operation];
            }
        }
        else if (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url])
        {
            SDWebImageDownloaderOptions downloaderOptions = 0;
            if (options & SDWebImageLowPriority) downloaderOptions |= SDWebImageDownloaderLowPriority;
            if (options & SDWebImageProgressiveDownload) downloaderOptions |= SDWebImageDownloaderProgressiveDownload;
            __block id<SDWebImageOperation> subOperation = [self.imageDownloader downloadImageWithURL:url options:downloaderOptions progress:progressBlock completed:^(UIImage *downloadedImage, NSData *data, NSError *error, BOOL finished)
            {
                if (weakOperation.cancelled)
                {
                    completedBlock(nil, nil, SDImageCacheTypeNone, finished);
                }
                else if (error)
                {
                    completedBlock(nil, error, SDImageCacheTypeNone, finished);

                    if (error.code != NSURLErrorNotConnectedToInternet)
                    {
                        @synchronized(self.failedURLs)
                        {
                            [self.failedURLs addObject:url];
                        }
                    }
                }
                else
                {
                    const BOOL cacheOnDisk = !(options & SDWebImageCacheMemoryOnly);

                    if (downloadedImage && [self.delegate respondsToSelector:@selector(imageManager:transformDownloadedImage:withURL:)])
                    {
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^
                        {
                            UIImage *transformedImage = [self.delegate imageManager:self transformDownloadedImage:downloadedImage withURL:url];

                            dispatch_async(queue, ^
                            {
                                completedBlock(transformedImage, nil, SDImageCacheTypeNone, finished);
                            });

                            if (transformedImage && finished)
                            {
                                [self.imageCache storeImage:transformedImage imageData:data forKey:key toDisk:cacheOnDisk];
                            }
                        });
                    }
                    else
                    {
                        completedBlock(downloadedImage, nil, SDImageCacheTypeNone, finished);

                        if (downloadedImage && finished)
                        {
                            [self.imageCache storeImage:downloadedImage imageData:data forKey:key toDisk:cacheOnDisk];
                        }
                    }
                }

                if (finished)
                {
                    @synchronized(self.runningOperations)
                    {
                        [self.runningOperations removeObject:operation];
                    }
                }
            }];
            operation.cancelBlock = ^{[subOperation cancel];};
        }
        else
        {
            // Image not in cache and download disallowed by delegate
            completedBlock(nil, nil, SDImageCacheTypeNone, YES);
            @synchronized(self.runningOperations)
            {
                [self.runningOperations removeObject:operation];
            }
        }
    }];

    return operation;

}

- (id<SDWebImageOperation>)downloadWithURL:(NSURL *)url options:(SDWebImageOptions)options progress:(SDWebImageDownloaderProgressBlock)progressBlock completed:(SDWebImageCompletedWithFinishedBlock)completedBlock
{    
    dispatch_queue_t queue = (self.dispatchedOnMainThread ? dispatch_get_main_queue() : nil);
    return [self downloadWithURL:url queue:queue options:options progress:progressBlock completed:completedBlock];
}

- (void)cancelAll
{
    @synchronized(self.runningOperations)
    {
        [self.runningOperations makeObjectsPerformSelector:@selector(cancel)];
        [self.runningOperations removeAllObjects];
    }
}

- (BOOL)isRunning
{
    return self.runningOperations.count > 0;
}

@end

@implementation SDWebImageCombinedOperation

- (void)setCancelBlock:(void (^)())cancelBlock
{
    if (self.isCancelled)
    {
        if (cancelBlock) cancelBlock();
    }
    else
    {
        _cancelBlock = [cancelBlock copy];
    }
}

- (void)cancel
{
    self.cancelled = YES;
    if (self.cancelBlock)
    {
        self.cancelBlock();
        self.cancelBlock = nil;
    }
}

@end
