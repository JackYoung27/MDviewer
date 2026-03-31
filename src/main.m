#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>

static NSString *const MDVErrorDomain = @"com.local.markdown-viewer";
static NSString *const MDVReleasesURL = @"https://api.github.com/repos/JackYoung27/MDviewer/releases/latest";
static NSString *const MDVDownloadURL = @"https://github.com/JackYoung27/MDviewer/releases/latest";

static NSSet<NSString *> *MDVMarkdownExtensions(void) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithObjects:@"md", @"markdown", @"mdown", @"mkd", nil];
    });
    return extensions;
}

static BOOL MDVURLLooksLikeMarkdown(NSURL *url) {
    return [MDVMarkdownExtensions() containsObject:url.pathExtension.lowercaseString];
}

static NSError *MDVMakeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:MDVErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Unknown error."}];
}

@interface MDVPreviewWindowController : NSWindowController <NSWindowDelegate, WKNavigationDelegate, WKUIDelegate>

@property(nonatomic, copy) void (^closeHandler)(void);
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSURL *sourceFileURL;
@property(nonatomic, strong) NSURL *previewFileURL;
@property(nonatomic, strong) NSURL *lastExportedPDFURL;
@property(nonatomic, assign, getter=isPreviewReady) BOOL previewReady;
@property(nonatomic, assign) FSEventStreamRef fileWatchStream;

- (BOOL)openMarkdownFileURL:(NSURL *)fileURL error:(NSError **)error;
- (void)reloadPreview:(id)sender;
- (void)printDocument:(id)sender;
- (void)exportPDF:(id)sender;
- (void)openPDFInDefaultApp:(id)sender;
- (void)revealSourceFile:(id)sender;
- (BOOL)hasLoadedDocument;

@end

@implementation MDVPreviewWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0.0, 0.0, 860.0, 980.0);
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];

    self = [super initWithWindow:window];
    if (!self) {
        return nil;
    }

    window.delegate = self;
    window.title = @"Markdown Viewer";
    window.titleVisibility = NSWindowTitleVisible;
    window.tabbingMode = NSWindowTabbingModePreferred;
    [window center];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    self.webView = [[WKWebView alloc] initWithFrame:window.contentView.bounds configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.allowsMagnification = YES;
    self.webView.allowsBackForwardNavigationGestures = NO;

    [window.contentView addSubview:self.webView];
    [window setInitialFirstResponder:self.webView];

    return self;
}

- (BOOL)hasLoadedDocument {
    return self.sourceFileURL != nil;
}

- (NSURL *)rendererScriptURL {
    NSBundle *bundle = [NSBundle mainBundle];
    return [bundle URLForResource:@"MarkdownViewer" withExtension:@"sh"];
}

- (NSURL *)previewHTMLURLForFileURL:(NSURL *)fileURL error:(NSError **)error {
    NSURL *scriptURL = [self rendererScriptURL];

    if (!scriptURL) {
        if (error) {
            *error = MDVMakeError(10, @"The preview generator is missing from the app bundle.");
        }
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    NSError *launchError = nil;

    task.executableURL = scriptURL;
    task.arguments = @[fileURL.path];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    if (![task launchAndReturnError:&launchError]) {
        if (error) {
            *error = launchError ?: MDVMakeError(11, @"Could not start the preview generator.");
        }
        return nil;
    }

    [task waitUntilExit];

    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    NSString *stdoutString = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrString = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";

    if (task.terminationStatus != 0) {
        NSString *message = stderrString.length > 0 ? stderrString : @"Preview generation failed.";
        if (error) {
            *error = MDVMakeError(12, [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        }
        return nil;
    }

    __block NSString *htmlPath = nil;
    [stdoutString enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) {
            htmlPath = trimmed;
            *stop = YES;
        }
    }];

    if (htmlPath.length == 0) {
        if (error) {
            *error = MDVMakeError(13, @"Preview generation did not return an HTML path.");
        }
        return nil;
    }

    return [NSURL fileURLWithPath:htmlPath];
}

- (void)loadErrorPageWithMessage:(NSString *)message {
    NSString *safeMessage = [[message ?: @"Preview failed to load."
        stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
        stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

    NSString *html = [NSString stringWithFormat:
        @"<!doctype html><html><head><meta charset=\"utf-8\"><style>"
         "body{margin:0;padding:32px;font:13pt/1.6 -apple-system,BlinkMacSystemFont,sans-serif;background:#fff;color:#1f2937;}"
         "main{max-width:760px;}h1{margin:0 0 0.5em;font-size:1.3em;}p{margin:0;white-space:pre-wrap;}"
         "</style></head><body><main><h1>Could not open document</h1><p>%@</p></main></body></html>",
        safeMessage];

    [self.webView loadHTMLString:html baseURL:nil];
    self.previewReady = NO;
}

- (BOOL)openMarkdownFileURL:(NSURL *)fileURL error:(NSError **)error {
    NSURL *standardURL = fileURL.fileURL ? fileURL.URLByStandardizingPath : [NSURL fileURLWithPath:fileURL.path];
    NSURL *previewURL = [self previewHTMLURLForFileURL:standardURL error:error];

    if (!previewURL) {
        [self loadErrorPageWithMessage:error && *error ? (*error).localizedDescription : nil];
        return NO;
    }

    BOOL fileChanged = ![standardURL isEqual:self.sourceFileURL];

    self.sourceFileURL = standardURL;
    self.previewFileURL = previewURL;
    self.previewReady = NO;
    self.lastExportedPDFURL = nil;

    self.window.title = standardURL.lastPathComponent;
    self.window.representedURL = standardURL;
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:standardURL];

    [self.webView loadFileURL:previewURL allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];

    if (fileChanged || !self.fileWatchStream) {
        [self startWatchingSourceFile];
    }

    return YES;
}

- (void)reloadPreview:(id)sender {
    if (!self.sourceFileURL) {
        return;
    }

    NSError *error = nil;
    if (![self openMarkdownFileURL:self.sourceFileURL error:&error]) {
        [self presentError:error];
    }
}

- (void)printDocument:(id)sender {
    if (!self.isPreviewReady) {
        return;
    }

    NSPrintInfo *printInfo = [NSPrintInfo sharedPrintInfo];
    NSPrintOperation *operation = [self.webView printOperationWithPrintInfo:printInfo];
    [operation runOperationModalForWindow:self.window delegate:nil didRunSelector:NULL contextInfo:NULL];
}

- (void)createPDFWithCompletion:(void (^)(NSData *pdfData, NSError *error))completion {
    if (!self.isPreviewReady) {
        if (completion) {
            completion(nil, MDVMakeError(20, @"Wait until the preview finishes loading before exporting."));
        }
        return;
    }

    [self.webView createPDFWithConfiguration:nil completionHandler:^(NSData *pdfData, NSError *error) {
        if (completion) {
            completion(pdfData, error);
        }
    }];
}

- (NSString *)defaultPDFFileName {
    NSString *sourceName = self.sourceFileURL.lastPathComponent ?: @"Document";
    NSString *stem = [sourceName stringByDeletingPathExtension];
    if (stem.length == 0) {
        stem = sourceName;
    }
    return [stem stringByAppendingPathExtension:@"pdf"];
}

- (void)writePDFData:(NSData *)pdfData
               toURL:(NSURL *)destinationURL
         openWhenDone:(BOOL)openWhenDone {
    NSError *writeError = nil;
    if (![pdfData writeToURL:destinationURL options:NSDataWritingAtomic error:&writeError]) {
        [self presentError:writeError];
        return;
    }

    self.lastExportedPDFURL = destinationURL;

    if (openWhenDone) {
        [[NSWorkspace sharedWorkspace] openURL:destinationURL];
    }
}

- (void)exportPDF:(id)sender {
    if (!self.sourceFileURL) {
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePDF];
    panel.canCreateDirectories = YES;
    panel.nameFieldStringValue = [self defaultPDFFileName];
    panel.directoryURL = self.sourceFileURL.URLByDeletingLastPathComponent;

    if ([panel runModal] != NSModalResponseOK || panel.URL == nil) {
        return;
    }

    NSURL *destinationURL = panel.URL;
    __weak typeof(self) weakSelf = self;

    [self createPDFWithCompletion:^(NSData *pdfData, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || pdfData.length == 0) {
                [weakSelf presentError:error ?: MDVMakeError(21, @"Could not create the PDF export.")];
                return;
            }

            [weakSelf writePDFData:pdfData toURL:destinationURL openWhenDone:NO];
        });
    }];
}

- (void)openPDFInDefaultApp:(id)sender {
    if (self.lastExportedPDFURL && [[NSFileManager defaultManager] fileExistsAtPath:self.lastExportedPDFURL.path]) {
        [[NSWorkspace sharedWorkspace] openURL:self.lastExportedPDFURL];
        return;
    }

    if (!self.previewFileURL) {
        return;
    }

    NSURL *previewDirectoryURL = self.previewFileURL.URLByDeletingLastPathComponent;
    NSURL *destinationURL = [previewDirectoryURL URLByAppendingPathComponent:[self defaultPDFFileName]];
    __weak typeof(self) weakSelf = self;

    [self createPDFWithCompletion:^(NSData *pdfData, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || pdfData.length == 0) {
                [weakSelf presentError:error ?: MDVMakeError(22, @"Could not create the PDF export.")];
                return;
            }

            [weakSelf writePDFData:pdfData toURL:destinationURL openWhenDone:YES];
        });
    }];
}

- (void)revealSourceFile:(id)sender {
    if (!self.sourceFileURL) {
        return;
    }

    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[self.sourceFileURL]];
}

static void MDVFSEventCallback(ConstFSEventStreamRef streamRef,
                               void *clientCallBackInfo,
                               size_t numEvents,
                               void *eventPaths,
                               const FSEventStreamEventFlags eventFlags[],
                               const FSEventStreamEventId eventIds[]) {
    MDVPreviewWindowController *controller = (__bridge MDVPreviewWindowController *)clientCallBackInfo;
    NSString *watchedName = controller.sourceFileURL.lastPathComponent;
    NSArray<NSString *> *paths = (__bridge NSArray *)eventPaths;

    for (NSUInteger i = 0; i < numEvents; i++) {
        NSString *changedName = paths[i].lastPathComponent;
        if ([changedName isEqualToString:watchedName]) {
            [controller reloadPreview:nil];
            return;
        }
    }
}

- (void)startWatchingSourceFile {
    [self stopWatchingSourceFile];

    if (!self.sourceFileURL) {
        return;
    }

    NSString *directoryPath = self.sourceFileURL.URLByDeletingLastPathComponent.path;
    NSArray *pathsToWatch = @[directoryPath];

    FSEventStreamContext context = {0, (__bridge void *)self, NULL, NULL, NULL};

    FSEventStreamRef stream = FSEventStreamCreate(
        NULL,
        &MDVFSEventCallback,
        &context,
        (__bridge CFArrayRef)pathsToWatch,
        kFSEventStreamEventIdSinceNow,
        0.3,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes);

    if (!stream) {
        return;
    }

    FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
    FSEventStreamStart(stream);
    self.fileWatchStream = stream;
}

- (void)stopWatchingSourceFile {
    if (self.fileWatchStream) {
        FSEventStreamStop(self.fileWatchStream);
        FSEventStreamInvalidate(self.fileWatchStream);
        FSEventStreamRelease(self.fileWatchStream);
        self.fileWatchStream = NULL;
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    [self stopWatchingSourceFile];
    if (self.closeHandler) {
        self.closeHandler();
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.previewReady = YES;
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    self.previewReady = NO;
    [self loadErrorPageWithMessage:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    self.previewReady = NO;
    [self loadErrorPageWithMessage:error.localizedDescription];
}

- (void)openLinkedURL:(NSURL *)url {
    if (!url) {
        return;
    }

    if (url.isFileURL && MDVURLLooksLikeMarkdown(url)) {
        NSError *error = nil;
        if (![self openMarkdownFileURL:url error:&error]) {
            [self presentError:error];
        }
        return;
    }

    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;

    if (navigationAction.navigationType == WKNavigationTypeLinkActivated && url) {
        [self openLinkedURL:url];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (nullable WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
              forNavigationAction:(WKNavigationAction *)navigationAction
                   windowFeatures:(WKWindowFeatures *)windowFeatures {
    [self openLinkedURL:navigationAction.request.URL];
    return nil;
}

@end

@interface MDVAppDelegate : NSObject <NSApplicationDelegate, NSUserInterfaceValidations>

@property(nonatomic, strong) NSMutableSet<MDVPreviewWindowController *> *windowControllers;
@property(nonatomic, assign) BOOL openedFileDuringLaunch;

@end

@implementation MDVAppDelegate

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _windowControllers = [NSMutableSet set];
    return self;
}

- (NSString *)appDisplayName {
    NSString *displayName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    return displayName.length > 0 ? displayName : @"MDviewer";
}

- (void)installMainMenu {
    NSString *appName = [self appDisplayName];
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:appName];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"About %@", appName]
                                                       action:@selector(orderFrontStandardAboutPanel:)
                                                keyEquivalent:@""];
    aboutItem.target = NSApp;
    [appMenu addItem:aboutItem];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [appMenu addItem:quitItem];
    appMenuItem.submenu = appMenu;

    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileMenuItem];

    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItem:[self menuItemWithTitle:@"Open..."
                                       action:@selector(openDocument:)
                                 keyEquivalent:@"o"
                             modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[self menuItemWithTitle:@"Reload"
                                       action:@selector(reloadPreview:)
                                 keyEquivalent:@"r"
                             modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItem:[self menuItemWithTitle:@"Print..."
                                       action:@selector(printDocument:)
                                 keyEquivalent:@"p"
                             modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[self menuItemWithTitle:@"Export as PDF..."
                                       action:@selector(exportPDF:)
                                 keyEquivalent:@"e"
                             modifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)]];
    [fileMenu addItem:[self menuItemWithTitle:@"Open PDF in Default App"
                                       action:@selector(openPDFInDefaultApp:)
                                 keyEquivalent:@""
                             modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[self menuItemWithTitle:@"Reveal Source File"
                                       action:@selector(revealSourceFile:)
                                 keyEquivalent:@""
                             modifierMask:NSEventModifierFlagCommand]];
    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close"
                                                       action:@selector(performClose:)
                                                keyEquivalent:@"w"];
    closeItem.target = nil;
    [fileMenu addItem:closeItem];

    fileMenuItem.submenu = fileMenu;

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:editMenuItem];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItem:[self standardMenuItemWithTitle:@"Undo"
                                               action:@selector(undo:)
                                         keyEquivalent:@"z"
                                         modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self standardMenuItemWithTitle:@"Redo"
                                               action:@selector(redo:)
                                         keyEquivalent:@"Z"
                                         modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self standardMenuItemWithTitle:@"Cut"
                                               action:@selector(cut:)
                                         keyEquivalent:@"x"
                                         modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self standardMenuItemWithTitle:@"Copy"
                                               action:@selector(copy:)
                                         keyEquivalent:@"c"
                                         modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self standardMenuItemWithTitle:@"Paste"
                                               action:@selector(paste:)
                                         keyEquivalent:@"v"
                                         modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self menuItemWithTitle:@"Find..."
                                       action:@selector(openFindPanel:)
                                 keyEquivalent:@"f"
                             modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItemWithTitle:@"Find Next"
                                       action:@selector(findNextMatch:)
                                 keyEquivalent:@"g"
                             modifierMask:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItemWithTitle:@"Find Previous"
                                       action:@selector(findPreviousMatch:)
                                 keyEquivalent:@"G"
                             modifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self standardMenuItemWithTitle:@"Select All"
                                               action:@selector(selectAll:)
                                         keyEquivalent:@"a"
                                         modifierMask:NSEventModifierFlagCommand]];
    editMenuItem.submenu = editMenu;

    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewMenuItem];

    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenu addItem:[self menuItemWithTitle:@"Toggle Dark Mode"
                                       action:@selector(toggleDarkMode:)
                                 keyEquivalent:@"d"
                             modifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)]];
    viewMenuItem.submenu = viewMenu;

    [NSApp setMainMenu:mainMenu];
}

- (NSMenuItem *)menuItemWithTitle:(NSString *)title
                           action:(SEL)action
                     keyEquivalent:(NSString *)keyEquivalent
                     modifierMask:(NSEventModifierFlags)modifierMask {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent];
    item.target = self;
    item.keyEquivalentModifierMask = modifierMask;
    return item;
}

- (NSMenuItem *)standardMenuItemWithTitle:(NSString *)title
                                   action:(SEL)action
                             keyEquivalent:(NSString *)keyEquivalent
                             modifierMask:(NSEventModifierFlags)modifierMask {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent];
    item.target = nil;
    item.keyEquivalentModifierMask = modifierMask;
    return item;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (!self.openedFileDuringLaunch) {
        [self openDocument:nil];
    }
    [self checkForUpdates];
}

- (void)checkForUpdates {
    NSString *currentVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0.0";

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:MDVReleasesURL]];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 10;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) return;

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *tagName = json[@"tag_name"];
        if (![tagName isKindOfClass:NSString.class]) return;

        NSString *latestVersion = [tagName hasPrefix:@"v"] ? [tagName substringFromIndex:1] : tagName;
        if ([latestVersion compare:currentVersion options:NSNumericSearch] != NSOrderedDescending) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [NSString stringWithFormat:@"MDviewer %@ is available", latestVersion];
            alert.informativeText = [NSString stringWithFormat:@"You're running version %@. Would you like to download the update?", currentVersion];
            [alert addButtonWithTitle:@"Download"];
            [alert addButtonWithTitle:@"Later"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:MDVDownloadURL]];
            }
        });
    }] resume];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag && self.windowControllers.count == 0) {
        [self openDocument:nil];
        return NO;
    }

    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    self.openedFileDuringLaunch = YES;

    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:filenames.count];
    for (NSString *filename in filenames) {
        [urls addObject:[NSURL fileURLWithPath:filename]];
    }

    [self openFileURLs:urls reuseCurrentWindow:NO];
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (MDVPreviewWindowController *)currentPreviewWindowController {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    if ([window.windowController isKindOfClass:MDVPreviewWindowController.class]) {
        return (MDVPreviewWindowController *)window.windowController;
    }

    return nil;
}

- (MDVPreviewWindowController *)newWindowController {
    MDVPreviewWindowController *controller = [[MDVPreviewWindowController alloc] init];
    __weak typeof(self) weakSelf = self;
    __weak MDVPreviewWindowController *weakController = controller;

    controller.closeHandler = ^{
        if (weakController) {
            [weakSelf.windowControllers removeObject:weakController];
        }
    };

    [self.windowControllers addObject:controller];
    return controller;
}

- (void)presentError:(NSError *)error {
    if (!error) {
        return;
    }

    NSAlert *alert = [NSAlert alertWithError:error];
    [alert runModal];
}

- (void)openFileURLs:(NSArray<NSURL *> *)urls reuseCurrentWindow:(BOOL)reuseCurrentWindow {
    MDVPreviewWindowController *reusableController = reuseCurrentWindow ? [self currentPreviewWindowController] : nil;

    for (NSUInteger index = 0; index < urls.count; index += 1) {
        NSURL *fileURL = urls[index];
        MDVPreviewWindowController *controller = (index == 0 && reusableController) ? reusableController : [self newWindowController];
        NSError *error = nil;

        if (![controller openMarkdownFileURL:fileURL error:&error]) {
            if (controller != reusableController) {
                [self.windowControllers removeObject:controller];
                [controller close];
            }
            [self presentError:error];
            continue;
        }

        [controller showWindow:self];
        [controller.window makeKeyAndOrderFront:self];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

- (void)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"md"],
        [UTType typeWithFilenameExtension:@"markdown"],
        [UTType typeWithFilenameExtension:@"mdown"],
        [UTType typeWithFilenameExtension:@"mkd"],
    ];
    panel.prompt = @"Open";

    [NSApp activateIgnoringOtherApps:YES];

    if ([panel runModal] != NSModalResponseOK) {
        if (self.windowControllers.count == 0) {
            [NSApp terminate:nil];
        }
        return;
    }

    [self openFileURLs:panel.URLs reuseCurrentWindow:YES];
}

- (void)reloadPreview:(id)sender {
    [[self currentPreviewWindowController] reloadPreview:sender];
}

- (void)printDocument:(id)sender {
    [[self currentPreviewWindowController] printDocument:sender];
}

- (void)exportPDF:(id)sender {
    [[self currentPreviewWindowController] exportPDF:sender];
}

- (void)openPDFInDefaultApp:(id)sender {
    [[self currentPreviewWindowController] openPDFInDefaultApp:sender];
}

- (void)revealSourceFile:(id)sender {
    [[self currentPreviewWindowController] revealSourceFile:sender];
}

- (void)toggleDarkMode:(id)sender {
    MDVPreviewWindowController *controller = [self currentPreviewWindowController];
    if (controller && controller.isPreviewReady) {
        [controller.webView evaluateJavaScript:@"toggleTheme()" completionHandler:nil];
    }
}

- (void)runPreviewJavaScript:(NSString *)script {
    MDVPreviewWindowController *controller = [self currentPreviewWindowController];
    if (!controller || !controller.isPreviewReady) {
        return;
    }

    [controller.webView evaluateJavaScript:script completionHandler:nil];
}

- (void)openFindPanel:(id)sender {
    [self runPreviewJavaScript:@"if (typeof mdvToggleFindBar === 'function') { mdvToggleFindBar(); } else if (typeof mdvOpenFindBar === 'function') { mdvOpenFindBar(); }"];
}

- (void)findNextMatch:(id)sender {
    [self runPreviewJavaScript:@"if (typeof mdvFindNextMatch === 'function') { mdvFindNextMatch(); }"];
}

- (void)findPreviousMatch:(id)sender {
    [self runPreviewJavaScript:@"if (typeof mdvFindPreviousMatch === 'function') { mdvFindPreviousMatch(); }"];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    SEL action = item.action;

    if (action == @selector(openDocument:)) {
        return YES;
    }

    MDVPreviewWindowController *controller = [self currentPreviewWindowController];
    if (!controller || !controller.hasLoadedDocument) {
        return NO;
    }

    if (action == @selector(reloadPreview:) || action == @selector(revealSourceFile:)) {
        return YES;
    }

    if (action == @selector(toggleDarkMode:) ||
        action == @selector(openFindPanel:) ||
        action == @selector(findNextMatch:) ||
        action == @selector(findPreviousMatch:) ||
        action == @selector(printDocument:) || action == @selector(exportPDF:) || action == @selector(openPDFInDefaultApp:)) {
        return controller.isPreviewReady;
    }

    return YES;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        MDVAppDelegate *delegate = [[MDVAppDelegate alloc] init];

        application.delegate = delegate;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        [delegate installMainMenu];
        [application run];
    }

    return EXIT_SUCCESS;
}
