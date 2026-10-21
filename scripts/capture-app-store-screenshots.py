#!/usr/bin/env python3
"""Export native-resolution WatchMate simulator screenshots without personal data."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import time
from PIL import Image


SCREENS = [
    ("up-next", "01-Up-Next"),
    ("coming-soon", "02-Coming-Soon"),
    ("my-shows", "03-My-Shows"),
    ("show", "04-Programme-Details"),
    ("episode", "05-Episode-Details"),
]
DEVICES = {
    "iPhone": "iPhone 18 Pro Max",
    "iPhone-Medium": "iPhone 18 Pro",
    "iPad-13-inch": "iPad Pro 13-inch (M5)",
    "iPhone-Duo": "iPhone Duo",
}
ACCEPTED_SIZES = {
    "iPhone": {(1320, 2868), (2868, 1320)},
    "iPhone-Medium": {(1206, 2622), (2622, 1206)},
    "iPad-13-inch": {(2064, 2752), (2752, 2064)},
    "iPhone-Duo": {(1398, 2034), (2034, 1398), (2007, 2853), (2853, 2007)},
}


def simctl(*args, check=True):
    result = subprocess.run(
        ["xcrun", "simctl", *args], text=True, capture_output=True, timeout=120
    )
    if check and result.returncode:
        raise RuntimeError(f"simctl {' '.join(args)} failed:\n{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path,
                        help="WatchMate.app built with Debug for iOS Simulator")
    parser.add_argument("--output", type=Path, default=Path("AppStoreScreenshots"))
    parser.add_argument("--device", action="append", choices=DEVICES,
                        help="Capture only this device group; repeat for multiple groups")
    parser.add_argument("--settle-seconds", type=float, default=8,
                        help="Wait for launch and navigation animations before capture")
    args = parser.parse_args()
    if not (args.app / "DemoLibrary.json").exists():
        parser.error("Build WatchMate with its bundled demo library first.")
    with (args.app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
        parser.error("--app must be an iOS Simulator build")
    bundle_id = info["CFBundleIdentifier"]
    # Release builds deliberately ignore the launch argument.
    if not any(b"--app-store-screenshots" in file.read_bytes()
               for file in args.app.iterdir()
               if file.is_file() and (file.name == "WatchMate" or file.suffix == ".dylib")):
        parser.error("Screenshot support is missing: build WatchMate in Debug")

    available = json.loads(simctl("list", "devices", "available", "-j").stdout)["devices"]
    manifest = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sampleData": "Real TMDB programmes, artwork and air dates; sample viewing progress; no account required.",
        "captures": [],
    }
    for group in args.device or DEVICES:
        candidates = [(runtime, device) for runtime, devices in available.items()
                      for device in devices if device["name"] == DEVICES[group]]
        if not candidates:
            raise RuntimeError(f"Create the {DEVICES[group]} simulator in Xcode first.")
        runtime, device = max(candidates, key=lambda item: item[0])
        udid = device["udid"]
        print(f"Preparing {device['name']}…", flush=True)
        folder = args.output / group
        folder.mkdir(parents=True, exist_ok=True)
        if device["state"] != "Booted":
            simctl("boot", udid)
        simctl("bootstatus", udid, "-b")
        simctl("install", udid, str(args.app.resolve()))
        simctl("status_bar", udid, "override", "--time", "9:41",
               "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
               "--batteryState", "charged", "--batteryLevel", "100")
        try:
            for screen, name in SCREENS:
                simctl("terminate", udid, bundle_id, check=False)
                simctl("launch", udid, bundle_id, "--app-store-screenshots",
                       f"--screenshot-screen={screen}", "-AppleLanguages", "(en)",
                       "-AppleLocale", "en_GB")
                time.sleep(args.settle_seconds)
                path = folder / f"{name}.png"
                # Simulator's helper cannot write directly to some external/cloud drives.
                with tempfile.TemporaryDirectory(prefix="watchmate-capture-") as temporary:
                    captured = Path(temporary) / "screenshot.png"
                    # Duo also exposes an inactive inner display; select its outer screen.
                    display = ["--display=1"] if group == "iPhone-Duo" else []
                    simctl("io", udid, "screenshot", "--type=png", *display, str(captured))
                    # App Store Connect rejects PNGs with an alpha channel.
                    with Image.open(captured) as screenshot:
                        if max(channel[1] - channel[0] for channel in screenshot.convert("RGB").getextrema()) < 16:
                            raise RuntimeError("Blank capture: unlock the simulator and check its active display.")
                        screenshot.convert("RGB").save(path)
                data = path.read_bytes()
                width, height = struct.unpack(">II", data[16:24])
                if (width, height) not in ACCEPTED_SIZES[group]:
                    raise RuntimeError(f"Unexpected capture size for {group}: {width} × {height}")
                manifest["captures"].append({
                    "file": str(path.relative_to(args.output)), "screen": screen,
                    "device": device["name"], "runtime": runtime,
                    "width": width, "height": height,
                })
                print(f"{path} ({width} × {height})", flush=True)
        finally:
            simctl("status_bar", udid, "clear", check=False)
            simctl("terminate", udid, bundle_id, check=False)
    args.output.mkdir(parents=True, exist_ok=True)
    suffix = "-".join(args.device) if args.device else "all"
    (args.output / f"manifest-{suffix}.json").write_text(
        json.dumps(manifest, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
