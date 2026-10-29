# Guard icons — Lucide outline

Selected on iconfont: https://www.iconfont.cn/collections/detail?cid=54062
Collection name: Lucide. Listed license: ISC. Original project: https://lucide.dev/

All geometry comes from one upstream revision recorded in sources.json, matched to the iconfont icon IDs.
SVGs use a 24×24 grid, round caps and joins, and a 2-unit stroke. The three large header shields use a 1-unit optical stroke so their visible weight matches the smaller icons. These are the only geometry-style modifications.

The PDF files are transparent native vector assets for macOS, converted from the corresponding SVGs. No runtime browser, icon font, or third-party rendering dependency is needed. Original SVG files and the full upstream ISC/Feather MIT license are included.

Reproduction: generate a 24pt-per-page HTML document from these SVGs, print through Chromium, then translate its centered 24pt viewport into a standalone 24×24pt PDF page. The development check asserts page size, a transparent corner and visible icon content for every asset.

The comparison window adds the upstream `arrow-down` and `refresh-cw` assets from the same pinned revision. Menu, refresh, and comparison arrows continue to use this one family.

The risk banner and welcome card (2026-10-29) add `x`, `circle-check`, `loader-circle` and `arrow-up-right` from the same pinned revision. Their PDFs were printed by headless Chromium onto a 24×24pt page (`@page` size), so no cropping step was needed; the iconfont IDs were not looked up and are recorded as null.
