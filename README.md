# RK3568 BSP and V4L2 Camera Project

Target board: EmbedFire LubanCat 2 (RK3568)

This directory is the single workspace for the BSP and Linux camera-driver
project. Start with the two-week BSP plan in `docs/BSP_PLAN.md`. Hardware-only
results must remain marked `PENDING-HARDWARE` until they have been reproduced
on the board.

## Directory layout

- `vendor/`: untouched vendor SDK and reference sources
- `src/`: project-owned programs and scripts
- `configs/`: exported U-Boot, kernel, and Buildroot configurations
- `patches/`: reviewable patches against the vendor baseline
- `logs/`: raw build, serial, boot, and test logs
- `reports/`: measurements, failure analyses, and acceptance reports
- `docs/`: plans, architecture notes, and interview notes
- `artifacts/`: generated images and checksums (do not commit large images)

## Ground rules

1. Establish an unmodified vendor baseline before changing configuration.
2. Prefer TF-card or RAM/TFTP testing before changing eMMC.
3. Keep each change in a focused commit and preserve the exact command and raw log.
4. Separate vendor functionality from project-owned changes.
5. Never claim hardware validation until a corresponding serial/test log exists.
