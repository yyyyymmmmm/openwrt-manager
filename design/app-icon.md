# Zirox-openwrt Icon

The user supplied `zhifi-icon-final.zip`. The approved source is the archive's `zhifi-final/zhifi-icon-1024.png`: an opaque, 1024 by 1024 RGB image with a white router mark on a solid `#0B4351` background. Its SHA-256 is `b25a07f1262b1ce81f2da7c25dec31022a364bce8b8b934b3d4e225227fc61b4`.

`design/brand/zirox-icon-1024.png` and `design/brand/zirox-icon.svg` preserve the supplied artwork. `scripts/import_brand_icon.ps1 -ArchivePath <zip>` imports the original PNG and generates the smaller opaque images; it does not recolor the icon or add gradients, corner masks or shadows.

- AppIcon: 40, 60, 58, 87, 80, 120, 120, 180 and 1024 pixel images for iPhone notification, Settings, Spotlight, Home Screen and App Store slots.
- BrandIcon: the original 1024 pixel PNG for in-app welcome and About views.
- LaunchIcon: 72, 144 and 216 pixel images, presented at 72 points in the system launch screen.

Apple supplies the App icon's corner mask and system appearance treatments. The archive contains no separate dark or tinted artwork. The same supplied icon is used in both app appearance modes. The approved interface accent remains `#087873` in light mode and `#74C8C0` in dark mode; semantic navigation and action icons use SF Symbols.
