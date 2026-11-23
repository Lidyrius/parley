# noVNC (vendored for the iPhone app)

The iPhone app's remote desktop (docs/IPHONE.md → Protocol v10) runs noVNC's RFB client in a
web view; its socket is replaced by the relay channel (`ios/ParleyMobile/VNC/vnc.html`).

- **Version:** `@novnc/novnc` 1.7.0 from npm
  (tarball sha256 `32689f18d6abe96bc6530828a6bd0b9ae33bda07c083a6575ed255b5a8f2e903`).
- **Bundle:** `ios/ParleyMobile/VNC/novnc.js` — one unminified IIFE script, global `NoVNC`:
  `NoVNC.default` is the `RFB` class, `NoVNC.keysyms` (`core/input/keysymdef.js`) and
  `NoVNC.KeyTable` (`core/input/keysym.js`) serve the iOS keyboard.
- **License:** noVNC's core is MPL-2.0 (`LICENSE.txt`, `LICENSE.MPL-2.0`, `AUTHORS`); the bundled
  pako (zlib) is MIT (`LICENSE.pako`). The bundle keeps the sources' license comments; the
  unmodified source is the npm package above.

## How it was built

```sh
npm pack @novnc/novnc@1.7.0 && tar xzf novnc-novnc-1.7.0.tgz
# The one change: core/util/browser.js awaits its H.264 check at the top level, which an IIFE
# can't do — the check now fills the flag when it resolves (H.264 is off until then).
sed -i '' 's/^supportsWebCodecsH264Decode = await _checkWebCodecsH264DecodeSupport();$/_checkWebCodecsH264DecodeSupport().then((ok) => { supportsWebCodecsH264Decode = ok; });/' \
  package/core/util/browser.js
cp third_party/novnc/entry.js .   # re-exports RFB, keysymdef, keysym
npx esbuild@0.24.2 entry.js --bundle --format=iife --global-name=NoVNC --target=safari16 \
  --legal-comments=inline --outfile=novnc.js
```
