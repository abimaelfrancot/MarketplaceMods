// MarketplaceAdBlock — drops Facebook Marketplace ads GraphQL queries.
//
// Marketplace home is React Native. Relay sends its GraphQL over RN's
// RCTNetworking module, and every request gets an "X-FB-Friendly-Name"
// header (and/or an fb_api_req_friendly_name body param) naming the query.
// We swizzle -[RCTNetworking handlerForRequest:] and, for the dedicated ads
// queries, hand back our own RCTURLRequestHandler that fails the request
// immediately. The ads QueryRenderers then get a network error and render
// nothing; real listings come from separate queries and are untouched.
//
// Search results (and some home feed pages) blend ad stories into the normal
// listing edges, so for Marketplace feed queries we also wrap the real handler,
// buffer the response, and drop array items whose __typename is an ad type.
//
// Plain ObjC runtime swizzling, no Substrate/ElleKit dependency.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/log.h>

// Set to 1 to log every friendly name that goes through RCTNetworking
// (view in Console.app, filter on "MPAdBlock"). Useful when FB renames queries.
#ifndef MPAB_LOG_ALL
#define MPAB_LOG_ALL 0
#endif

static os_log_t MPABLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.personal.mpadblock", "MPAdBlock"); });
    return log;
}

#pragma mark - Matching

static NSSet<NSString *> *MPABBlockedNames(void) {
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[
            @"MarketplaceHomeFeedAdsQueryRendererQuery",
            @"MarketplaceHomeFeedAdsPaginationQuery",
            @"MarketplaceHomeFeedBoostedListingAdsQuery",
            @"MarketplaceHomeFeedBoostedListingAdsPaginationQuery",
        ]];
    });
    return names;
}

static BOOL MPABIsBlockedName(NSString *name) {
    if (name.length == 0) return NO;
    if ([MPABBlockedNames() containsObject:name]) return YES;
    // Any other dedicated Marketplace ads query, e.g. MarketplaceHomeFeedAdsThemedQuery,
    // MarketplacePDPBoostedListingAdsQuery, MarketplacePDPPersonalizedAdsQuery,
    // MarketplaceProductDetailsPageRelatedAdsDetailQuery. "Ads" must be followed by
    // an uppercase letter so Address/Adsomething words don't match. Mutations are left alone.
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^Marketplace\\w*Ads(?:[A-Z]\\w*)?Query$" options:0 error:nil];
    });
    return [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

static NSString *MPABFriendlyName(NSURLRequest *request) {
    NSString *name = [request valueForHTTPHeaderField:@"X-FB-Friendly-Name"];
    if (name.length) return name;

    NSData *body = request.HTTPBody;
    if (body.length == 0 || body.length > 512 * 1024) return nil;
    NSString *str = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    NSRange r = [str rangeOfString:@"fb_api_req_friendly_name="];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange end = [str rangeOfString:@"&" options:0 range:NSMakeRange(start, str.length - start)];
    NSString *value = [str substringWithRange:NSMakeRange(start, (end.location == NSNotFound ? str.length : end.location) - start)];
    return value.stringByRemovingPercentEncoding ?: value;
}

#pragma mark - Failing request handler

// Conforms informally to RCTURLRequestHandler / talks to RCTURLRequestDelegate.
@protocol MPABURLRequestDelegate <NSObject>
- (void)URLRequest:(id)requestToken didCompleteWithError:(NSError *)error;
@end

@interface MPABBlockingHandler : NSObject
@end

@implementation MPABBlockingHandler

+ (instancetype)shared {
    static MPABBlockingHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [self new]; });
    return h;
}

+ (NSString *)moduleName { return @"MPABBlockingHandler"; }
- (BOOL)canHandleRequest:(NSURLRequest *)request { return MPABIsBlockedName(MPABFriendlyName(request)); }
- (float)handlerPriority { return 0; }

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id<MPABURLRequestDelegate>)delegate {
    id token = [NSUUID UUID];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorNotConnectedToInternet
                                     userInfo:@{NSLocalizedDescriptionKey: @"Blocked by MarketplaceAdBlock"}];
    // Complete asynchronously so RCTNetworkTask has stored the token first.
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate URLRequest:token didCompleteWithError:error];
    });
    return token;
}

- (void)cancelRequest:(id)requestToken {}

@end

#pragma mark - Response filtering

// Marketplace feed queries whose responses may contain blended ad stories.
static BOOL MPABIsFilteredName(NSString *name) {
    return [name hasPrefix:@"Marketplace"] && [name containsString:@"Feed"];
}

static BOOL MPABIsAdTypename(NSString *typename) {
    // MarketplaceFeedAdStory, MarketplaceSearchAdStory, ...AdsBlended..., SponsoredX.
    // Requires an uppercase letter after "Ad"/"Ads" so Additional/Address don't match.
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"Ads?[A-Z]|Sponsored" options:0 error:nil];
    });
    return typename.length && [re firstMatchInString:typename options:0 range:NSMakeRange(0, typename.length)] != nil;
}

// An edge is an ad if it, its node, or the node's story is an ad type.
static NSString *MPABAdTypenameOfItem(id item) {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableArray *candidates = [NSMutableArray arrayWithObject:item];
    for (NSString *key in @[@"node", @"story"]) {
        id v = item[key];
        if ([v isKindOfClass:[NSDictionary class]]) {
            [candidates addObject:v];
            id story = v[@"story"];
            if ([story isKindOfClass:[NSDictionary class]]) [candidates addObject:story];
        }
    }
    for (NSDictionary *c in candidates) {
        id t = c[@"__typename"];
        if ([t isKindOfClass:[NSString class]] && MPABIsAdTypename(t)) return t;
    }
    return nil;
}

static NSUInteger MPABStrip(id obj, NSMutableSet<NSString *> *seenTypes) {
    NSUInteger removed = 0;
    if ([obj isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *arr = obj;
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            id item = arr[i];
            if (seenTypes && [item isKindOfClass:[NSDictionary class]]) {
                id t = item[@"__typename"] ?: item[@"node"][@"__typename"];
                if ([t isKindOfClass:[NSString class]]) [seenTypes addObject:t];
            }
            NSString *adType = MPABAdTypenameOfItem(item);
            if (adType) {
                [arr removeObjectAtIndex:i];
                removed++;
            } else {
                removed += MPABStrip(item, seenTypes);
            }
        }
    } else if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        for (id value in [obj allValues]) removed += MPABStrip(value, seenTypes);
    }
    return removed;
}

// Returns filtered data, or the original if nothing changed or it isn't JSON.
// Handles single JSON documents and newline-separated streamed payloads.
static NSData *MPABFilterResponse(NSData *data, NSString *name) {
    if (data.length == 0) return data;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return data;

    NSString *sep = [body containsString:@"\r\n"] ? @"\r\n" : @"\n";
    NSArray<NSString *> *parts = [body componentsSeparatedByString:sep];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:parts.count];
    NSMutableSet<NSString *> *seen = MPAB_LOG_ALL ? [NSMutableSet set] : nil;
    NSUInteger removed = 0;

    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length == 0) { [out addObject:part]; continue; }
        id json = [NSJSONSerialization JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding]
                                                  options:NSJSONReadingMutableContainers error:nil];
        if (!json) return data; // multipart or something unexpected: leave untouched
        NSUInteger n = MPABStrip(json, seen);
        if (n == 0) { [out addObject:part]; continue; }
        NSData *re = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        if (!re) return data;
        [out addObject:[[NSString alloc] initWithData:re encoding:NSUTF8StringEncoding]];
        removed += n;
    }

#if MPAB_LOG_ALL
    os_log(MPABLog(), "%{public}@: %lu bytes, %lu parts, item types %{public}@",
           name, (unsigned long)data.length, (unsigned long)parts.count,
           [seen.allObjects componentsJoinedByString:@","]);
#endif
    if (removed == 0) return data;
    os_log(MPABLog(), "stripped %lu ad item(s) from %{public}@", (unsigned long)removed, name);
    return [[out componentsJoinedByString:sep] dataUsingEncoding:NSUTF8StringEncoding];
}

// Stands in for RCTNetworkTask as the inner handler's delegate. Buffers the
// body and hands the filtered result to the real delegate on completion.
// Anything else the handler calls is forwarded untouched.
@interface MPABFilteringDelegate : NSObject <MPABURLRequestDelegate>
@property (nonatomic, strong) id realDelegate;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableData *buffer;
@end

static NSMutableSet *MPABLiveDelegates(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

@implementation MPABFilteringDelegate

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.realDelegate respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel { return self.realDelegate; }

- (void)URLRequest:(id)token didReceiveData:(NSData *)data {
    @synchronized (self) { [self.buffer appendData:data]; }
}

- (void)URLRequest:(id)token didCompleteWithError:(NSError *)error {
    if (!error) {
        NSData *body;
        @synchronized (self) { body = [self.buffer copy]; }
        body = MPABFilterResponse(body, self.name);
        if (body.length) [self.realDelegate URLRequest:token didReceiveData:body];
    }
    [self.realDelegate URLRequest:token didCompleteWithError:error];
    @synchronized (MPABLiveDelegates()) { [MPABLiveDelegates() removeObject:self]; }
}

@end

// Per-request wrapper around the handler RCTNetworking picked.
@interface MPABFilteringHandler : NSObject
@property (nonatomic, strong) id inner;
@property (nonatomic, copy) NSString *name;
@end

@implementation MPABFilteringHandler

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.inner respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel { return self.inner; }

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id)delegate {
    MPABFilteringDelegate *proxy = [MPABFilteringDelegate new];
    proxy.realDelegate = delegate;
    proxy.name = self.name;
    proxy.buffer = [NSMutableData data];
    // Keep the proxy alive in case the inner handler holds delegates weakly.
    @synchronized (MPABLiveDelegates()) { [MPABLiveDelegates() addObject:proxy]; }
    return [self.inner sendRequest:request withDelegate:proxy];
}

@end

#pragma mark - Hook

static IMP orig_handlerForRequest;

static id hook_handlerForRequest(id self, SEL _cmd, NSURLRequest *request) {
    NSString *name = MPABFriendlyName(request);
#if MPAB_LOG_ALL
    if (name) os_log(MPABLog(), "query %{public}@", name);
#endif
    if (MPABIsBlockedName(name)) {
        os_log(MPABLog(), "blocked %{public}@", name);
        return [MPABBlockingHandler shared];
    }
    id handler = ((id (*)(id, SEL, NSURLRequest *))orig_handlerForRequest)(self, _cmd, request);
    if (handler && MPABIsFilteredName(name)) {
        MPABFilteringHandler *wrapper = [MPABFilteringHandler new];
        wrapper.inner = handler;
        wrapper.name = name;
        return wrapper;
    }
    return handler;
}

static void MPABTryInstall(void) {
    static BOOL installed;
    if (installed) return;
    Class cls = objc_getClass("RCTNetworking");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(handlerForRequest:));
    if (!m) {
        os_log_error(MPABLog(), "RCTNetworking has no handlerForRequest:, not hooking");
        installed = YES;
        return;
    }
    orig_handlerForRequest = method_setImplementation(m, (IMP)hook_handlerForRequest);
    installed = YES;
    os_log(MPABLog(), "hooked -[RCTNetworking handlerForRequest:]");
}

static void MPABImageAdded(const struct mach_header *mh, intptr_t slide) {
    // RCTNetworking lives in FBReactNativeProductsFramework, which may load
    // after us. Defer to the main queue so ObjC has registered the image.
    dispatch_async(dispatch_get_main_queue(), ^{ MPABTryInstall(); });
}

__attribute__((constructor))
static void MPABInit(void) {
    _dyld_register_func_for_add_image(MPABImageAdded);
}
