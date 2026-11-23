# CC Tiles

A small LSPosed module that gives OxygenOS 17 Quick Settings tiles a Control
Center style hairline edge: inactive tiles get a thin brighter outline, active
tiles are left alone on their accent fill.

Built and tested against OOS17 `CPH2747_17.0.1.201` on a OnePlus 15. Other
OxygenOS builds are untested.

## Build

```bash
./gradlew :app:assembleRelease
```

Output lands in `app/build/outputs/apk/release/`. Nothing to configure: the
Xposed API comes from `https://api.xposed.info/` as a `compileOnly`
dependency, declared in `settings.gradle.kts`, because it is not on Maven
Central.

To sign with your own key, drop a `keystore.properties` in the repo root:

```properties
storeFile=/path/to/key.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Without it the debug key is used, which is fine for a sideloaded module.

## Use

Install, enable in LSPosed with **System UI** in scope, restart SystemUI.

**It starts in log mode and changes nothing.** That default exists because the
module was written by instrumenting a live SystemUI. To switch the restyle on:

```bash
su -c 'touch /data/local/tmp/cctiles_replace'
```

Then restart SystemUI. Delete the file to revert. No rebuild either way.

## Why a module and not a resource pack

Oxygen Customizer can replace SystemUI resources from a pack, but **it cannot
reach these tiles**, and that is worth knowing independently of this module.
`res/layout/oplus_qs_tile_1x1.xml` has no `android:background`: OOS17 builds
the tile background in code. Replacing `drawable/status_bar_qs_tile_bg_inactive`
and then `color/status_bar_qs_tile_bg_color_inactive` through a style pack both
rendered pixel identical, with the mappings verified present in the built APK.
Those resources are left over from the older QS and nothing draws them now.

## How it works

`com.oplus.systemui.qs.base.res.StdQSResPool` publishes tile appearance through
static setters that take a `QSDrawableBuilder`, a public interface with a single
method:

```java
Drawable build(View view, boolean reuse, Integer color);
```

The module hooks those setters and substitutes a `java.lang.reflect.Proxy`
implementing that interface, so it can see every tile drawable the ROM builds.
It also pushes a wrapper into the pool's `StateFlow` directly, because the ROM
populates it before the hooks attach.

Four things that are easy to get wrong, all learned the hard way:

- **`StdQSResPool` is the live pool, not `SepQSResPool`.** Both exist and both
  hook cleanly; only Std draws.
- **Never wrap the ROM's drawable.** `MixColorTileDrawable` is a
  `DrawableWrapper` around an `AutoBlurDrawable` and carries the blur and the
  path clipping. Both `LayerDrawable` and `DrawableWrapper` break it and the
  tiles render as plain squares. The module returns the stock drawable untouched
  and hooks its `draw(Canvas)`, painting the edge afterwards.
- **Active state is `com.android.systemui:attr/state_active`**, not
  `state_selected`, `state_activated` or `state_checked`. Read it from
  `drawable.getState()`; the `Integer color` argument is always null. The id is
  resolved by name at runtime because it moves between builds.
- **The tile shape is in `OplusPath.mPath`.** Both `drawable.getOutline()` and
  `view.getOutlineProvider().getOutline()` report a radius of 0, which means
  unknown rather than square; taking it literally draws a box around a squircle.
  The drawable's private `oplusPath` field is a `com.oplus.graphics.OplusPath`
  from `oplus-framework.jar`, which is not an `android.graphics.Path` but wraps
  one in `mPath`. Stroking that follows whichever shape is set under Quick
  Settings, Tile shape.

## Caveat

These are OPlus internals, not AOSP. Class and method names can change in any
OxygenOS update. The module guards its lookups and stands down quietly if the
pool or the builder interface is missing, rather than taking SystemUI with it.
Logging is one-shot per setter, so it does not grow with use.
