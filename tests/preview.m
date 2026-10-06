#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Wnullability-completeness-on-arrays"
#define main MDVApplicationMain
#import "../src/main.m"
#undef main
#pragma clang diagnostic pop
#import <objc/runtime.h>

static NSInteger alertResponse = NSAlertFirstButtonReturn;
static NSInteger TestAlert(id self, SEL selector) { return alertResponse; }

static void Check(BOOL value, NSString *message) {
    if (!value) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static BOOL Wait(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

static id JavaScript(MDVPreviewWindowController *controller, NSString *script) {
    __block BOOL done = NO;
    __block id value = nil;
    __block NSError *failure = nil;
    [controller.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        value = result;
        failure = error;
        done = YES;
    }];
    Check(Wait(^BOOL { return done; }), [@"JavaScript timed out: " stringByAppendingString:[script substringToIndex:MIN(script.length, 100)]]);
    Check(!failure, failure.localizedDescription ?: @"JavaScript failed");
    return value;
}

static void Open(MDVPreviewWindowController *controller, NSURL *url) {
    Check([controller openDocumentFileURL:url], @"Open rejected");
    Check(Wait(^BOOL { return controller.isPreviewReady; }), @"Preview did not finish");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:MDVClickToEditKey];
        method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)TestAlert);
        NSURL *directory = [[NSFileManager defaultManager].temporaryDirectory
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *json = [directory URLByAppendingPathComponent:@"source.json"];
        NSString *original = @"{\"value\":\"hello\",\"literal\":\"</script>雪 __MDV_ASSETS__\"}\n";
        [original writeToURL:json atomically:YES encoding:NSUTF8StringEncoding error:nil];
        MDVPreviewWindowController *controller = [[MDVPreviewWindowController alloc] init];
        Open(controller, json);
        Check([JavaScript(controller, @"document.querySelector('.doc-plain').textContent") isEqual:original], @"Source text changed");
        Check([JavaScript(controller, @"document.querySelector('.doc-plain').contentEditable") isEqual:@"false"], @"Editing must default off");
        Check([JavaScript(controller, @"[...document.scripts].every(s => !/mermaid|katex|marked|purify/.test(s.src))") boolValue], @"JSON loaded Markdown assets");
        MDVAppDelegate *delegate = [[MDVAppDelegate alloc] init];
        [delegate.windowControllers addObject:controller];
        [delegate toggleClickToEdit:nil];

        JavaScript(controller, @"const surface = document.querySelector('.doc-plain'); surface.textContent = '{\"value\":\"edited\"}'; surface.dispatchEvent(new Event('input')); mdvOpenFindBar(); document.querySelector('.find-panel__input').value = 'edited'; document.querySelector('.find-panel__input').dispatchEvent(new Event('input'));");
        Check(Wait(^BOOL { return controller.dirty; }), @"Dirty state missing");
        Check(Wait(^BOOL { return [JavaScript(controller, @"document.querySelectorAll('.find-match').length") integerValue] == 1; }), @"Search failed");
        JavaScript(controller, @"mdvCloseFindBar()");
        Check([JavaScript(controller, @"document.querySelector('.doc-plain').textContent") isEqual:@"{\"value\":\"edited\"}"], @"Search discarded edits");
        Check(![controller windowShouldClose:controller.window], @"Close discarded edits");
        Check(![controller openDocumentFileURL:json], @"Reload discarded edits");
        alertResponse = NSAlertSecondButtonReturn;
        Open(controller, json);
        Check(!controller.dirty, @"Discard left dirty state");

        JavaScript(controller, @"document.querySelector('.doc-plain').textContent = '{\"value\":\"saved\"}'; document.querySelector('.doc-plain').dispatchEvent(new Event('input'));");
        Check(Wait(^BOOL { return controller.dirty; }), @"Dirty state missing before save");
        [@"{\"value\":\"external\"}" writeToURL:json atomically:YES encoding:NSUTF8StringEncoding error:nil];
        alertResponse = NSAlertFirstButtonReturn;
        JavaScript(controller, @"document.querySelector('.doc-plain').dispatchEvent(new KeyboardEvent('keydown', {key:'s', metaKey:true, bubbles:true}))");
        Check(Wait(^BOOL { return [JavaScript(controller, @"document.querySelector('.doc-plain').contentEditable") isEqual:@"true"]; }), @"Canceled save left editing locked");
        Check(controller.dirty, @"Canceled save lost dirty state");
        Check([[NSString stringWithContentsOfURL:json encoding:NSUTF8StringEncoding error:nil] containsString:@"external"], @"Canceled save overwrote external changes");
        alertResponse = NSAlertSecondButtonReturn;
        JavaScript(controller, @"document.querySelector('.doc-plain').dispatchEvent(new KeyboardEvent('keydown', {key:'s', metaKey:true, bubbles:true}))");
        Check(Wait(^BOOL { return !controller.dirty; }), @"Save did not clear dirty state");
        Check([[NSString stringWithContentsOfURL:json encoding:NSUTF8StringEncoding error:nil] containsString:@"saved"], @"Save did not write edits");

        NSURL *markdown = [directory URLByAppendingPathComponent:@"source.md"];
        [@"# Read\n\nHello [link](source.json).\n" writeToURL:markdown atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Open(controller, markdown);
        Check([JavaScript(controller, @"document.querySelector('h1').textContent") isEqual:@"Read"], @"Markdown failed");
        Check([JavaScript(controller, @"!window.mermaid && !window.katex") boolValue], @"Plain Markdown loaded optional assets");
        JavaScript(controller, @"document.querySelector('h1').click(); document.querySelector('textarea').value += 'edit'; document.querySelector('textarea').dispatchEvent(new Event('input'))");
        Check(Wait(^BOOL { return controller.dirty; }), @"Markdown edits not tracked");
        JavaScript(controller, @"document.querySelector('textarea').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}))");
        Check(Wait(^BOOL { return !controller.dirty && controller.isPreviewReady; }), @"Markdown discard failed");

        [@"# Math\n\n$x^2$\n\n```mermaid\ngraph TD; A-->B\n```\n" writeToURL:markdown atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Open(controller, markdown);
        Check([JavaScript(controller, @"!!document.querySelector('.katex') && !!document.querySelector('.mermaid-diagram__image')") boolValue], @"Optional rendering failed");
        Check([JavaScript(controller, @"[...document.scripts].filter(s => s.src.endsWith('mermaid.min.js')).length") integerValue] == 1, @"Mermaid loaded more than once");

        NSURL *yaml = [directory URLByAppendingPathComponent:@"source.yaml"];
        NSString *yamlSource = @"name: 雪\nvalue: hello\n";
        [yamlSource writeToURL:yaml atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Open(controller, yaml);
        JavaScript(controller, @"const surface = document.querySelector('.doc-plain'); surface.dispatchEvent(new InputEvent('beforeinput')); surface.textContent += 'added: true\\n'; surface.dispatchEvent(new Event('input')); surface.dispatchEvent(new KeyboardEvent('keydown', {key:'z', metaKey:true, bubbles:true}))");
        Check([JavaScript(controller, @"document.querySelector('.doc-plain').textContent") isEqual:yamlSource], @"Undo changed YAML source");
        Check(Wait(^BOOL { return !controller.dirty; }), @"Undo failed to clear dirty state");
        JavaScript(controller, @"document.querySelector('.doc-plain').dispatchEvent(new KeyboardEvent('keydown', {key:'z', metaKey:true, shiftKey:true, bubbles:true}))");
        NSString *redo = JavaScript(controller, @"document.querySelector('.doc-plain').textContent");
        Check([redo hasSuffix:@"added: true\n"], [@"Redo failed: " stringByAppendingString:redo]);
        Check(Wait(^BOOL { return controller.dirty; }), @"Redo failed to restore dirty state");
        alertResponse = NSAlertFirstButtonReturn;
        Check([delegate applicationShouldTerminate:NSApp] == NSTerminateCancel, @"Quit discarded edits");
        alertResponse = NSAlertSecondButtonReturn;
        Open(controller, yaml);

        NSString *largeSource = [@"x" stringByPaddingToLength:3 * 1024 * 1024 withString:@"x" startingAtIndex:0];
        NSString *largeJSON = [NSString stringWithFormat:@"\"%@\"", largeSource];
        [largeJSON writeToURL:json atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Open(controller, json);
        JavaScript(controller, @"const surface = document.querySelector('.doc-plain'); surface.dispatchEvent(new InputEvent('beforeinput')); surface.textContent += ' '; surface.dispatchEvent(new Event('input')); surface.dispatchEvent(new KeyboardEvent('keydown', {key:'z', metaKey:true, bubbles:true}))");
        Check([JavaScript(controller, @"document.querySelector('.doc-plain').textContent") isEqual:largeJSON], @"Large-document undo failed");
        Check(Wait(^BOOL { return !controller.dirty; }), @"Large-document undo left dirty state");

        for (NSNumber *size in @[@1024, @1048576, @10485760]) {
            NSMutableString *source = [NSMutableString stringWithString:@"\""];
            [source appendString:[@"x" stringByPaddingToLength:size.unsignedIntegerValue - 2 withString:@"x" startingAtIndex:0]];
            [source appendString:@"\""];
            [source writeToURL:json atomically:YES encoding:NSUTF8StringEncoding error:nil];
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            NSString *content = nil;
            NSURL *preview = [controller previewHTMLURLForFileURL:json content:&content error:nil];
            Check(preview != nil, @"Preview generation failed");
            printf("%lu KiB: %.1f ms\n", size.unsignedIntegerValue / 1024, (CFAbsoluteTimeGetCurrent() - start) * 1000);
            [[NSFileManager defaultManager] removeItemAtURL:preview error:nil];
        }
        [controller close];
        [[NSFileManager defaultManager] removeItemAtURL:directory error:nil];
        puts("PASS: rendering, lazy assets, search, undo/redo, dirty state, discard, save conflicts.");
    }
    return 0;
}
