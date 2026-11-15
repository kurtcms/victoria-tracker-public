#!/usr/bin/env python3
"""Check the *built* app includes invocable actions and English and Cantonese Siri phrase archives."""
from pathlib import Path
import json
import sys

app = Path(sys.argv[1])
metadata = app / "Metadata.appintents"
data = json.loads((metadata / "extract.actionsdata").read_bytes())
expected = {"LogEventIntent"}
actual = {item["actionIdentifier"] for item in data["autoShortcuts"]}
assert expected == actual, f"Only the prompted recording shortcut may be registered: {actual}"
for retired in ("Log160MilkIntent", "LogWetDiaperIntent", "LogDirtyDiaperIntent", "LogMixedDiaperIntent"):
    assert data["actions"][retired]["isDiscoverable"] is False, f"Retired action must be hidden: {retired}"
text = next(p for p in data["actions"]["LogEventIntent"]["parameters"] if p["name"] == "text")
assert not text["isOptional"], "Natural-language intent must prompt for its event"
assert "defaultValue" not in text, "Recording descriptions must not have a default"
phrases = [p["key"] for item in data["autoShortcuts"] for p in item["phraseTemplates"]]
assert "Talk to ${applicationName}" in phrases
assert "${applicationName}" in phrases
assert not any("millilitr" in p or "diaper" in p for p in phrases), "Fixed recording phrases must be retired"
assert all("${applicationName}" in phrase for phrase in phrases)
# Xcode may remove diagnostic YAML during an incremental metadata extraction.
# The compiled locale archive is the shipped artifact.
if (metadata / "root.ssu.yaml").exists():
    corpus = (metadata / "root.ssu.yaml").read_text()
    assert "locale: en" in corpus and "training: []" not in corpus, "Missing English phrase training corpus"
for locale in ("en", "zh-HK"):
    archive = app / f"{locale}.lproj/nlu.appintents"
    assert (archive / "nlu.lzfse").is_file() and (archive / "nlu.lzfse").stat().st_size > 0, f"Siri phrase training did not produce the {locale} archive"
print("PASS: one prompted shortcut, required request, no fixed presets, and compiled English/Cantonese Siri phrases")
