"""Choose an installed, available iPhone rather than hard-code a simulator model."""
import json
import subprocess

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtime, devices in sorted(data["devices"].items(), reverse=True):
    if "iOS" in runtime:
        for device in devices:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                print(device["udid"])
                raise SystemExit(0)
raise SystemExit("No available iPhone simulator. Inspect xcrun simctl list runtimes.")
