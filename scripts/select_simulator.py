"""Read simctl JSON from stdin and choose an available iOS 26 iPhone."""
import json
import sys

devices = json.load(sys.stdin).get("devices", {})
for runtime, entries in sorted(devices.items(), reverse=True):
    if "iOS-26" not in runtime:
        continue
    for device in entries:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone "):
            print(device["udid"])
            sys.exit(0)
sys.exit("No available iOS 26 iPhone simulator found on this runner.")
