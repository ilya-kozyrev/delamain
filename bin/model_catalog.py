"""Resolve Codex families from the selected CLI's local model catalog."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re

import hubcore as hc


FAMILIES = ("luna", "terra", "sol", "astra")
_ID = r"gpt-(\d+)(?:\.(\d+))?-(" + "|".join(FAMILIES) + r")"
_MODEL_ID = re.compile(_ID)
_MENTION = re.compile(rf"(?:(?<=codex/)|(?<![\w./-])){_ID}(?![\w/-]|\.[\w])")


def model_version(model):
    hit = _MODEL_ID.fullmatch(model) if isinstance(model, str) else None
    if hit:
        major, minor, family = hit.groups()
        return family, (int(major), int(minor or 0))
    return None, ()


def codex_family(model):
    return model if model in FAMILIES else model_version(model)[0]


def map_model(model, aliases):
    # Family names are reserved and a full family ID is an explicit pin.
    return model if codex_family(model) else aliases.get(model, model)


def mentioned_pins(text):
    return [match.group() for match in _MENTION.finditer(text)]


def recorded_model(meta, reported=None):
    """Display the run's recorded identity without applying today's catalog to past launches."""
    return meta.get("resolved_model") or reported


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser().absolute()


class Catalog:
    def __init__(self):
        # CODEX_BIN may select another executable or a proxy. Its CLI inherits
        # CODEX_HOME, which selects the cache independently of the executable path.
        self.path = codex_home() / "models_cache.json"
        self.newest = {}
        self.error = None
        self.fetched_at = None
        try:
            with self.path.open(encoding="utf-8") as stream:
                data = json.load(stream)
            models = data["models"]
            if not isinstance(models, list):
                raise TypeError("models is not a list")
        except (OSError, ValueError, KeyError, TypeError) as e:
            self.error = f"Codex model catalog {self.path} is missing or unreadable ({type(e).__name__}: {e})"
            return
        self.fetched_at = data.get("fetched_at")
        ranks = {}
        for entry in models:
            if not isinstance(entry, dict) or entry.get("visibility") != "list":
                continue
            slug = entry.get("slug")
            family, version = model_version(slug)
            if family is None:
                continue
            priority = entry.get("priority")
            rank = (-version[0], -version[1], priority if isinstance(priority, (int, float)) else float("inf"))
            if family not in ranks or rank < ranks[family]:
                ranks[family], self.newest[family] = rank, slug

    def resolve(self, model):
        if model not in FAMILIES:
            return model
        if self.error:
            raise hc.UsageError(self.error)
        if model not in self.newest:
            raise hc.UsageError(f"Codex model catalog {self.path} has no listed model for family {model!r}")
        return self.newest[model]

    def pin_warnings(self, models, cwd=None):
        pins = hc.setting_json("AGENT_HUB_MODEL_PINS", [], cwd=cwd)
        if not isinstance(pins, list) or not all(isinstance(pin, str) for pin in pins):
            hc.warn("AGENT_HUB_MODEL_PINS expects a JSON list of model IDs; ignored")
            pins = []
        for model in dict.fromkeys(models):
            family, version = model_version(model)
            newest = self.newest.get(family)
            if model not in pins and newest and model_version(newest)[1] > version:
                yield (f"STALE MODEL {model}: newest {family} is {newest} "
                       f'(use "{family}" or pin deliberately via AGENT_HUB_MODEL_PINS)')

    def age_warning(self):
        try:
            fetched = datetime.fromisoformat(self.fetched_at.replace("Z", "+00:00"))
            if fetched.tzinfo is None:
                raise ValueError
        except (AttributeError, ValueError):
            try:
                fetched = datetime.fromtimestamp(self.path.stat().st_mtime, timezone.utc)
            except OSError:
                return None
        if datetime.now(timezone.utc) - fetched > timedelta(days=7):
            return f"STALE CATALOG {self.path}: older than 7 days; refresh it with the selected Codex CLI"
        return None
