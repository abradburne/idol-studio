# Idol Studio

## [⬇ Download for Mac](https://github.com/abradburne/idol-studio/releases/download/v0.3/Idol-Studio-0.3.dmg)

Apple Silicon · macOS 26.2+ · Signed and notarized

Turn a single image into a 3D Gaussian splat on your Mac. Drop or paste a photo or render, generate with IDOL, and inspect the result in an interactive Metal viewer. Everything runs locally.

![Idol Studio showing a robot image and its generated 3D Gaussian splat](docs/idol-studio.png)

## Getting started

Requires **Apple Silicon** and **macOS 26.2 or later**.

1. Open the signed DMG and drag **Idol Studio** into **Applications**.
2. On first launch, download the **3.57 GB** model. You can choose where to store it or select an existing model folder. Manage it later in **Settings (⌘,)**.
3. Drop in an image or paste one with **⌘V**, then click **Generate Splat**. Drag to orbit, Shift-drag to pan, and scroll to zoom.
4. Use **Export** to save a Gaussian splat as **PLY** or **GLB**.

## Build from source

With Xcode installed, run these commands from the project folder.

```sh
./scripts/setup.sh
open ".build/Idol Studio.app"
```

Powered by [IDOL](https://github.com/speridlabs/idol-sdk) and [MLX-Serve](https://github.com/ddalcu/mlx-serve). The robot image is from the [IDOL demo gallery](https://github.com/speridlabs/idol-sdk/blob/main/demo/examples/fig-robot-cute.webp).
