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
// The same response pass also does the listing-level features below (home feed
// only, search results are left alone):
//   - hide listings you have already seen
//   - hide listings older than N hours
//   - sort each page of listings newest first
// And once per Marketplace visit we try to switch to the "Local" tab.
//
// Plain ObjC runtime swizzling, no Substrate/ElleKit dependency.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/log.h>

// Set to 1 to log every friendly name that goes through RCTNetworking
// (view in Console.app, filter on "MPAdBlock"). Useful when FB renames queries.
#ifndef MPAB_LOG_ALL
#define MPAB_LOG_ALL 0
#endif

// Feature defaults. Override at build time (see build.sh) or at runtime with the
// NSUserDefaults keys named next to each one.
#ifndef MPAB_HIDE_SEEN            // MPABHideSeen
#define MPAB_HIDE_SEEN 1
#endif
#ifndef MPAB_SEEN_ON_IMPRESSION   // MPABSeenOnImpression: 1 = seen once delivered in a feed page, 0 = only once opened
#define MPAB_SEEN_ON_IMPRESSION 1
#endif
#ifndef MPAB_MAX_AGE_HOURS        // MPABMaxAgeHours: 0 = no age filter
#define MPAB_MAX_AGE_HOURS 168
#endif
#ifndef MPAB_SORT_NEWEST          // MPABSortNewest
#define MPAB_SORT_NEWEST 1
#endif
#ifndef MPAB_DEFAULT_LOCAL_TAB    // MPABDefaultLocalTab
#define MPAB_DEFAULT_LOCAL_TAB 1
#endif
#ifndef MPAB_LOCAL_TAB_LABEL      // MPABLocalTabLabel
#define MPAB_LOCAL_TAB_LABEL "Local"
#endif

static os_log_t MPABLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.personal.mpadblock", "MPAdBlock"); });
    return log;
}

#pragma mark - Preferences

static BOOL MPABPref(NSString *key, BOOL def) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : def;
}

static double MPABPrefNum(NSString *key, double def) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v doubleValue] : def;
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

// The GraphQL "variables" JSON of a form-encoded request, or nil.
static NSDictionary *MPABRequestVariables(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (body.length == 0 || body.length > 512 * 1024) return nil;
    NSString *str = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    NSRange r = [str rangeOfString:@"variables="];
    if (r.location == NSNotFound) return nil;
    if (r.location > 0 && [str characterAtIndex:r.location - 1] != '&') return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange end = [str rangeOfString:@"&" options:0 range:NSMakeRange(start, str.length - start)];
    NSString *value = [str substringWithRange:NSMakeRange(start, (end.location == NSNotFound ? str.length : end.location) - start)];
    value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    value = value.stringByRemovingPercentEncoding ?: value;
    id json = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
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

#pragma mark - Seen store

static NSString *const kMPABSeenKey = @"MPABSeenIDs";
static const NSUInteger kMPABSeenCap = 20000;

static NSMutableOrderedSet<NSString *> *MPABSeen(void) {
    static NSMutableOrderedSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:kMPABSeenKey];
        set = saved ? [NSMutableOrderedSet orderedSetWithArray:saved] : [NSMutableOrderedSet orderedSet];
    });
    return set;
}

static void MPABScheduleSeenSave(void) {
    static BOOL pending;
    @synchronized (MPABSeen()) {
        if (pending) return;
        pending = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *snapshot;
        @synchronized (MPABSeen()) {
            pending = NO;
            snapshot = [NSArray arrayWithArray:MPABSeen().array];
        }
        [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:kMPABSeenKey];
    });
}

static BOOL MPABIsSeen(NSString *lid) {
    @synchronized (MPABSeen()) { return [MPABSeen() containsObject:lid]; }
}

static void MPABMarkSeen(NSString *lid) {
    if (lid.length == 0) return;
    @synchronized (MPABSeen()) {
        NSMutableOrderedSet *set = MPABSeen();
        [set removeObject:lid];   // re-add at the end so the cap evicts the oldest
        [set addObject:lid];
        if (set.count > kMPABSeenCap) [set removeObjectsInRange:NSMakeRange(0, set.count - kMPABSeenCap)];
    }
    MPABScheduleSeenSave();
}

#pragma mark - Listing helpers

static BOOL MPABIsDict(id o) { return [o isKindOfClass:[NSDictionary class]]; }

// The dictionary holding a listing's own fields (id, creation time, ...) for a
// feed edge, or nil if the item isn't a listing. Feed edges look like
// {node: {__typename: "MarketplaceFeedListingStoryObject", listing: {id, ...}}}.
static NSDictionary *MPABListingDict(id item) {
    if (!MPABIsDict(item)) return nil;
    NSDictionary *node = MPABIsDict(item[@"node"]) ? item[@"node"] : nil;
    NSArray *cands = node ? @[item, node] : @[item];
    for (NSDictionary *c in cands) {
        NSDictionary *l = MPABIsDict(c[@"listing"]) ? c[@"listing"] : nil;
        if (l && l[@"id"]) return l;
    }
    // Some feeds put the listing fields straight on the node.
    for (NSDictionary *c in cands) {
        NSString *t = c[@"__typename"];
        if ([t isKindOfClass:[NSString class]] &&
            ([t containsString:@"Listing"] || [t containsString:@"ProductItem"]) && c[@"id"]) return c;
    }
    return nil;
}

static NSString *MPABListingID(NSDictionary *listing) {
    id v = listing[@"id"];
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return nil;
}

// Seconds since epoch, or 0 if the listing carries no usable time.
static NSTimeInterval MPABListingTime(NSDictionary *listing) {
    for (NSString *key in @[@"creation_time", @"creationTime", @"listing_creation_time",
                            @"created_time", @"creation_timestamp"]) {
        id v = listing[key];
        if (![v isKindOfClass:[NSNumber class]] && ![v isKindOfClass:[NSString class]]) continue;
        double d = [v doubleValue];
        if (d > 1e11) d /= 1000.0;   // milliseconds
        if (d > 1e9) return d;       // anything earlier is not a plausible timestamp
    }
    return 0;
}

typedef struct {
    BOOL hideSeen, markSeen, sortNewest;
    NSTimeInterval maxAgeSec;       // 0 = off
    NSUInteger ads, seen, old, reordered, listings, timed;
} MPABCtx;

static NSUInteger MPABCtxChanges(const MPABCtx *c) { return c->ads + c->seen + c->old + c->reordered; }

// Hide seen/old listings, remember what was shown, and sort newest first.
// Sorting only moves timed listings among their own slots, so a listing with no
// timestamp keeps its position and nothing is ever dropped for lacking one.
static void MPABProcessListings(NSMutableArray *arr, MPABCtx *ctx) {
    if (!(ctx->hideSeen || ctx->markSeen || ctx->sortNewest || ctx->maxAgeSec > 0)) return;

    BOOL hasListing = NO;
    for (id item in arr) { if (MPABListingDict(item)) { hasListing = YES; break; } }
    if (!hasListing) return;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableArray<NSString *> *survivors = [NSMutableArray array];

    for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
        NSDictionary *listing = MPABListingDict(arr[i]);
        if (!listing) continue;
        ctx->listings++;
        NSTimeInterval t = MPABListingTime(listing);
        if (t > 0) ctx->timed++;
        NSString *lid = MPABListingID(listing);
        if (ctx->hideSeen && lid && MPABIsSeen(lid)) {
            [arr removeObjectAtIndex:i];
            ctx->seen++;
            continue;
        }
        if (ctx->maxAgeSec > 0 && t > 0 && now - t > ctx->maxAgeSec) {
            [arr removeObjectAtIndex:i];
            ctx->old++;
            continue;
        }
        if (lid) [survivors addObject:lid];
    }
    // Mark after the filtering pass so a duplicate inside one page isn't hidden.
    if (ctx->markSeen) for (NSString *lid in survivors) MPABMarkSeen(lid);

    if (ctx->sortNewest) {
        NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
        NSMutableArray *timed = [NSMutableArray array];
        for (NSUInteger i = 0; i < arr.count; i++) {
            NSDictionary *listing = MPABListingDict(arr[i]);
            if (listing && MPABListingTime(listing) > 0) { [slots addObject:@(i)]; [timed addObject:arr[i]]; }
        }
        if (timed.count >= 2) {
            NSArray *sorted = [timed sortedArrayWithOptions:NSSortStable
                                            usingComparator:^NSComparisonResult(id a, id b) {
                NSTimeInterval ta = MPABListingTime(MPABListingDict(a));
                NSTimeInterval tb = MPABListingTime(MPABListingDict(b));
                return ta > tb ? NSOrderedAscending : (ta < tb ? NSOrderedDescending : NSOrderedSame);
            }];
            for (NSUInteger k = 0; k < slots.count; k++) {
                NSUInteger idx = slots[k].unsignedIntegerValue;
                if (arr[idx] != sorted[k]) { arr[idx] = sorted[k]; ctx->reordered++; }
            }
        }
    }
}

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

static void MPABStrip(id obj, NSMutableSet<NSString *> *seenTypes, MPABCtx *ctx) {
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
                ctx->ads++;
            } else {
                MPABStrip(item, seenTypes, ctx);
            }
        }
        MPABProcessListings(arr, ctx);
    } else if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        for (id value in [obj allValues]) MPABStrip(value, seenTypes, ctx);
    }
}

// Returns filtered data, or the original if nothing changed or it isn't JSON.
// Handles single JSON documents and newline-separated streamed payloads.
static NSData *MPABFilterResponse(NSData *data, NSString *name) {
    if (data.length == 0) return data;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return data;

    // Listing features are for the home feed; search results keep FB's order.
    BOOL isSearch = [name containsString:@"Search"];
    MPABCtx ctx = {0};
    ctx.hideSeen = !isSearch && MPABPref(@"MPABHideSeen", MPAB_HIDE_SEEN);
    ctx.markSeen = ctx.hideSeen && MPABPref(@"MPABSeenOnImpression", MPAB_SEEN_ON_IMPRESSION);
    ctx.sortNewest = !isSearch && MPABPref(@"MPABSortNewest", MPAB_SORT_NEWEST);
    ctx.maxAgeSec = isSearch ? 0 : MAX(0, MPABPrefNum(@"MPABMaxAgeHours", MPAB_MAX_AGE_HOURS)) * 3600.0;

    NSString *sep = [body containsString:@"\r\n"] ? @"\r\n" : @"\n";
    NSArray<NSString *> *parts = [body componentsSeparatedByString:sep];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:parts.count];
    NSMutableSet<NSString *> *seen = MPAB_LOG_ALL ? [NSMutableSet set] : nil;

    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length == 0) { [out addObject:part]; continue; }
        id json = [NSJSONSerialization JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding]
                                                  options:NSJSONReadingMutableContainers error:nil];
        if (!json) return data; // multipart or something unexpected: leave untouched
        NSUInteger before = MPABCtxChanges(&ctx);
        MPABStrip(json, seen, &ctx);
        if (MPABCtxChanges(&ctx) == before) { [out addObject:part]; continue; }
        NSData *re = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        if (!re) return data;
        [out addObject:[[NSString alloc] initWithData:re encoding:NSUTF8StringEncoding]];
    }

#if MPAB_LOG_ALL
    os_log(MPABLog(), "%{public}@: %lu bytes, %lu parts, item types %{public}@, listings %lu (%lu with a time)",
           name, (unsigned long)data.length, (unsigned long)parts.count,
           [seen.allObjects componentsJoinedByString:@","],
           (unsigned long)ctx.listings, (unsigned long)ctx.timed);
#endif
    if (MPABCtxChanges(&ctx) == 0) return data;
    os_log(MPABLog(), "%{public}@: stripped %lu ad(s), hid %lu seen + %lu old, moved %lu",
           name, (unsigned long)ctx.ads, (unsigned long)ctx.seen,
           (unsigned long)ctx.old, (unsigned long)ctx.reordered);
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

#pragma mark - Opened listings

// Listing detail queries (MarketplacePDP...Query) carry the listing id in their
// variables. Opening a listing always counts as seen, whatever the seen mode.
static BOOL MPABIsListingOpenName(NSString *name) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^MarketplacePDP\\w*Query$" options:0 error:nil];
    });
    return name.length && [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

static void MPABNoteOpenedListing(NSURLRequest *request) {
    NSDictionary *vars = MPABRequestVariables(request);
    if (!vars) return;
    for (NSString *key in @[@"targetId", @"listingId", @"listing_id", @"productId", @"id"]) {
        id v = vars[key];
        NSString *lid = [v isKindOfClass:[NSString class]] ? v : ([v isKindOfClass:[NSNumber class]] ? [v stringValue] : nil);
        if (lid.length) { MPABMarkSeen(lid); return; }
    }
}

#pragma mark - Default to the Local tab

static UIView *MPABFindTab(UIView *root, NSString *label, int depth) {
    if (depth > 80) return nil;
    NSString *l = root.accessibilityLabel;
    if (l.length && !root.hidden && root.alpha > 0.01 &&
        ([l caseInsensitiveCompare:label] == NSOrderedSame ||
         [l.lowercaseString hasPrefix:[label.lowercaseString stringByAppendingString:@","]])) return root;
    for (UIView *sub in root.subviews) {
        UIView *f = MPABFindTab(sub, label, depth + 1);
        if (f) return f;
    }
    return nil;
}

static void MPABTryLocalTab(NSUInteger attempt) {
    if (attempt > 20) {
        os_log(MPABLog(), "Local tab not found, giving up");
        return;
    }
    NSString *label = [NSUserDefaults.standardUserDefaults stringForKey:@"MPABLocalTabLabel"];
    if (label.length == 0) label = @MPAB_LOCAL_TAB_LABEL;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *tab = MPABFindTab(window, label, 0);
            if (!tab) continue;
            if (tab.accessibilityTraits & UIAccessibilityTraitSelected) return; // already there
            BOOL ok = [tab accessibilityActivate];
            os_log(MPABLog(), "activated %{public}@ tab: %d", label, ok);
            if (ok) return;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MPABTryLocalTab(attempt + 1);
    });
}

// Called for each Marketplace home feed query. The first page of a visit is
// the cue that Marketplace just opened; pagination and our own tab switch are
// throttled out so we never fight the user's manual tab choice mid-scroll.
static void MPABMaybeSelectLocalTab(NSString *name) {
    if (!MPABPref(@"MPABDefaultLocalTab", MPAB_DEFAULT_LOCAL_TAB)) return;
    if (![name hasPrefix:@"MarketplaceHomeFeed"] || [name containsString:@"Pagination"]) return;
    static CFAbsoluteTime last;
    @synchronized ([MPABBlockingHandler class]) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last < 20) return;
        last = now;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ MPABTryLocalTab(0); });
}

#pragma mark - Hook

static IMP orig_handlerForRequest;

static id hook_handlerForRequest(id self, SEL _cmd, NSURLRequest *request) {
    NSString *name = MPABFriendlyName(request);
#if MPAB_LOG_ALL
    if (name) {
        NSDictionary *vars = [name hasPrefix:@"Marketplace"] ? MPABRequestVariables(request) : nil;
        NSData *vd = vars ? [NSJSONSerialization dataWithJSONObject:vars options:0 error:nil] : nil;
        NSString *vs = vd ? [[NSString alloc] initWithData:vd encoding:NSUTF8StringEncoding] : @"";
        os_log(MPABLog(), "query %{public}@ vars %{public}@", name,
               vs.length > 800 ? [vs substringToIndex:800] : vs);
    }
#endif
    if (MPABIsBlockedName(name)) {
        os_log(MPABLog(), "blocked %{public}@", name);
        return [MPABBlockingHandler shared];
    }
    if (MPABIsListingOpenName(name)) MPABNoteOpenedListing(request);
    MPABMaybeSelectLocalTab(name);
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
