import ctypes as c
import pathlib
import sys
import os
import time

root = pathlib.Path(sys.argv[1])
gtk = c.CDLL('/nix/store/yl5yl395iqx88kd1m7lx7p7b65n0jfx9-gtk+3-3.24.51/lib/libgtk-3.so.0')
def fn(name, result, *args):
    f = getattr(gtk, name)
    f.restype, f.argtypes = result, list(args)
    return f
p, i, d = c.c_void_p, c.c_int, c.c_double
fn('g_set_prgname', None, c.c_char_p)(os.environ['FIXTURE_CLASS'].encode())
assert fn('gtk_init_check', i, p, p)(None, None)
window = fn('gtk_window_new', p, i)(0)
fn('gtk_window_set_title', None, p, c.c_char_p)(window, os.environ['FIXTURE_TITLE'].encode())
fn('gtk_window_set_decorated', None, p, i)(window, 0)
fn('gtk_window_set_default_size', None, p, i, i)(window, 640, 440)
if os.getenv('RESIZE_ALPHA'):
    screen = fn('gtk_widget_get_screen', p, p)(window)
    visual = fn('gdk_screen_get_rgba_visual', p, p)(screen)
    assert visual
    fn('gtk_widget_set_visual', None, p, p)(window, visual)
    fn('gtk_widget_set_app_paintable', None, p, i)(window, 1)
area = fn('gtk_drawing_area_new', p)()
fn('gtk_container_add', None, p, p)(window, area)
width = fn('gtk_widget_get_allocated_width', i, p)
height = fn('gtk_widget_get_allocated_height', i, p)
color = fn('cairo_set_source_rgb', None, p, d, d, d)
rect = fn('cairo_rectangle', None, p, d, d, d, d)
fill = fn('cairo_fill', None, p)
@c.CFUNCTYPE(i, p, p, p)
def draw(widget, cr, data):
    w, h = width(widget), height(widget)
    arm = root / 'arm'
    changed = arm.exists() and [w, h] != list(map(int, arm.read_text().split()))
    if changed and os.getenv('RESIZE_DELAY') and not (root/'delayed').exists():
        (root/'delayed').touch()
        time.sleep(float(os.environ['RESIZE_DELAY']))
    if os.getenv('RESIZE_ALPHA'):
        fn('cairo_set_operator', None, p, i)(cr, 1)
        fn('cairo_set_source_rgba', None, p, d, d, d, d)(cr, int(changed), 0, int(not changed), .5)
    else:
        color(cr, *[float(x) for x in os.environ['FIXTURE_COLOR'].split(',')])
    rect(cr, 0, 0, w, h)
    fill(cr)
    color(cr, 1, 1, 1)
    for fraction in (0.25, 0.75):
        rect(cr, w * fraction, 0, 3, h)
        fill(cr)
        rect(cr, 0, h * fraction, w, 3)
        fill(cr)
    if changed and not (root / 'frame-ready').exists():
        (root / 'frame-ready').write_text(str(time.monotonic()))
    (root / 'client-size').write_text(f'{w} {h}')
    return 0
fn('g_signal_connect_data', c.c_ulong, p, c.c_char_p, p, p, p, i)(area, b'draw', c.cast(draw, p), None, None, 0)
fn('gtk_widget_show_all', None, p)(window)
@c.CFUNCTYPE(i, p)
def repaint(data):
    fn('gtk_widget_queue_draw', None, p)(area)
    return 1
if not os.getenv('RESIZE_NO_REPAINT'):
    fn('g_timeout_add', c.c_uint, c.c_uint, p, p)(100, c.cast(repaint, p), None)

if os.getenv('FIXTURE_INPUT'):
    fn('gtk_widget_add_events', None, p, i)(area, (1 << 8) | (1 << 21) | (1 << 23))
    fn('gtk_widget_set_can_focus', None, p, i)(area, 1)
    fn('gtk_widget_grab_focus', None, p)(area)
    @c.CFUNCTYPE(i, p, p, p)
    def clicked(widget, event, data):
        x, y = d(), d()
        fn('gdk_event_get_coords', i, p, p, p)(event, c.byref(x), c.byref(y))
        (root/'click').write_text(f'{x.value} {y.value}')
        return 0
    @c.CFUNCTYPE(i, p, p, p)
    def key(widget, event, data):
        value = c.c_uint()
        fn('gdk_event_get_keyval', i, p, p)(event, c.byref(value))
        with (root/'keys').open('a') as f: f.write(str(value.value)+'\n')
        return 0
    @c.CFUNCTYPE(i, p, p, p)
    def scroll(widget, event, data):
        (root/'scroll').touch()
        return 1
    for widget, name, callback in [(area,b'button-press-event',clicked),(window,b'key-press-event',key),(area,b'scroll-event',scroll)]:
        fn('g_signal_connect_data', c.c_ulong, p, c.c_char_p, p, p, p, i)(widget,name,c.cast(callback,p),None,None,0)
fn('gtk_main', None)()
