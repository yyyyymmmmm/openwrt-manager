# Zirox-openwrt Icon

The current icon was chosen by the user on 2026-11-21 (brand review, final
selection): a rounded router body with two antennas and three square ports —
the third port in light blue `#7FA8F5` — drawn in `#0052D9` on an opaque
white 1024 by 1024 canvas. The approved master is
`zirox-appicon-1024.png` (SHA-256
`d1c476ea7ec01433de18b934acc70469951215463c67312549838072333286ba`).

`design/brand/` preserves the supplied artwork: `zirox-appicon-1024.png`
(raster master), `zirox-appicon-1024.svg` (full icon, vector) and
`zirox-mark.svg` (the bare mark on transparency).
`scripts/import_brand_icon.ps1 -ArchivePath <zip>` imports the PNG master
from an archive laid out like the delivery (`final-router/…`) and generates
the smaller opaque images; it does not recolor the icon or add gradients,
corner masks or shadows.

- AppIcon: 40, 60, 58, 87, 80, 120, 120, 180 and 1024 pixel images for iPhone notification, Settings, Spotlight, Home Screen and App Store slots.
- BrandIcon: the original 1024 pixel PNG for in-app welcome and About views.
- LaunchIcon: 72, 144 and 216 pixel images, presented at 72 points in the system launch screen.

Apple supplies the App icon's corner mask and system appearance treatments. The archive contains no separate dark or tinted artwork. The same supplied icon is used in both app appearance modes. The approved interface accent remains `#087873` in light mode and `#74C8C0` in dark mode; semantic navigation and action icons use SF Symbols.

## Retired

The previous icon — a white router mark on a solid `#0B4351` background,
supplied as `zhifi-final/zhifi-icon-1024.png` — was retired on 2026-11-21
when the user picked the router-body design above. Its source files
(`design/brand/zirox-icon-1024.png`, `design/brand/zirox-icon.svg`) were
removed from the tree; they remain recoverable from git history.
