// Phase 4 tasks 4 and 5 on macOS: mac_clip_files and mac_clip_image read private pasteboards (file URLs, a
// PNG, a TIFF made PNG by the system, text beside each, an image over the limit), and the view's drop methods
// (draggingEntered:, draggingExited:, performDragOperation:) report a drag whose pasteboard is private, called
// as AppKit calls them with a stand-in for NSDraggingInfo. Never linked into rhun; never the desktop's board.
#import <AppKit/AppKit.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint64_t value, aux; } Result;
extern Result fixture_call(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
#define CORE(name) extern void name(void) __asm__(#name)
CORE(mac_clip_files); CORE(mac_clip_image); CORE(mem_free); CORE(drop_over); CORE(drop_take);
CORE(drop_frame); CORE(mac_drag_enter); CORE(mac_drag_update); CORE(mac_drag_exit); CORE(mac_drag_perform);
#define C1(f,a) fixture_call((void *)f,(uint64_t)(a),0,0,0,0,0)
#define C2(f,a,b) fixture_call((void *)f,(uint64_t)(a),(uint64_t)(b),0,0,0,0)
#define C4(f,a,b,c,d) fixture_call((void *)f,(uint64_t)(a),(uint64_t)(b),(uint64_t)(c),(uint64_t)(d),0,0)

static NSPasteboard *board;
static void failure(int line) {
    fprintf(stderr, "FAIL mac clipboard kinds line %d\n", line);
    [board releaseGlobally];
    exit(1);
}
#define CHECK(...) do { if (!(__VA_ARGS__)) failure(__LINE__); } while (0)

@interface FakeDrag : NSObject
@property (strong) NSPasteboard *pb;
- (NSPasteboard *)draggingPasteboard;
- (NSPoint)draggingLocation;
@end
@implementation FakeDrag
- (NSPasteboard *)draggingPasteboard { return self.pb; }
- (NSPoint)draggingLocation { return NSMakePoint(0, 0); }
@end

static NSData *files(void) {
    Result r = C1(mac_clip_files, (__bridge void *)board);
    if (!r.value) { CHECK(r.aux == 0); return nil; }
    NSData *copy = [NSData dataWithBytes:(void *)r.value length:(NSUInteger)r.aux];
    C1(mem_free, r.value);
    return copy;
}
static NSData *image(uint64_t limit, int64_t *count) {
    Result r = C2(mac_clip_image, (__bridge void *)board, limit);
    *count = (int64_t)r.aux;
    if (!r.value) return nil;
    NSData *copy = [NSData dataWithBytes:(void *)r.value length:(NSUInteger)r.aux];
    C1(mem_free, r.value);
    return copy;
}
static NSData *pngOf(int side) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:side
        pixelsHigh:side bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSData *tiffOf(int side) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:side
        pixelsHigh:side bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    return [rep TIFFRepresentation];
}

int test_mac_clipboard_kinds(int argc, char **argv) {
    (void)argc; (void)argv;
    @autoreleasepool {
        board = [NSPasteboard pasteboardWithUniqueName];
        int64_t n;
        // two file URLs and text beside them: the paths, a NUL after each; no image
        NSString *a = @"/tmp/rhun kinds/a.txt", *b = @"/tmp/rhun\nkinds/b\x1b.png";
        [board clearContents];
        CHECK([board writeObjects:@[[NSURL fileURLWithPath:a], [NSURL fileURLWithPath:b]]]);
        [board setString:@"the text" forType:NSPasteboardTypeString];
        NSMutableData *want = [NSMutableData data];
        [want appendBytes:a.fileSystemRepresentation length:strlen(a.fileSystemRepresentation) + 1];
        [want appendBytes:b.fileSystemRepresentation length:strlen(b.fileSystemRepresentation) + 1];
        CHECK([files() isEqual:want]);
        CHECK(image(100, &n) == nil && n == 0);
        // a PNG and text: the PNG's bytes, no files
        NSData *png = pngOf(3);
        [board clearContents];
        CHECK([board setData:png forType:NSPasteboardTypePNG]);
        [board setString:@"beside" forType:NSPasteboardTypeString];
        CHECK(files() == nil);
        CHECK([image(png.length + 1, &n) isEqual:png] && n == (int64_t)png.length);
        // the same PNG over the limit: not copied, -1
        CHECK(image(png.length, &n) == nil && n == -1);
        // a TIFF alone: the system's PNG of it
        [board clearContents];
        CHECK([board setData:tiffOf(2) forType:NSPasteboardTypeTIFF]);
        NSData *made = image(1 << 20, &n);
        CHECK(made != nil && made.length > 8 && memcmp(made.bytes, "\x89PNG\r\n\x1a\n", 8) == 0);
        // text alone: nothing of either kind
        [board clearContents];
        [board setString:@"only text" forType:NSPasteboardTypeString];
        CHECK(files() == nil);
        CHECK(image(1 << 20, &n) == nil && n == 0);
        // the view's drop methods with a drag whose pasteboard is private
        [board clearContents];
        CHECK([board writeObjects:@[[NSURL fileURLWithPath:a]]]);
        FakeDrag *drag = [FakeDrag new];
        drag.pb = board;
        C1(mac_clip_files, NULL);           // (the IMPs continue the x86 stack the last entry recorded)
        typedef NSUInteger (*Op)(id, SEL, id);
        typedef void (*Exit)(id, SEL, id);
        typedef BOOL (*Perform)(id, SEL, id);
        CHECK(((Op)mac_drag_enter)(nil, NULL, drag) == NSDragOperationCopy);
        CHECK(C4(drop_over, 0, 0, 10, 10).value == 1);
        ((Exit)mac_drag_exit)(nil, NULL, drag);
        CHECK(C4(drop_over, 0, 0, 10, 10).value == 0);
        CHECK(((Op)mac_drag_update)(nil, NULL, drag) == NSDragOperationCopy);
        CHECK(((Perform)mac_drag_perform)(nil, NULL, drag) == YES);
        Result taken = C4(drop_take, 0, 0, 10, 10);
        want = [NSMutableData dataWithBytes:a.fileSystemRepresentation length:strlen(a.fileSystemRepresentation) + 1];
        CHECK(taken.value != 0 && [[NSData dataWithBytes:(void *)taken.value length:taken.aux] isEqual:want]);
        CHECK(C4(drop_take, 0, 0, 10, 10).value == 0);          // once
        // a drag of text alone: no copy operation, no drop
        [board clearContents];
        [board setString:@"words" forType:NSPasteboardTypeString];
        CHECK(((Op)mac_drag_enter)(nil, NULL, drag) == 0);
        CHECK(((Perform)mac_drag_perform)(nil, NULL, drag) == NO);
        [board releaseGlobally];
    }
    fputs("ok mac clipboard kinds and drops\n", stderr);
    return 0;
}
