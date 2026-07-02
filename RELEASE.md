# Releasing koni_jxl

This monorepo publishes **two** packages to pub.dev:

- `packages/koni_jxl` — the pure-Dart codec (no dependencies)
- `packages/koni_jxl_flutter` — Flutter bindings (depends on `koni_jxl`)

The Flutter package depends on `koni_jxl: ^<version>`, so **always publish
`koni_jxl` first** and let it index before publishing the Flutter package.
(Until the core version is live on pub.dev, `pana` scores the Flutter
package low because the dependency can't resolve — this self-heals once
the core is published.)

## Pre-flight checklist

Run from the repo root. Everything must be green.

```bash
# 1. Analyzer clean, formatted.
dart analyze
dart format --output=none --set-exit-if-changed packages/koni_jxl packages/koni_jxl_flutter

# 2. All test suites pass. (Gates need cjxl/djxl 0.11.x on PATH and the
#    generated corpus; they skip cleanly otherwise, so run where they exist.)
(cd packages/koni_jxl && dart test)
(cd packages/koni_jxl_flutter && flutter test)
(cd packages/koni_jxl_flutter/example && flutter test)

# 3. Scoring — koni_jxl should be 160/160. (Flutter scores low until the
#    matching koni_jxl version is on pub.dev; that's expected pre-publish.)
dart pub global run pana packages/koni_jxl

# 4. Dry-run both packages — expect "Package has 0 warnings".
(cd packages/koni_jxl && dart pub publish --dry-run)
(cd packages/koni_jxl_flutter && flutter pub publish --dry-run)
```

## Cutting a release

1. **Bump versions.** Edit the `version:` field in both
   `packages/koni_jxl/pubspec.yaml` and
   `packages/koni_jxl_flutter/pubspec.yaml`. If the public API of
   `koni_jxl` changed, also bump the `koni_jxl:` dependency constraint in
   the Flutter package's pubspec to `^<new-version>`.

2. **Update changelogs.** Prepend a new `## <version>` section to both
   `packages/koni_jxl/CHANGELOG.md` and
   `packages/koni_jxl_flutter/CHANGELOG.md`. Write for a reader skimming
   pub.dev, not a commit log.

3. **Run the pre-flight checklist** above. Do not proceed on any failure.

4. **Commit and tag.**

   ```bash
   git add -A
   git commit -m "release: <version>"
   git tag -a v<version> -m "koni_jxl <version>"
   git push origin main
   git push origin v<version>
   ```

5. **Publish, core first.**

   ```bash
   (cd packages/koni_jxl && dart pub publish)
   # Wait for it to appear on https://pub.dev/packages/koni_jxl, then:
   (cd packages/koni_jxl_flutter && flutter pub publish)
   ```

## Version policy

Pre-1.0, breaking changes bump the minor (`0.x`) and additive changes
bump the patch (`0.1.x`), following pub's convention. Keep the two
packages on the same version for simplicity, even when only one changed.

## Notes

- Publishing is irreversible; a version number can never be reused or
  unpublished (only retracted). Double-check the dry-run.
- `third_party/`, `manga_samples/` and the generated corpus are
  gitignored and never shipped. `manga_samples/` is copyrighted — never
  commit it.
- Both packages ship a `LICENSE` (MIT) and `NOTICE` (jxlatte
  attribution); keep both in each package directory.
