#import <Foundation/Foundation.h>

// Mach service the on-demand launchd agent registers; the Quick Look
// extension holds a mach-lookup entitlement exception for this exact name.
static NSString *const MDVRenderHelperServiceName = @"com.local.markdown-viewer.render-helper";

@protocol MDVRenderHelperProtocol

- (void)renderMermaidSource:(NSString *)source
                      theme:(NSString *)theme
                  withReply:(void (^)(NSString *_Nullable svg, NSString *_Nullable errorMessage))reply;

@end
