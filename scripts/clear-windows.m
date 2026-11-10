// Makes every window a test process creates fully transparent, so test runs don't flash windows
// on the screen. `scripts/test` builds this into a dylib and loads it into each test bundle with
// DYLD_INSERT_LIBRARIES; the app never loads it.
//
// A clear window is still visible to AppKit: it orders in, lays out, becomes key and takes
// sheets as before; the window server just draws nothing. Moving windows offscreen doesn't work,
// since AppKit moves a titled window back onto a screen when it orders in. The hook is the
// designated initializer because every window, panel, sheet and alert goes through it, while
// showing one has several paths, `orderFrontRegardless` among them.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static IMP original;

static id clearWindow(
    NSWindow *self, SEL _cmd, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing,
    BOOL defer) {
    NSWindow *window = ((id(*)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL))
                            original)(self, _cmd, rect, style, backing, defer);
    window.alphaValue = 0;
    return window;
}

__attribute__((constructor)) static void install(void) {
    Method init = class_getInstanceMethod(
        [NSWindow class], @selector(initWithContentRect:styleMask:backing:defer:));
    original = method_setImplementation(init, (IMP)clearWindow);
}
