package com.xxxy.cctiles;

import android.content.Context;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.graphics.Canvas;
import android.graphics.Outline;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.View;

import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * OxygenOS 17 builds its Quick Settings tile backgrounds in code, so no resource pack
 * can reach them. SepQSResPool publishes the appearance as QSDrawableBuilder objects,
 * a one-method public interface, so this swaps in its own implementation.
 *
 * Starts in log mode and changes nothing. Create /data/local/tmp/cctiles_replace and
 * restart SystemUI to switch to replace mode.
 */
public class Hook implements IXposedHookLoadPackage {

    private static final String TAG = "CCTiles: ";
    private static final String SYSUI = "com.android.systemui";
    private static final String[] POOLS = {
        "com.oplus.systemui.qs.base.res.SepQSResPool",   // the split panel
        "com.oplus.systemui.qs.base.res.StdQSResPool",   // the standard panel
    };
    private static final String BUILDER = "com.oplus.systemui.qs.base.res.model.QSDrawableBuilder";
    private static final File REPLACE = new File("/data/local/tmp/cctiles_replace");

    private static final String[] SETTERS = {
        "updateTileViewDrawable",
        "updateHighLightTileViewDrawable",
        "updateTileThemeDrawable",
        "updateHighLightTileThemeDrawable",
        "updateDetailTileViewDrawable",
        "updateBottomEditTileViewDrawable",
    };

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (!SYSUI.equals(lpparam.packageName)) return;
        final ClassLoader cl = lpparam.classLoader;

        final Class<?> builder;
        try {
            builder = XposedHelpers.findClass(BUILDER, cl);
        } catch (Throwable t) {
            XposedBridge.log(TAG + "builder interface missing, standing down: " + t);
            return;
        }

        for (String poolName : POOLS) {
            Class<?> pool;
            try {
                pool = XposedHelpers.findClass(poolName, cl);
            } catch (Throwable t) {
                XposedBridge.log(TAG + "no " + poolName);
                continue;
            }
            String tag = poolName.substring(poolName.lastIndexOf('.') + 1);
            for (String setter : SETTERS) {
                hook(cl, pool, builder, tag, setter);
            }
            push(cl, pool, builder, tag);
        }
        hookDraw(cl);
    }

    private static void hook(final ClassLoader cl, Class<?> pool, final Class<?> builder,
                             final String tag, final String setter) {
        try {
            pool.getMethod(setter, builder);
        } catch (NoSuchMethodException e) {
            return;                       // this pool does not have that one
        }
        try {
            XposedHelpers.findAndHookMethod(pool, setter, builder, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    Object original = param.args[0];
                    if (original == null || isOurs(original)) return;
                    param.args[0] = Proxy.newProxyInstance(
                            cl, new Class<?>[]{builder}, new Wrapper(tag + "." + setter, original));
                    XposedBridge.log(TAG + tag + "." + setter + " wrapped "
                            + original.getClass().getName());
                }
            });
            XposedBridge.log(TAG + "hooked " + tag + "." + setter);
        } catch (Throwable t) {
            XposedBridge.log(TAG + "could not hook " + tag + "." + setter + ": " + t);
        }
    }

    /**
     * The ROM populates the pools before our hooks attach, so waiting for a setter call
     * never fires. Find each backing MutableStateFlow and put a wrapped builder back.
     */
    private static void push(ClassLoader cl, Class<?> pool, Class<?> builder, String tag) {
        Method getValue;
        try {
            getValue = XposedHelpers.findClass("kotlinx.coroutines.flow.StateFlow", cl)
                    .getMethod("getValue");
        } catch (Throwable t) {
            XposedBridge.log(TAG + "no StateFlow.getValue: " + t);
            return;
        }
        for (String setter : SETTERS) {
            Field field = backingField(pool, setter);
            if (field == null) continue;
            try {
                field.setAccessible(true);
                Object flow = field.get(null);
                Object current = flow == null ? null : getValue.invoke(flow);
                XposedBridge.log(TAG + tag + "." + field.getName() + " holds "
                        + (current == null ? "null" : current.getClass().getName()));
                if (current == null || isOurs(current)) continue;
                Object wrapped = Proxy.newProxyInstance(
                        cl, new Class<?>[]{builder}, new Wrapper(tag + "." + setter, current));
                pool.getMethod(setter, builder).invoke(null, wrapped);
                XposedBridge.log(TAG + "pushed through " + tag + "." + setter);
            } catch (Throwable t) {
                XposedBridge.log(TAG + "push failed " + tag + "." + setter + ": " + t);
            }
        }
    }

    /** updateTileViewDrawable -> the _tileViewDrawable flow, tolerating casing drift. */
    private static Field backingField(Class<?> pool, String setter) {
        String want = "_" + setter.substring("update".length());
        for (Field f : pool.getDeclaredFields()) {
            if (f.getName().equalsIgnoreCase(want)) return f;
        }
        return null;
    }

    private static boolean isOurs(Object o) {
        return Proxy.isProxyClass(o.getClass())
                && Proxy.getInvocationHandler(o) instanceof Wrapper;
    }

    /** Delegates to the real builder, logs what it was asked for, optionally replaces. */
    private static final class Wrapper implements InvocationHandler {
        private final String setter;
        private final Object original;

        Wrapper(String setter, Object original) {
            this.setter = setter;
            this.original = original;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            String name = method.getName();
            if ("equals".equals(name)) return proxy == args[0];
            if ("hashCode".equals(name)) return System.identityHashCode(proxy);
            if ("toString".equals(name)) return "CCTiles[" + setter + " -> " + original + "]";
            if (!"build".equals(name)) return method.invoke(original, args);

            Drawable stock = (Drawable) method.invoke(original, args);
            View view = args != null && args.length > 0 && args[0] instanceof View ? (View) args[0] : null;
            if (view != null && stock != null) OWNER.put(stock, view);
            if (stateActive == 0 && view != null) {
                try {
                    Context c = view.getContext();
                    int id = c.getResources().getIdentifier("state_active", "attr",
                            c.getPackageName());
                    if (id != 0) {
                        stateActive = id;
                        XposedBridge.log(TAG + "state_active resolved to 0x"
                                + Integer.toHexString(id));
                    }
                } catch (Throwable ignored) {
                }
            }
            // One line per setter, not per draw: tiles redraw constantly and this used
            // to fill LSPosed's log.
            if (BUILT.add(setter)) XposedBridge.log(TAG + "build " + setter
                    + " reuse=" + (args != null && args.length > 1 ? args[1] : "?")
                    + " color=" + colorArg(args)
                    + " view=" + (view == null ? "null" : view.getClass().getSimpleName())
                    + " stock=" + describe(stock));

            // Never wrap it. Both LayerDrawable and DrawableWrapper break the ROM's
            // blur and path clipping and the tiles render as plain squares. The edge is
            // painted by hooking the drawable's own draw() instead, see hookDraw().
            return stock;
        }

        private static String colorArg(Object[] args) {
            if (args == null || args.length < 3 || !(args[2] instanceof Integer)) return "null";
            return String.format("#%08X", (Integer) args[2]);
        }
    }

    private static String describe(Drawable d) {
        if (d == null) return "null";
        String s = d.getClass().getSimpleName();
        if (d instanceof ColorDrawable) {
            s += String.format("(#%08X)", ((ColorDrawable) d).getColor());
        } else if (d instanceof GradientDrawable) {
            Object c = ((GradientDrawable) d).getColor();
            if (c != null) s += "(" + c + ")";
        }
        return s;
    }

    private static final String[] TILE_DRAWABLES = {
        "com.oplus.systemui.qs.base.res.drawable.MixColorTileDrawable",
        "com.oplus.systemui.qs.base.res.drawable.GradientTileDrawable",
    };

    /**
     * Paint the Control Center hairline after the ROM has drawn the tile. Hooking draw()
     * leaves the drawable itself untouched, which matters: it carries an AutoBlurDrawable
     * and its own path clipping, and anything that wraps it loses both.
     */
    private static void hookDraw(ClassLoader cl) {
        for (String name : TILE_DRAWABLES) {
            try {
                Class<?> cls = XposedHelpers.findClass(name, cl);
                XposedHelpers.findAndHookMethod(cls, "draw", Canvas.class, new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        if (!REPLACE.exists()) return;
                        try {
                            edge((Drawable) param.thisObject, (Canvas) param.args[0]);
                        } catch (Throwable ignored) {
                        }
                    }
                });
                XposedBridge.log(TAG + "hooked draw on " + name.substring(name.lastIndexOf('.') + 1));
            } catch (Throwable t) {
                XposedBridge.log(TAG + "no draw hook for " + name + ": " + t);
            }
        }
    }

    private static final Paint EDGE = new Paint(Paint.ANTI_ALIAS_FLAG);
    static {
        EDGE.setStyle(Paint.Style.STROKE);
    }

    private static final java.util.Map<Class<?>, Field> PATH_FIELD =
            new java.util.concurrent.ConcurrentHashMap<>();
    /** Which view each tile drawable was built for; the view is what clips the shape. */
    private static final java.util.Map<Drawable, View> OWNER =
            java.util.Collections.synchronizedMap(new java.util.WeakHashMap<Drawable, View>());

    private static final java.util.Set<String> SHAPE =
            java.util.Collections.synchronizedSet(new java.util.HashSet<String>());

    private static final java.util.Map<Class<?>, Field> INNER =
            new java.util.concurrent.ConcurrentHashMap<>();

    private static final java.util.Set<String> PATH_KIND =
            java.util.Collections.synchronizedSet(new java.util.HashSet<String>());
    private static final Field NONE;
    static {
        Field f = null;
        try {
            f = Hook.class.getDeclaredField("NONE");
        } catch (Throwable ignored) {
        }
        NONE = f;
    }

    private static void prepare(Drawable d) {
        boolean night = (Resources.getSystem().getConfiguration().uiMode
                & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        EDGE.setStrokeWidth(Math.max(1f, Resources.getSystem().getDisplayMetrics().density));
        EDGE.setColor(night ? 0x59FFFFFF : 0x1A000000);
    }

    /** The drawable's own shape path, or null if this build does not expose one. */
    private static Path tilePath(Drawable d) {
        Field f = PATH_FIELD.get(d.getClass());
        if (f == null) {
            f = NONE;
            for (Class<?> c = d.getClass(); c != null && f == NONE; c = c.getSuperclass()) {
                try {
                    Field candidate = c.getDeclaredField("oplusPath");
                    candidate.setAccessible(true);
                    f = candidate;
                } catch (NoSuchFieldException ignored) {
                }
            }
            PATH_FIELD.put(d.getClass(), f);
            XposedBridge.log(TAG + d.getClass().getSimpleName()
                    + (f == NONE ? " has no oplusPath field" : " has an oplusPath field"));
        }
        if (f == NONE) return null;
        try {
            Object v = f.get(d);
            if (v == null) return null;
            if (v instanceof Path) return ((Path) v).isEmpty() ? null : (Path) v;
            // com.oplus.graphics.OplusPath is not a Path, it wraps one in mPath.
            Field inner = INNER.get(v.getClass());
            if (inner == null) {
                inner = NONE;
                for (Field c : v.getClass().getDeclaredFields()) {
                    if (Path.class.isAssignableFrom(c.getType())) {
                        c.setAccessible(true);
                        inner = c;
                        break;
                    }
                }
                INNER.put(v.getClass(), inner);
                XposedBridge.log(TAG + v.getClass().getName()
                        + (inner == NONE ? " exposes no Path field"
                                         : " unwrapped via " + inner.getName()));
            }
            if (inner == NONE) return null;
            Object got = inner.get(v);
            return got instanceof Path && !((Path) got).isEmpty() ? (Path) got : null;
        } catch (Throwable t) {
            return null;
        }
    }

    // The tile's active state lives in the drawable's state set, not in build()'s
    // arguments. OPlus does not use the framework attrs here: it defines its own
    // com.android.systemui:attr/state_active, resolved by name at runtime rather than
    // hard coded, since the id moves between ROM builds.
    private static final int STATE_ACTIVE_FALLBACK = 0x7f040b0a;   // 17.0.1.201
    private static volatile int stateActive = 0;
    private static final int STATE_SELECTED = 0x010100a1;
    private static final int STATE_ACTIVATED = 0x010102fe;
    private static final int STATE_CHECKED = 0x010100a0;
    private static final java.util.Set<String> BUILT =
            java.util.Collections.synchronizedSet(new java.util.HashSet<String>());

    private static final java.util.Set<String> SEEN =
            java.util.Collections.synchronizedSet(new java.util.HashSet<String>());

    private static boolean active(int[] state) {
        if (state == null) return false;
        int oplus = stateActive != 0 ? stateActive : STATE_ACTIVE_FALLBACK;
        for (int s : state) {
            if (s == oplus) return true;
            if (s == STATE_SELECTED || s == STATE_ACTIVATED || s == STATE_CHECKED) return true;
        }
        return false;
    }

    private static void edge(Drawable d, Canvas canvas) {
        Rect b = d.getBounds();
        if (b.isEmpty()) return;

        int[] state = d.getState();
        if (SEEN.size() < 12 && SEEN.add(java.util.Arrays.toString(state))) {
            XposedBridge.log(TAG + "state " + java.util.Arrays.toString(state)
                    + " -> " + (active(state) ? "active, no edge" : "edge"));
        }
        // Control Center leaves its active toggles borderless: solid accent, no hairline.
        if (active(state)) return;

        prepare(d);

        // The ROM draws the tile with its own OplusPath, which wraps a real Path in
        // mPath. Stroking that follows whichever shape is set under Quick Settings,
        // Tile shape. Neither outline carries a usable radius, so this is the only
        // source that actually knows the shape.
        Path shape = tilePath(d);
        if (shape != null) {
            canvas.drawPath(shape, EDGE);
            return;
        }

        float width = EDGE.getStrokeWidth();
        View owner = OWNER.get(d);
        if (owner != null) {
            try {
                Outline o = new Outline();
                owner.getOutlineProvider().getOutline(owner, o);
                Rect vr = new Rect();
                if (o.getRect(vr) && !vr.isEmpty()) {
                    // A radius of 0 means "I do not know", not "square": OPlus draws the
                    // real shape with its own OplusPath and reports nothing useful here.
                    float rad = o.getRadius();
                    if (rad < 1f) rad = Math.min(vr.width(), vr.height()) / 2f;
                    if (SHAPE.add(vr.width() + "x" + vr.height() + "r" + rad)) {
                        XposedBridge.log(TAG + "view outline " + vr.width() + "x" + vr.height()
                                + " radius " + rad);
                    }
                    float h2 = width / 2f;
                    canvas.drawRoundRect(vr.left + h2, vr.top + h2, vr.right - h2,
                            vr.bottom - h2, rad, rad, EDGE);
                    return;
                }
            } catch (Throwable ignored) {
            }
        }



        float radius = Math.min(b.width(), b.height()) / 2f;
        Rect r = new Rect(b);
        try {
            Outline outline = new Outline();
            d.getOutline(outline);
            Rect got = new Rect();
            if (outline.getRect(got) && !got.isEmpty()) {
                r.set(got);
                float got_r = outline.getRadius();
                if (got_r > 1f) radius = got_r;   // the ROM reports 0 for its squircle
            }
        } catch (Throwable ignored) {
        }
        float half = width / 2f;
        canvas.drawRoundRect(r.left + half, r.top + half, r.right - half, r.bottom - half,
                radius, radius, EDGE);
    }

    private static float dp(Context ctx, float v) {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                ctx.getResources().getDisplayMetrics());
    }
}
