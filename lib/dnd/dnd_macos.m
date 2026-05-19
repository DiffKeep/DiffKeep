/*
 * dnd_macos.m — macOS AppKit NSDraggingSession drag source.
 *
 * Exposes:
 *   bool dnd_macos_init(void *sdl_window)
 *   void dnd_macos_deinit(void)
 *   void dnd_macos_start_drag(const char **paths, int path_count,
 *                              const void **jpeg_bufs, const size_t *jpeg_lens)
 *   bool dnd_macos_is_dragging(void)
 */

#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stddef.h>

/* SDL3 property key for the NSWindow pointer */
#ifndef SDL_PROP_WINDOW_COCOA_WINDOW_POINTER
#define SDL_PROP_WINDOW_COCOA_WINDOW_POINTER "SDL.window.cocoa.window"
#endif

/* SDL3 opaque type forward declarations (we only need these two). */
typedef void SDL_Window;
typedef unsigned int SDL_PropertiesID;
extern SDL_PropertiesID SDL_GetWindowProperties(SDL_Window *window);
extern void *SDL_GetPointerProperty(SDL_PropertiesID props, const char *name,
                                    void *default_value);

/* ── Module-level state ───────────────────────────────────────────────────── */

static NSView          *g_ns_view       = nil;
static id<NSObject>     g_monitor       = nil;
static NSEvent         *g_last_mouse_down = nil;
static volatile bool    g_is_dragging   = false;

/* ── DKDragSource ─────────────────────────────────────────────────────────── */

@interface DKDragSource : NSObject <NSDraggingSource>
@end

@implementation DKDragSource

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    (void)session; (void)context;
    return NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation
{
    (void)session; (void)screenPoint; (void)operation;
    g_is_dragging = false;
}

@end

static DKDragSource *g_drag_source = nil;

/* ── Public API ───────────────────────────────────────────────────────────── */

bool dnd_macos_init(void *sdl_window) {
    @autoreleasepool {
        SDL_PropertiesID props = SDL_GetWindowProperties((SDL_Window *)sdl_window);
        NSWindow *nswin = (__bridge NSWindow *)SDL_GetPointerProperty(
            props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
        if (!nswin) return false;

        g_ns_view = nswin.contentView;
        if (!g_ns_view) return false;

        g_drag_source = [[DKDragSource alloc] init];

        /* Capture each left-mouse-down so we have a valid event for
         * beginDraggingSessionWithItems:event:source:. */
        g_monitor = [NSEvent
            addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
            handler:^NSEvent *(NSEvent *ev) {
                g_last_mouse_down = ev; /* ARC retains */
                return ev;             /* still delivered to SDL */
            }];

        return true;
    }
}

void dnd_macos_deinit(void) {
    @autoreleasepool {
        if (g_monitor) {
            [NSEvent removeMonitor:g_monitor];
            g_monitor = nil;
        }
        g_last_mouse_down = nil;
        g_drag_source     = nil;
        g_ns_view         = nil;
    }
}

void dnd_macos_start_drag(
    const char  **paths,     int          path_count,
    const void  **jpeg_bufs, const size_t *jpeg_lens)
{
    @autoreleasepool {
        if (!g_ns_view || !g_drag_source || !g_last_mouse_down) return;
        if (path_count <= 0) return;

        NSMutableArray<NSDraggingItem *> *items = [NSMutableArray array];

        int n = path_count < 3 ? path_count : 3; /* AppKit stacks up to ~3 visibly */
        for (int i = 0; i < n; i++) {
            NSString *pathStr = [NSString stringWithUTF8String:paths[i]];
            if (!pathStr) continue;

            NSURL *url = [NSURL fileURLWithPath:pathStr];
            NSPasteboardItem *pbi = [[NSPasteboardItem alloc] init];
            [pbi setString:url.absoluteString forType:NSPasteboardTypeFileURL];

            NSDraggingItem *di = [[NSDraggingItem alloc]
                initWithPasteboardWriter:pbi];

            /* Dragging frame in view coordinates, offset to stack visibly. */
            NSPoint loc = [g_ns_view
                convertPoint:[g_last_mouse_down locationInWindow]
                    fromView:nil];
            float off = (float)i * 4.0f;
            NSRect frame = NSMakeRect(loc.x - 32.0f + off,
                                      loc.y - 32.0f - off,
                                      64.0f, 64.0f);

            NSImage *thumb = nil;
            if (jpeg_bufs && jpeg_bufs[i] && jpeg_lens && jpeg_lens[i] > 0) {
                NSData *d = [NSData dataWithBytes:jpeg_bufs[i]
                                          length:jpeg_lens[i]];
                thumb = [[NSImage alloc] initWithData:d];
            }

            [di setDraggingFrame:frame contents:thumb];
            [items addObject:di];
        }

        if (items.count == 0) return;

        g_is_dragging = true;
        [g_ns_view beginDraggingSessionWithItems:items
                                           event:g_last_mouse_down
                                          source:g_drag_source];
    }
}

bool dnd_macos_is_dragging(void) {
    return g_is_dragging;
}
