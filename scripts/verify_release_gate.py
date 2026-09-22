#!/usr/bin/env python3
"""Fail closed on missing production-regression and live-journey evidence."""
import argparse
import json
import subprocess
from pathlib import Path

REQUIRED_TESTS = {
    "NomvaCoreTests/overlappingActivityRefresh()",
    "NomvaCoreTests/backupReplacement()",
    "NomvaCoreTests/plannerOutage()",
    "NomvaCoreTests/healthActivityCorrections()",
    "NomvaCoreTests/liveActivityTargets()",
    "NomvaCoreTests/healthPartialSyncFailure()",
    "NomvaCoreTests/healthHistoryRecovery()",
    "NomvaCoreTests/backupRetainsHealthSuppression()",
    "NomvaCoreTests/widgetWaterRetry()",
    "NomvaCoreTests/requestRecoveryPolicy()",
    "NomvaReliabilityUITests/testAppleHealthActivityReachesLogAndChatTargets()",
    "NomvaReliabilityUITests/testLiveFoodRequestCanStopThenRetryWithoutDuplicates()",
    "NomvaCoreTests/reportedDinnerPersists()",
    "NomvaCoreTests/bundledCatalogThroughAliasedPath()",
    "NomvaCoreTests/unavailableFoodLookupIsRecoverable()",
    "NomvaCoreTests/foodResolutionFailureKinds()",
    "NomvaCoreTests/wholeBottleCorrectionPersists()",
    "NomvaReliabilityUITests/testReportedDinnerThroughLiveChatAndSavedLog()",
    "NomvaReliabilityUITests/testBottleNutritionSurvivesEditingAndChatCorrection()",
}
REQUIRED_JOURNEYS = {
    "screenshot-dinner", "fraction-and-grams", "ordinary-breakfast",
    "measured-snack", "single-common-food",
}


def xcresult(bundle, command):
    return json.loads(subprocess.check_output([
        "xcrun", "xcresulttool", "get", "test-results", command,
        "--path", str(bundle), "--format", "json",
    ]))


def nodes(tree):
    for node in tree:
        yield node
        yield from nodes(node.get("children", []))


def verify(bundles, journeys):
    passed = set()
    count = 0
    for bundle in bundles:
        summary = xcresult(bundle, "summary")
        if summary.get("result") != "Passed" or summary.get("failedTests", 0) or not summary.get("passedTests", 0):
            raise ValueError(f"Tests did not pass: {bundle}")
        count += summary["passedTests"]
        for node in nodes(xcresult(bundle, "tests").get("testNodes", [])):
            if node.get("nodeType") == "Test Case" and node.get("result") == "Passed":
                passed.add(node.get("nodeIdentifier"))
    missing = REQUIRED_TESTS - passed
    if missing:
        raise ValueError(f"Missing passing production regressions: {sorted(missing)}")
    report = json.loads(journeys.read_text())
    results = report.get("results", [])
    identifiers = [r.get("id") for r in results]
    if set(identifiers) != REQUIRED_JOURNEYS or len(identifiers) != len(REQUIRED_JOURNEYS):
        raise ValueError("The required live food journeys are missing or duplicated")
    for result in results:
        if result.get("passed") is not True or not (0 < result.get("ms", 0) < 20_000):
            raise ValueError(f"Live food journey failed: {result.get('id')}")
    print(f"PASS: {count} iOS tests, all required production regressions, {len(results)} live food journeys")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", type=Path, action="append", required=True)
    parser.add_argument("--journeys", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(args.tests, args.journeys)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"RELEASE BLOCKED: {error}\n")
