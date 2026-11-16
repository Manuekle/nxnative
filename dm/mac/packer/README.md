# NX Packer

NX Packer is a Mac app for building an nxnative game as a Mac app or an unsigned IPA. It shares the Wii Menu styling of [NX Pad](../../joypad/README.md) and runs the [packing script](../../../docs/frontends.md#building-the-nsp-script).

## Install from the DMG

1. Download the DMG from [Releases](https://github.com/Manuekle/nxnative/releases). Open it and drag **NX Packer.app** into **Applications**. The app requires an Apple silicon Mac with macOS 26.6 or later.
2. Download **Source code (zip)** from the same release and unzip it. Set up the [packing prerequisites](../../../README.md#build-from-the-command-line), including Xcode, its Metal toolchain, and Python with the build dependencies.
3. Open **NX Packer**, choose **Build Tools**, and select the unzipped nxnative folder. If you installed the Python dependencies into a virtual environment, select its `bin/python3` there too.

The app is signed ad hoc and comes without Apple notarization. For first-launch prompts, see [Apple's guidance for opening downloaded apps](https://support.apple.com/en-us/102445).

## Build a game

1. Open **NX Packer.app** in Finder.
2. Drop a folder containing one game's packages (`.nsp`, `.xci`, `.nsz`, or `.xcz`) on **Game**, or drop a package to use the folder containing it. Keep the base game, updates and DLC together. You can also select a `.nup` file or a folder of extracted game files.
3. For an encrypted game, drop your local `prod.keys` on its card. The app passes the file path to the local packer. A NUP or an extracted game folder needs no keys.
4. Choose **iPhone & iPad** or **Mac**. Use **Save to** to choose an output path, or leave it at the game folder. For Switch 2 games choose **Mac**.
5. Select **Build Game**. The window shows the current stage and its progress, with details in **Build Log**. **Cancel** asks the packer to stop. Use **Show in Finder** when the build finishes.

iPhone and iPad builds are unsigned. See [Install](../../../README.md#install) for sideloading. The packer keeps reusable build files and its full stage logs under the game's build folder.

## Build NX Packer

Use the [same prerequisites as the packing script](../../../README.md#build-from-the-command-line), including Xcode, its Metal toolchain, and Python with the build dependencies. From this folder:

```sh
xcodegen generate
xcodebuild -project 'NX Packer.xcodeproj' -scheme 'NX Packer' -configuration Debug -derivedDataPath build build
```

Open `build/Build/Products/Debug/NX Packer.app`. A copy under the checkout finds the packing script automatically. If you move the app, select the checkout in **Build Tools**. The same panel lets you choose a different Python executable, such as the `bin/python3` inside the build virtual environment.
