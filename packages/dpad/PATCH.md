# Vendored fork of `dpad` 2.0.2

This is a local copy of [`dpad` 2.0.2](https://pub.dev/packages/dpad), vendored as a
path dependency so we can patch a crash in its D-pad focus traversal.

## Why

On Android TV, scrolling a long list/grid recycles off-screen cells. Their
`FocusNode`s stay registered in dpad's region manager for a frame after their
widgets are unmounted. `RegionAwareFocusTraversalPolicy` then read `node.rect`
on those unmounted nodes during navigation, throwing:

```
Cannot get renderObject of inactive element. ... _ElementLifecycle.defunct
```

This aborted the D-pad key handler, so focus got stuck (e.g. pressing **Up**
from the 3rd row did nothing). PostHog tracked 37 real occurrences.

## The patch — `lib/src/core/region_navigation.dart`

1. `RegionNavigationManager.getNodesInRegion` now also filters out nodes whose
   element is unmounted (`context?.mounted == false`).
2. `_getSortedNodesInScope` applies the same `context.mounted` filter.
3. New `RegionAwareFocusTraversalPolicy._safeNodeRect` returns `null` for an
   unmounted/defunct node (and try/catches `.rect`). Both geometric traversals
   (`_findNextNodeInSameRegion`, `_findNextNodeInDirection`) use it and skip any
   node without a valid rect instead of crashing.

## The patch — `lib/src/navigation/dpad_navigator.dart`

dpad created its `RegionAwareFocusTraversalPolicy` with no `requestFocusCallback`,
so it used Flutter's default, which calls `Scrollable.ensureVisible(duration:
Duration.zero)` on every focus move — an instant scroll "jump". When a host
drives its own scrolling (or dpad's smooth `scrollToFocus` runs), the two fight
and you see jump-then-scroll. We now pass `dpadRequestFocusNoAutoScroll`, which
only requests focus; smooth scrolling is left to dpad's `scrollToFocus`.

## Upgrading

If bumping dpad, re-apply these guards (or confirm upstream fixed it) before
replacing this folder.
