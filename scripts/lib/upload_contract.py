#!/usr/bin/env python3
"""Deterministic JSON contracts for the ReleaseKit upload action."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

TRANSIENT_UPLOAD_ERROR_MARKERS = (
    "NETWORK",
    "TIMEOUT",
    "CONNECTION",
    "SERVER_ERROR",
    "INTERNAL_ERROR",
    "SERVICE_UNAVAILABLE",
    "RATE_LIMIT",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"Unable to parse asc JSON from {path.name}: {error}")
    if not isinstance(value, dict):
        fail(f"Unexpected asc JSON root in {path.name}; expected an object")
    return value


def upload_state(attributes: dict[str, Any]) -> str:
    state = attributes.get("state")
    if isinstance(state, dict):
        state = state.get("state")
    return state if isinstance(state, str) else ""


def upload_error_items(attributes: dict[str, Any]) -> list[dict[str, str]]:
    state = attributes.get("state")
    if not isinstance(state, dict) or not isinstance(state.get("errors"), list):
        return []
    items = []
    for error in state["errors"]:
        if not isinstance(error, dict):
            continue
        code = error.get("code") if isinstance(error.get("code"), str) else ""
        message = error.get("message") if isinstance(error.get("message"), str) else ""
        if code or message:
            items.append({"code": code, "message": message})
    return items


def upload_errors(attributes: dict[str, Any]) -> list[str]:
    return [
        ": ".join(part for part in (item["code"], item["message"]) if part)
        for item in upload_error_items(attributes)
    ]


def upload_error_classification(attributes: dict[str, Any]) -> str:
    errors = upload_error_items(attributes)
    if not errors:
        return "none"
    if all(
        error["code"]
        and any(marker in error["code"].upper() for marker in TRANSIENT_UPLOAD_ERROR_MARKERS)
        for error in errors
    ):
        return "transient"
    return "unrecoverable"


def reconcile(
    builds_path: Path,
    uploads_path: Path,
    marketing_version: str,
    build_number: str,
) -> dict[str, str]:
    builds_json = load_json(builds_path)
    uploads_json = load_json(uploads_path)

    builds = [
        item
        for item in builds_json.get("data", [])
        if isinstance(item, dict)
        and isinstance(item.get("attributes"), dict)
        and item["attributes"].get("version") == build_number
    ]
    if len(builds) > 1:
        fail(
            "App Store Connect returned multiple builds for exact version "
            f"'{marketing_version}' and build '{build_number}'."
        )

    active_uploads = []
    failed_uploads = []
    for item in uploads_json.get("data", []):
        if not isinstance(item, dict) or not isinstance(item.get("attributes"), dict):
            continue
        attributes = item["attributes"]
        if (
            attributes.get("cfBundleShortVersionString") == marketing_version
            and attributes.get("cfBundleVersion") == build_number
            and attributes.get("platform") == "IOS"
        ):
            if upload_state(attributes) == "FAILED":
                failed_uploads.append(item)
            else:
                active_uploads.append(item)
    if len(active_uploads) > 1:
        fail(
            "App Store Connect returned multiple active build uploads for exact version "
            f"'{marketing_version}' and build '{build_number}'."
        )

    build = builds[0] if builds else {}
    build_attributes = build.get("attributes", {})
    upload = active_uploads[0] if active_uploads else {}
    upload_attributes = upload.get("attributes", {})
    failed_upload_ids = [item.get("id", "") for item in failed_uploads]
    failed_errors = [
        detail
        for item in failed_uploads
        for detail in upload_errors(item.get("attributes", {}))
    ]
    failed_classifications = [
        upload_error_classification(item.get("attributes", {}))
        for item in failed_uploads
    ]
    return {
        "build_id": build.get("id", ""),
        "build_state": build_attributes.get("processingState", ""),
        "upload_id": upload.get("id", ""),
        "upload_state": upload_state(upload_attributes),
        "failed_upload_ids": ",".join(identifier for identifier in failed_upload_ids if identifier),
        "failed_upload_errors": "; ".join(failed_errors),
        "failed_upload_classification": (
            "unrecoverable"
            if "unrecoverable" in failed_classifications
            else "transient"
            if "transient" in failed_classifications
            else "none"
        ),
    }


def app_bundle_id(path: Path) -> str:
    value = load_json(path)
    data = value.get("data")
    if isinstance(data, dict):
        attributes = data.get("attributes")
        if isinstance(attributes, dict) and isinstance(attributes.get("bundleId"), str):
            return attributes["bundleId"]
    bundle_id = value.get("bundleId")
    return bundle_id if isinstance(bundle_id, str) else ""


def build_processing_state(path: Path) -> str:
    value = load_json(path)
    data = value.get("data")
    if isinstance(data, dict):
        attributes = data.get("attributes")
        if isinstance(attributes, dict) and isinstance(attributes.get("processingState"), str):
            return attributes["processingState"]
    state = value.get("processingState")
    return state if isinstance(state, str) else ""


def build_upload_state(path: Path) -> str:
    value = load_json(path)
    data = value.get("data")
    if isinstance(data, dict) and isinstance(data.get("attributes"), dict):
        return upload_state(data["attributes"])
    attributes = value.get("attributes")
    return upload_state(attributes) if isinstance(attributes, dict) else ""


def build_upload_errors(path: Path) -> str:
    value = load_json(path)
    data = value.get("data")
    if isinstance(data, dict) and isinstance(data.get("attributes"), dict):
        return "; ".join(upload_errors(data["attributes"]))
    attributes = value.get("attributes")
    return "; ".join(upload_errors(attributes)) if isinstance(attributes, dict) else ""


def build_upload_error_classification(path: Path) -> str:
    value = load_json(path)
    data = value.get("data")
    if isinstance(data, dict) and isinstance(data.get("attributes"), dict):
        return upload_error_classification(data["attributes"])
    attributes = value.get("attributes")
    return upload_error_classification(attributes) if isinstance(attributes, dict) else "none"


def main() -> None:
    if len(sys.argv) < 3:
        fail(
            "Usage: upload_contract.py "
            "<app-bundle-id|build-state|upload-state|upload-errors|"
            "upload-error-classification|reconcile> <path> [...]"
        )

    command = sys.argv[1]
    if command == "app-bundle-id" and len(sys.argv) == 3:
        print(app_bundle_id(Path(sys.argv[2])))
    elif command == "build-state" and len(sys.argv) == 3:
        print(build_processing_state(Path(sys.argv[2])))
    elif command == "upload-state" and len(sys.argv) == 3:
        print(build_upload_state(Path(sys.argv[2])))
    elif command == "upload-errors" and len(sys.argv) == 3:
        print(build_upload_errors(Path(sys.argv[2])))
    elif command == "upload-error-classification" and len(sys.argv) == 3:
        print(build_upload_error_classification(Path(sys.argv[2])))
    elif command == "reconcile" and len(sys.argv) == 6:
        result = reconcile(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5])
        print(json.dumps(result, separators=(",", ":")))
    else:
        fail(f"Invalid arguments for upload contract command: {command}")


if __name__ == "__main__":
    main()
