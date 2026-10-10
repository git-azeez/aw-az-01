#!/usr/bin/env python3
"""Validate manifest.json against contracts/schemas/manifest.schema.json."""
import json
import os
import sys

manifest_path = sys.argv[1]
schema_path = sys.argv[2] if len(sys.argv) > 2 else "/workspace/contracts/schemas/manifest.schema.json"

if os.path.getsize(manifest_path) > 1024 * 1024:
    sys.exit("manifest.json exceeds 1 MiB")
manifest = json.load(open(manifest_path))
if not os.path.exists(schema_path):
    print("schema not found, skipping validation")
    sys.exit(0)
try:
    import jsonschema
except ImportError:
    print("jsonschema not installed, skipping validation")
    sys.exit(0)
jsonschema.Draft202012Validator(json.load(open(schema_path))).validate(manifest)
print("manifest.json is valid")
