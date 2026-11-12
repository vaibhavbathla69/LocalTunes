"""Choose an installed, available iPhone rather than hard-code a simulator model."""
import json
import subprocess
import re

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
maximum = tuple(int(v) for v in sdk.split(".")[:2])
def version(runtime):
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return tuple(map(int, match.groups())) if match else (0, 0)
for runtime, devices in sorted(data["devices"].items(), key=lambda pair: version(pair[0]), reverse=True):
    if "iOS" in runtime and (17, 0) <= version(runtime) <= maximum:
        for device in devices:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                print(device["udid"])
                raise SystemExit(0)
raise SystemExit("No available iPhone simulator. Inspect xcrun simctl list runtimes.")
