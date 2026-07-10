#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import <CoreGraphics/CoreGraphics.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <QuickLookUI/QuickLookUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <pwd.h>

#import "render-helper.h"

static NSString *const MDVQLErrorDomain = @"com.local.markdown-viewer.quicklook";

static NSString *MDVDecodeHTMLEntities(NSString *text);

@interface MDVPreviewProvider : QLPreviewProvider <QLPreviewingController>
@end

static NSError *MDVQLMakeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:MDVQLErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Unknown error."}];
}

static NSString *MDVEscapeHTML(NSString *text) {
    NSMutableString *escaped = [text mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:NSLiteralSearch range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:NSLiteralSearch range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:NSLiteralSearch range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSBundle *MDVBundle(void) {
    return [NSBundle bundleForClass:[MDVPreviewProvider class]];
}

static NSString *MDVLoadBundleResource(NSString *name, NSString *extension, NSString *subdirectory, NSError **error) {
    NSURL *resourceURL = [MDVBundle() URLForResource:name withExtension:extension subdirectory:subdirectory];
    if (!resourceURL) {
        if (error) {
            *error = MDVQLMakeError(1, [NSString stringWithFormat:@"%@.%@ is missing from the Quick Look extension bundle.", name, extension]);
        }
        return nil;
    }
    return [NSString stringWithContentsOfURL:resourceURL encoding:NSUTF8StringEncoding error:error];
}

static NSString *MDVRenderMarkdownHTML(NSString *markdown, NSError **error) {
    NSString *markedSource = MDVLoadBundleResource(@"marked.umd", @"js", @"vendor", error);
    if (!markedSource) {
        return nil;
    }

    JSContext *context = [[JSContext alloc] init];
    __block NSString *exceptionMessage = nil;
    context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
        exceptionMessage = [exception description];
    };

    [context evaluateScript:markedSource];
    JSValue *marked = context[@"marked"];
    if (exceptionMessage || !marked || marked.isUndefined) {
        if (error) {
            *error = MDVQLMakeError(2, exceptionMessage ?: @"marked failed to load in JavaScriptCore.");
        }
        return nil;
    }

    JSValue *rendered = [marked invokeMethod:@"parse"
                               withArguments:@[markdown, @{@"gfm": @YES, @"breaks": @YES, @"async": @NO}]];
    if (exceptionMessage || !rendered.isString) {
        if (error) {
            *error = MDVQLMakeError(3, exceptionMessage ?: @"marked.parse did not return a string.");
        }
        return nil;
    }
    return rendered.toString;
}

#pragma mark - KaTeX math (JavaScriptCore, no DOM needed)

// katex.renderToString works without a browser DOM, so math renders even
// though Quick Look forbids web content processes in extension sandboxes.
static JSValue *MDVKaTeXRenderFunction(void) {
    static JSContext *context = nil;
    static JSValue *renderToString = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *katexSource = MDVLoadBundleResource(@"katex.min", @"js", @"vendor", NULL);
        if (!katexSource) {
            return;
        }
        context = [[JSContext alloc] init];
        __block BOOL failed = NO;
        context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
            failed = YES;
        };
        [context evaluateScript:katexSource];
        JSValue *katex = context[@"katex"];
        if (failed || !katex || katex.isUndefined) {
            context = nil;
            return;
        }
        renderToString = katex[@"renderToString"];
    });
    return renderToString;
}

static NSString *MDVKaTeXRenderTeX(NSString *tex, BOOL displayMode) {
    JSValue *render = MDVKaTeXRenderFunction();
    if (!render) {
        return nil;
    }

    __block BOOL failed = NO;
    JSContext *context = render.context;
    void (^previousHandler)(JSContext *, JSValue *) = context.exceptionHandler;
    context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
        failed = YES;
    };
    JSValue *result = [render callWithArguments:@[tex, @{@"displayMode": @(displayMode), @"throwOnError": @NO}]];
    context.exceptionHandler = previousHandler;

    return (!failed && result.isString) ? result.toString : nil;
}

// Replaces every regex match with an opaque token that marked passes through
// untouched; the original substring is stored for later restoration.
static void MDVProtectMatches(NSMutableString *text,
                              NSString *pattern,
                              unichar tokenMarker,
                              NSMutableDictionary<NSString *, NSString *> *store) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];

    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *token = [NSString stringWithFormat:@"%C%lu%C", tokenMarker, (unsigned long)store.count, tokenMarker];
        store[token] = [text substringWithRange:match.range];
        [text replaceCharactersInRange:match.range withString:token];
    }
}

// Extracts $$...$$, \[...\], \(...\), and $...$ math from the markdown source
// (skipping code fences and inline code), renders each with KaTeX, and swaps
// in placeholder tokens that are resolved after marked runs. Working on the
// source keeps TeX like $a_i + b_j$ away from marked's emphasis parsing.
static NSString *MDVSubstituteMath(NSString *markdown,
                                   NSMutableDictionary<NSString *, NSString *> *mathHTMLByToken) {
    BOOL mightHaveMath = [markdown containsString:@"$"] ||
                         [markdown containsString:@"\\("] ||
                         [markdown containsString:@"\\["];
    if (!mightHaveMath) {
        return markdown;
    }

    NSMutableString *working = [markdown mutableCopy];
    NSMutableDictionary<NSString *, NSString *> *protectedCode = [NSMutableDictionary dictionary];
    MDVProtectMatches(working, @"(?ms)^(```|~~~)[^\n]*$.*?^\\1[ \t]*$", 0xE000, protectedCode);
    MDVProtectMatches(working, @"(`+)[\\s\\S]*?\\1", 0xE000, protectedCode);

    NSRegularExpression *mathPattern = [NSRegularExpression regularExpressionWithPattern:
        @"\\$\\$([\\s\\S]+?)\\$\\$"        // $$display$$
         "|\\\\\\[([\\s\\S]+?)\\\\\\]"     // \[display\]
         "|\\\\\\(([\\s\\S]+?)\\\\\\)"     // \(inline\)
         "|\\$([^\\s$][^$\n]*?)\\$"        // $inline$
                                                                            options:0
                                                                              error:NULL];
    NSArray<NSTextCheckingResult *> *matches = [mathPattern matchesInString:working options:0 range:NSMakeRange(0, working.length)];

    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *tex = nil;
        BOOL displayMode = NO;
        for (NSUInteger group = 1; group <= 4; group += 1) {
            NSRange groupRange = [match rangeAtIndex:group];
            if (groupRange.location != NSNotFound) {
                tex = [working substringWithRange:groupRange];
                displayMode = group <= 2;
                break;
            }
        }

        NSString *rendered = tex.length > 0 ? MDVKaTeXRenderTeX(tex, displayMode) : nil;
        if (!rendered) {
            continue;
        }

        NSString *token = [NSString stringWithFormat:@"%C%lu%C", (unichar)0xE001, (unsigned long)mathHTMLByToken.count, (unichar)0xE001];
        mathHTMLByToken[token] = rendered;
        [working replaceCharactersInRange:match.range withString:token];
    }

    for (NSString *token in protectedCode) {
        NSRange tokenRange = [working rangeOfString:token];
        if (tokenRange.location != NSNotFound) {
            [working replaceCharactersInRange:tokenRange withString:protectedCode[token]];
        }
    }

    return working;
}

#pragma mark - Mermaid

// Mermaid needs a real browser engine, which the Quick Look sandbox refuses to
// spawn (WebContent processes are terminated immediately). The app caches every
// SVG it renders, keyed by diagram content hash — the extension reuses those
// and degrades to a styled source fallback for diagrams the app has never shown.
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

// NSHomeDirectory() points inside the extension's sandbox container; the
// app's cache lives under the user's real home, readable via the read-only
// filesystem exception entitlement.
static NSString *MDVRealHomeDirectory(void) {
    struct passwd *userInfo = getpwuid(getuid());
    return (userInfo && userInfo->pw_dir) ? @(userInfo->pw_dir) : NSHomeDirectory();
}

static NSString *MDVMermaidCachePath(void) {
    return [MDVRealHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Markdown Viewer/mermaid-cache"];
}

// The sandboxed extension cannot read preferences the normal way; the global
// preferences plist under the real home reveals the current appearance.
static NSString *MDVSystemTheme(void) {
    NSString *plistPath = [MDVRealHomeDirectory()
        stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"];
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *style = [preferences[@"AppleInterfaceStyle"] isKindOfClass:NSString.class] ? preferences[@"AppleInterfaceStyle"] : nil;
    return [style isEqualToString:@"Dark"] ? @"dark" : @"light";
}

static NSString *MDVCachedMermaidSVGForTheme(NSString *hash, NSString *theme) {
    NSString *filePath = [MDVMermaidCachePath() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@-%@.svg", hash, theme]];
    NSString *svg = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:NULL];
    return svg.length > 0 ? svg : nil;
}

// Cache miss: ask the on-demand launchd helper to render the diagram. launchd
// spawns it lazily and it exits when idle, so this costs nothing at rest; if
// the agent is not installed the lookup fails fast and we fall back.
static NSString *MDVRequestMermaidRender(NSString *trimmedSource) {
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:MDVRenderHelperServiceName
                                                                           options:0];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MDVRenderHelperProtocol)];
    [connection resume];

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSString *renderedSVG = nil;

    id<MDVRenderHelperProtocol> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        dispatch_semaphore_signal(semaphore);
    }];
    [proxy renderMermaidSource:trimmedSource theme:MDVSystemTheme() withReply:^(NSString *svg, NSString *errorMessage) {
        renderedSVG = svg.length > 0 ? svg : nil;
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)));
    [connection invalidate];
    return renderedSVG;
}

// Theme priority: an SVG matching the system appearance, then a live helper
// render (which produces the system theme), then a stale-theme SVG as a last
// resort — a wrong-theme diagram beats no diagram.
static NSString *MDVMermaidSVGForSource(NSString *source) {
    NSString *trimmed = [source stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return nil;
    }

    NSString *hash = MDVSHA256Hex(trimmed);
    NSString *systemTheme = MDVSystemTheme();

    NSString *svg = MDVCachedMermaidSVGForTheme(hash, systemTheme);
    if (svg) {
        return svg;
    }

    svg = MDVRequestMermaidRender(trimmed);
    if (svg) {
        return svg;
    }

    NSString *otherTheme = [systemTheme isEqualToString:@"dark"] ? @"light" : @"dark";
    return MDVCachedMermaidSVGForTheme(hash, otherTheme);
}

static NSString *MDVApplyMermaidRendering(NSString *html) {
    NSRegularExpression *mermaidBlock = [NSRegularExpression regularExpressionWithPattern:
        @"<pre><code class=\"language-mermaid\">([\\s\\S]*?)</code></pre>" options:0 error:NULL];
    NSArray<NSTextCheckingResult *> *matches = [mermaidBlock matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    if (matches.count == 0) {
        return html;
    }

    NSMutableString *result = [html mutableCopy];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *escapedSource = [html substringWithRange:[match rangeAtIndex:1]];
        NSString *cachedSVG = MDVMermaidSVGForSource(MDVDecodeHTMLEntities(escapedSource));

        NSString *figure;
        if (cachedSVG) {
            NSString *dataURI = [NSString stringWithFormat:@"data:image/svg+xml;base64,%@",
                [[cachedSVG dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
            figure = [NSString stringWithFormat:
                @"<figure class=\"mermaid-diagram\">"
                 "<img class=\"mermaid-diagram__image\" alt=\"Mermaid diagram\" src=\"%@\">"
                 "</figure>", dataURI];
        } else {
            figure = [NSString stringWithFormat:
                @"<figure class=\"mermaid-diagram\">"
                 "<p class=\"mermaid-diagram__status\">Could not render Mermaid diagram.</p>"
                 "<pre><code class=\"language-mermaid\">%@</code></pre>"
                 "</figure>", escapedSource];
        }
        [result replaceCharactersInRange:match.range withString:figure];
    }
    return result;
}

#pragma mark - Preview assembly

static NSString *MDVRenderPreviewBody(NSString *markdown, NSError **error) {
    NSMutableDictionary<NSString *, NSString *> *mathHTMLByToken = [NSMutableDictionary dictionary];
    NSString *prepared = MDVSubstituteMath(markdown, mathHTMLByToken);

    NSString *html = MDVRenderMarkdownHTML(prepared, error);
    if (!html) {
        return nil;
    }

    if (mathHTMLByToken.count > 0) {
        NSMutableString *resolved = [html mutableCopy];
        for (NSString *token in mathHTMLByToken) {
            NSRange tokenRange = [resolved rangeOfString:token];
            if (tokenRange.location != NSNotFound) {
                [resolved replaceCharactersInRange:tokenRange withString:mathHTMLByToken[token]];
            }
        }
        html = resolved;
    }

    return MDVApplyMermaidRendering(html);
}

static NSString *MDVDecodeHTMLEntities(NSString *text) {
    NSMutableString *decoded = [text mutableCopy];
    [decoded replaceOccurrencesOfString:@"&quot;" withString:@"\"" options:NSLiteralSearch range:NSMakeRange(0, decoded.length)];
    [decoded replaceOccurrencesOfString:@"&#39;" withString:@"'" options:NSLiteralSearch range:NSMakeRange(0, decoded.length)];
    [decoded replaceOccurrencesOfString:@"&lt;" withString:@"<" options:NSLiteralSearch range:NSMakeRange(0, decoded.length)];
    [decoded replaceOccurrencesOfString:@"&gt;" withString:@">" options:NSLiteralSearch range:NSMakeRange(0, decoded.length)];
    [decoded replaceOccurrencesOfString:@"&amp;" withString:@"&" options:NSLiteralSearch range:NSMakeRange(0, decoded.length)];
    return decoded;
}

static NSData *MDVReadImageData(NSURL *imageURL) {
    static const NSUInteger MDVMaxImageBytes = 25 * 1024 * 1024;
    NSData *data = [NSData dataWithContentsOfURL:imageURL options:NSDataReadingMappedIfSafe error:NULL];
    return (data.length > 0 && data.length <= MDVMaxImageBytes) ? data : nil;
}

static NSURL *MDVResolveLocalImageURL(NSString *source, NSURL *baseDirectoryURL) {
    if ([source hasPrefix:@"file://"]) {
        return [NSURL URLWithString:source];
    }
    NSString *path = source;
    if ([path containsString:@"%"]) {
        path = [path stringByRemovingPercentEncoding] ?: path;
    }
    if ([path hasPrefix:@"/"]) {
        return [NSURL fileURLWithPath:path];
    }
    return [NSURL fileURLWithPath:path relativeToURL:baseDirectoryURL].absoluteURL;
}

// Data-based previews have no document base URL, so relative image paths can
// never load on their own; local images are inlined as cid: attachments instead.
static NSString *MDVEmbedLocalImages(NSString *bodyHTML,
                                     NSURL *baseDirectoryURL,
                                     NSMutableDictionary<NSString *, QLPreviewReplyAttachment *> *attachments) {
    NSRegularExpression *imageSource =
        [NSRegularExpression regularExpressionWithPattern:@"(<img\\b[^>]*?\\bsrc\\s*=\\s*\")([^\"]+)(\")"
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:NULL];
    NSArray<NSTextCheckingResult *> *matches =
        [imageSource matchesInString:bodyHTML options:0 range:NSMakeRange(0, bodyHTML.length)];
    if (matches.count == 0) {
        return bodyHTML;
    }

    NSMutableString *result = [bodyHTML mutableCopy];
    NSUInteger attachmentIndex = 0;

    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *source = MDVDecodeHTMLEntities([bodyHTML substringWithRange:[match rangeAtIndex:2]]);
        if ([source rangeOfString:@"^(https?:|data:|cid:)" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) {
            continue;
        }

        NSURL *imageURL = MDVResolveLocalImageURL(source, baseDirectoryURL);
        NSData *imageData = imageURL ? MDVReadImageData(imageURL) : nil;
        if (!imageData) {
            continue;
        }

        UTType *contentType = [UTType typeWithFilenameExtension:imageURL.pathExtension.lowercaseString];
        if (!contentType || ![contentType conformsToType:UTTypeImage]) {
            continue;
        }

        NSString *attachmentKey = [NSString stringWithFormat:@"img%lu", (unsigned long)attachmentIndex];
        attachmentIndex += 1;
        attachments[attachmentKey] = [[QLPreviewReplyAttachment alloc] initWithData:imageData contentType:contentType];
        [result replaceCharactersInRange:[match rangeAtIndex:2]
                              withString:[NSString stringWithFormat:@"cid:%@", attachmentKey]];
    }

    return result;
}

// KaTeX CSS references its fonts with relative url(fonts/...) entries that a
// data-based preview cannot resolve, so the woff2 fonts are inlined as data URIs.
static NSString *MDVKaTeXCSS(void) {
    static NSString *inlinedCSS = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *css = MDVLoadBundleResource(@"katex.min", @"css", @"vendor", NULL);
        if (!css) {
            inlinedCSS = @"";
            return;
        }

        NSRegularExpression *fontURL =
            [NSRegularExpression regularExpressionWithPattern:@"url\\(fonts/([^)]+\\.woff2)\\)" options:0 error:NULL];
        NSMutableString *result = [css mutableCopy];
        NSArray<NSTextCheckingResult *> *matches = [fontURL matchesInString:css options:0 range:NSMakeRange(0, css.length)];

        for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
            NSString *fontName = [css substringWithRange:[match rangeAtIndex:1]];
            NSURL *fontFile = [MDVBundle() URLForResource:[fontName stringByDeletingPathExtension]
                                            withExtension:@"woff2"
                                             subdirectory:@"vendor/fonts"];
            NSData *fontData = fontFile ? [NSData dataWithContentsOfURL:fontFile] : nil;
            if (!fontData) {
                continue;
            }
            NSString *replacement = [NSString stringWithFormat:@"url(data:font/woff2;base64,%@)",
                                     [fontData base64EncodedStringWithOptions:0]];
            [result replaceCharactersInRange:match.range withString:replacement];
        }

        inlinedCSS = result;
    });
    return inlinedCSS;
}

// Quick Look renders data-based HTML previews with JavaScript disabled, so the
// document must arrive fully rendered; the CSP is defense in depth on top of that.
static NSString *MDVPreviewHTML(NSString *bodyHTML, NSString *css) {
    return [NSString stringWithFormat:
        @"<!DOCTYPE html>\n"
         "<html lang=\"en\">\n"
         "<head>\n"
         "<meta charset=\"UTF-8\">\n"
         "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data: file: cid:; style-src 'unsafe-inline'; script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none';\">\n"
         "<meta name=\"color-scheme\" content=\"light dark\">\n"
         "<style>\n%@\n</style>\n"
         "</head>\n"
         "<body>\n"
         "<main class=\"document\">\n%@\n</main>\n"
         "</body>\n"
         "</html>\n", css, bodyHTML];
}

@implementation MDVPreviewProvider

- (void)providePreviewForFileRequest:(QLFilePreviewRequest *)request
                   completionHandler:(void (^)(QLPreviewReply *_Nullable, NSError *_Nullable))handler {
    NSURL *fileURL = request.fileURL;
    QLPreviewReply *reply = [[QLPreviewReply alloc]
        initWithDataOfContentType:UTTypeHTML
                      contentSize:CGSizeMake(720.0, 900.0)
                dataCreationBlock:^NSData *_Nullable(QLPreviewReply *replyToUpdate, NSError **error) {
        replyToUpdate.stringEncoding = NSUTF8StringEncoding;

        NSString *markdown = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:NULL];
        if (!markdown) {
            NSData *rawData = [NSData dataWithContentsOfURL:fileURL options:0 error:error];
            if (!rawData) {
                return nil;
            }
            markdown = [[NSString alloc] initWithData:rawData encoding:NSISOLatin1StringEncoding] ?: @"";
        }

        NSString *body = MDVRenderPreviewBody(markdown, NULL);
        if (!body) {
            body = [NSString stringWithFormat:@"<pre>%@</pre>", MDVEscapeHTML(markdown)];
        }

        NSString *css = MDVLoadBundleResource(@"viewer", @"css", nil, NULL) ?: @"";
        if ([body containsString:@"class=\"katex"]) {
            css = [css stringByAppendingFormat:@"\n%@", MDVKaTeXCSS()];
        }

        NSMutableDictionary<NSString *, QLPreviewReplyAttachment *> *attachments = [NSMutableDictionary dictionary];
        body = MDVEmbedLocalImages(body, fileURL.URLByDeletingLastPathComponent, attachments);
        if (attachments.count > 0) {
            replyToUpdate.attachments = attachments;
        }

        return [MDVPreviewHTML(body, css) dataUsingEncoding:NSUTF8StringEncoding];
    }];

    handler(reply, nil);
}

@end
