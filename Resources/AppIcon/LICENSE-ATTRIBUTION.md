# App icon and logo: license and attribution

## License

The MacSize app icon (`AppIcon.icns`, `AppIcon-1024.png`), the logo (`logo.svg`), and
the generator script (`scripts/make-icon.swift`) are original work, released under the
repository's MIT License (see `LICENSE` at the repository root).

Every shape is drawn programmatically with CoreGraphics from the coordinates in
`scripts/make-icon.swift`. **No path data, SVG, or bitmap from any icon set is included
or copied.** Apple SF Symbols are not used anywhere.

## Inspiration (credited, not copied)

The treemap mark (a large tile beside a column of smaller tiles) follows the same idea as
these permissively licensed open-source glyphs:

| Icon | Project | License | Link |
| --- | --- | --- | --- |
| `chart-treemap` | Tabler Icons, Copyright (c) 2020-2024 Paweł Kuna | MIT | https://tabler.io/icons/icon/chart-treemap |
| `layout-dashboard` | Lucide, Copyright (c) Lucide Contributors | ISC | https://lucide.dev/icons/layout-dashboard |

Both projects permit reuse and modification in commercial and open-source work. Because
MacSize uses only the concept and not their artwork, neither license's notice
requirement is triggered. We credit them anyway as a courtesy.

The tile proportions come from running the squarified treemap algorithm (Bruls, Huizing
& van Wijk, 2000), the same layout MacSize uses, on the weights 40/24/16/12/8.
