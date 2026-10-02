#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import "native_actions_darwin.h"
#import "_cgo_export.h"

@interface BlankEditingActions : NSObject <NSMenuItemValidation>
@end
@implementation BlankEditingActions
- (void)blankUndo:(id)sender {
    id responder = NSApp.keyWindow.firstResponder;
    if ([responder isKindOfClass:NSTextView.class]) { [[responder undoManager] undo]; return; }
    blankDocumentHistoryRequested((void *)(NSApp.mainWindow ?: NSApp.keyWindow), 0);
}
- (void)blankRedo:(id)sender {
    id responder = NSApp.keyWindow.firstResponder;
    if ([responder isKindOfClass:NSTextView.class]) { [[responder undoManager] redo]; return; }
    blankDocumentHistoryRequested((void *)(NSApp.mainWindow ?: NSApp.keyWindow), 1);
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { return YES; }
@end
static BlankEditingActions *editingActions;
void blankInstallEditingActions(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!editingActions) editingActions = [BlankEditingActions new];
        for (NSMenuItem *parent in NSApp.mainMenu.itemArray) {
            for (NSMenuItem *item in parent.submenu.itemArray) {
                NSString *action = NSStringFromSelector(item.action);
                if ([action isEqualToString:@"undo:"] || [action isEqualToString:@"redo:"]) {
                    item.target = editingActions;
                    item.action = [action isEqualToString:@"undo:"] ? @selector(blankUndo:) : @selector(blankRedo:);
                }
            }
        }
    });
}

char *blankApplicationID(void) {
 return strdup(([NSBundle mainBundle].bundleIdentifier ?: @"local.still.writer").UTF8String);
}

char *blankFontFamilies(void) {
    @autoreleasepool {
        CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
        if (!families) return NULL;
        NSData *json = [NSJSONSerialization dataWithJSONObject:(NSArray *)families options:0 error:nil];
        CFRelease(families);
        if (!json) return NULL;
        NSString *value = [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease];
        return strdup(value.UTF8String);
    }
}
