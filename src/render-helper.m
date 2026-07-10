// On-demand launchd agent that renders Mermaid diagrams to SVG for the Quick
// Look extension, which cannot host a web content process itself. launchd
// spawns this binary when the extension connects and it exits when idle.
#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonCrypto.h>
#import <WebKit/WebKit.h>

#import "render-helper.h"

static const NSTimeInterval MDVIdleExitInterval = 45.0;
static const NSTimeInterval MDVRenderTimeout = 20.0;
static const NSUInteger MDVMaxSourceLength = 1024 * 1024;

static NSDate *gLastActivity = nil;
static NSInteger gActiveRenders = 0;

static NSString *MDVSHA256Hex(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static NSString *MDVMermaidCacheDirectory(void) {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[appSupport stringByAppendingPathComponent:@"Markdown Viewer"] stringByAppendingPathComponent:@"mermaid-cache"];
}

static void MDVWriteCachedSVG(NSString *trimmedSource, NSString *theme, NSString *svg) {
    NSString *cacheDirectory = MDVMermaidCacheDirectory();
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.svg", MDVSHA256Hex(trimmedSource), theme];
    [svg writeToFile:[cacheDirectory stringByAppendingPathComponent:fileName]
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:NULL];
}

#pragma mark - Offscreen mermaid rendering

@interface MDVMermaidRender : NSObject <WKNavigationDelegate>

@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, copy) void (^completion)(NSString *_Nullable svg, NSString *_Nullable errorMessage);
@property(nonatomic, assign) NSInteger pollsRemaining;

@end

@implementation MDVMermaidRender

// Keeps renders alive for the duration of their async work; main thread only.
static NSMutableSet<MDVMermaidRender *> *MDVActiveRenderSet(void) {
    static NSMutableSet *renders = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        renders = [NSMutableSet set];
    });
    return renders;
}

+ (void)renderSource:(NSString *)source
               theme:(NSString *)theme
          completion:(void (^)(NSString *_Nullable, NSString *_Nullable))completion {
    NSString *mermaidSource = nil;
    NSURL *mermaidURL = [[NSBundle mainBundle] URLForResource:@"mermaid.min" withExtension:@"js" subdirectory:@"vendor"];
    if (mermaidURL) {
        mermaidSource = [NSString stringWithContentsOfURL:mermaidURL encoding:NSUTF8StringEncoding error:NULL];
    }
    if (!mermaidSource) {
        completion(nil, @"mermaid.min.js is missing from the app bundle.");
        return;
    }

    MDVMermaidRender *render = [[MDVMermaidRender alloc] init];
    render.completion = completion;
    [MDVActiveRenderSet() addObject:render];

    NSString *base64Source = [[source dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    NSString *mermaidTheme = [theme isEqualToString:@"dark"] ? @"dark" : @"default";
    NSString *driverScript = [NSString stringWithFormat:
        @"(async () => {"
         "  try {"
         "    const bytes = Uint8Array.from(atob(\"%@\"), (c) => c.charCodeAt(0));"
         "    const source = new TextDecoder().decode(bytes);"
         "    mermaid.initialize({ startOnLoad: false, securityLevel: \"strict\", theme: \"%@\" });"
         "    const result = await mermaid.render(\"mdv-diagram\", source);"
         "    window.__mdvResult = { svg: result.svg };"
         "  } catch (error) {"
         "    window.__mdvResult = { error: String(error) };"
         "  }"
         "})();", base64Source, mermaidTheme];

    // User scripts sidestep any HTML escaping concerns with inline <script> tags.
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    [configuration.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:mermaidSource
                               injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                            forMainFrameOnly:YES]];
    [configuration.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:driverScript
                               injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                            forMainFrameOnly:YES]];

    render.webView = [[WKWebView alloc] initWithFrame:CGRectMake(0.0, 0.0, 800.0, 600.0) configuration:configuration];
    render.webView.navigationDelegate = render;
    [render.webView loadHTMLString:@"<!DOCTYPE html><html><head><meta charset=\"UTF-8\"></head><body></body></html>"
                           baseURL:nil];

    __weak MDVMermaidRender *weakRender = render;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MDVRenderTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakRender finishWithSVG:nil errorMessage:@"Timed out rendering the diagram."];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pollsRemaining = (NSInteger)(MDVRenderTimeout / 0.1);
    [self pollForResult];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithSVG:nil errorMessage:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithSVG:nil errorMessage:error.localizedDescription];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self finishWithSVG:nil errorMessage:@"Web content process was terminated."];
}

- (void)pollForResult {
    if (!self.completion) {
        return;
    }

    __weak MDVMermaidRender *weakSelf = self;
    [self.webView evaluateJavaScript:@"window.__mdvResult || null" completionHandler:^(id result, NSError *error) {
        MDVMermaidRender *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.completion) {
            return;
        }

        if ([result isKindOfClass:NSDictionary.class]) {
            NSDictionary *payload = result;
            NSString *svg = [payload[@"svg"] isKindOfClass:NSString.class] ? payload[@"svg"] : nil;
            NSString *message = [payload[@"error"] isKindOfClass:NSString.class] ? payload[@"error"] : nil;
            [strongSelf finishWithSVG:svg errorMessage:svg ? nil : (message ?: @"Mermaid returned no SVG.")];
            return;
        }

        strongSelf.pollsRemaining -= 1;
        if (strongSelf.pollsRemaining <= 0 || error) {
            [strongSelf finishWithSVG:nil errorMessage:error.localizedDescription ?: @"Timed out waiting for Mermaid."];
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf pollForResult];
        });
    }];
}

- (void)finishWithSVG:(NSString *)svg errorMessage:(NSString *)errorMessage {
    if (!self.completion) {
        return;
    }

    void (^completion)(NSString *_Nullable, NSString *_Nullable) = self.completion;
    self.completion = nil;

    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    self.webView = nil;

    [MDVActiveRenderSet() removeObject:self];
    completion(svg, errorMessage);
}

@end

#pragma mark - XPC service

@interface MDVHelperListenerDelegate : NSObject <NSXPCListenerDelegate, MDVRenderHelperProtocol>
@end

@implementation MDVHelperListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MDVRenderHelperProtocol)];
    newConnection.exportedObject = self;
    [newConnection resume];
    return YES;
}

- (void)renderMermaidSource:(NSString *)source
                      theme:(NSString *)theme
                  withReply:(void (^)(NSString *_Nullable, NSString *_Nullable))reply {
    if (![source isKindOfClass:NSString.class] || source.length == 0 || source.length > MDVMaxSourceLength) {
        reply(nil, @"Invalid diagram source.");
        return;
    }

    NSString *safeTheme = [theme isEqualToString:@"dark"] ? @"dark" : @"light";
    NSString *trimmedSource = [source stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    dispatch_async(dispatch_get_main_queue(), ^{
        gActiveRenders += 1;
        gLastActivity = [NSDate date];

        [MDVMermaidRender renderSource:trimmedSource theme:safeTheme completion:^(NSString *svg, NSString *errorMessage) {
            if (svg.length > 0) {
                MDVWriteCachedSVG(trimmedSource, safeTheme, svg);
            }
            gActiveRenders -= 1;
            gLastActivity = [NSDate date];
            reply(svg, errorMessage);
        }];
    });
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gLastActivity = [NSDate date];

        MDVHelperListenerDelegate *delegate = [[MDVHelperListenerDelegate alloc] init];
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:MDVRenderHelperServiceName];
        listener.delegate = delegate;
        [listener resume];

        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *timer) {
            if (gActiveRenders == 0 && -[gLastActivity timeIntervalSinceNow] > MDVIdleExitInterval) {
                exit(0);
            }
        }];

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
