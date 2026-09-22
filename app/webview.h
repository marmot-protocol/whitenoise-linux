// The shared-memory contract between the app and wn-webview. Mirrored
// on the Odin side in app/webembed.odin; both sides must agree on this
// layout byte for byte.
#ifndef WN_WEBVIEW_H
#define WN_WEBVIEW_H

#define WN_EV_CAP 256 // input ring slots; a dropped event is a lost click

enum {
    WN_EV_MOVE = 1,
    WN_EV_DOWN = 2,
    WN_EV_UP = 3,
    WN_EV_SCROLL = 4,
    WN_EV_KEY_DOWN = 5,
    WN_EV_KEY_UP = 6,
};

struct WnEvent {
    unsigned kind;
    unsigned arg;  // button number, or GDK keyval
    unsigned mods; // GdkModifierType
    unsigned pad;
    double x, y;   // widget-local pointer position
    double dx, dy; // scroll deltas
};

struct WnShm {
    unsigned seq;            // bumped by the child after each frame
    unsigned quit;           // set by the parent to end the child
    unsigned head;           // written by the parent
    unsigned tail;           // written by the child
    unsigned w, h;           // size of the published frame, written by the child
    unsigned want_w, want_h; // size the parent wants, in device pixels
    unsigned zoom_milli;     // page zoom * 1000, so CSS pixels stay legible
    unsigned pad;
    struct WnEvent events[WN_EV_CAP];
    unsigned char pixels[]; // w * h * 4, RGBA, up to the agreed capacity
};

#endif
