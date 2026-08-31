#!/usr/bin/env python3
"""Assert committed Tailscale credential material stays SOPS-encrypted."""
import os
import sys

ENC_PATHS = ("tailscale/operator-oauth.enc.yaml",)


def main() -> int:
    repo_root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    failed = False
    for rel in ENC_PATHS:
        path = os.path.join(repo_root, rel)
        if not os.path.isfile(path):
            print(f"FAIL: {rel} is missing (expected the SOPS-encrypted credential source)")
            failed = True
            continue
        text = open(path).read()
        if "sops:" not in text or "ENC[AES256_GCM" not in text:
            print(f"FAIL: {rel} is not SOPS-encrypted")
            failed = True
        for marker in ("client_id: k1", "tskey-client-"):
            if marker in text:
                print(f"FAIL: {rel} contains plaintext credential material ({marker!r})")
                failed = True
        if not failed:
            print(f"OK: {rel} is SOPS-encrypted")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
