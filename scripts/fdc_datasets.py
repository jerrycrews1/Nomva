#!/usr/bin/env python3
"""Find the newest USDA FoodData Central JSON downloads.

USDA publishes dated file names (Foundation and Branded about twice a year),
so a pinned URL silently goes stale and a scheduled rebuild keeps rebuilding
old data. The download page links every release: pick the newest one per
dataset, and fall back to the last known release if the page can't be read.

In GitHub Actions, `python scripts/fdc_datasets.py` also appends
<key>_release, <key>_url and `datasets` to $GITHUB_OUTPUT.
"""

import os
import re
import urllib.request

DOWNLOAD_PAGE = "https://fdc.nal.usda.gov/download-datasets/"
DATASET_BASE_URL = "https://fdc.nal.usda.gov/fdc-datasets/"

# key: (file-name kind, last known release)
DATASETS = {
    "sr_legacy": ("sr_legacy_food", "2018-04"),
    "foundation": ("foundation_food", "2026-04-30"),
    "fndds": ("survey_food", "2024-10-31"),
    "branded": ("branded_food", "2026-04-30"),
}


def dataset_url(key, release):
    kind = DATASETS[key][0]
    return f"{DATASET_BASE_URL}FoodData_Central_{kind}_json_{release}.zip"


def newest_releases(page_html):
    """Return {key: newest release} for every dataset linked on the page."""
    releases = {}
    for key, (kind, _) in DATASETS.items():
        found = re.findall(
            rf"FoodData_Central_{kind}_json_(\d{{4}}-\d{{2}}(?:-\d{{2}})?)\.zip", page_html
        )
        if found:
            releases[key] = max(found)  # ISO dates sort chronologically
    return releases


def fetch_download_page(timeout=30):
    request = urllib.request.Request(DOWNLOAD_PAGE, headers={"User-Agent": "Nomva-food-db-builder"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def resolve_releases(fetch=fetch_download_page):
    """Return ({key: release}, [warnings]), using the last known release as a fallback."""
    warnings = []
    try:
        found = newest_releases(fetch())
    except Exception as error:
        found = {}
        warnings.append(f"Could not read {DOWNLOAD_PAGE} ({error}); using the last known USDA releases.")
    releases = {}
    for key, (_, last_known) in DATASETS.items():
        releases[key] = found.get(key, last_known)
        if found and key not in found:
            warnings.append(f"No {key} download is linked on {DOWNLOAD_PAGE}; using {last_known}.")
    return releases, warnings


def main():
    releases, warnings = resolve_releases()
    prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") else "warning: "
    for warning in warnings:
        print(prefix + warning)

    lines = [f"{key}_release={release}" for key, release in releases.items()]
    lines += [f"{key}_url={dataset_url(key, release)}" for key, release in releases.items()]
    lines.append("datasets=" + ";".join(f"{key}={release}" for key, release in releases.items()))
    print("\n".join(lines))
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
