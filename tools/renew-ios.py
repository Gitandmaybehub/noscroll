#!/usr/bin/env python3
"""Renew the personal iPhone build in place. Local config contains device details."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone

ROOT = Path.home() / "Library/Application Support/NoScrollRenewal"
UTC = timezone.utc


def run(args, log=None):
    with subprocess.Popen([str(a) for a in args], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, start_new_session=True) as proc:
        try:
            output, _ = proc.communicate(timeout=600)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
            raise RuntimeError("command timed out: " + str(args[0]))
    if log:
        Path(log).write_bytes(output)
    if proc.returncode:
        raise RuntimeError("command failed: " + str(args[0]) + "; see local renewal logs")
    return output


def profile(path):
    return plistlib.loads(run(["/usr/bin/security", "cms", "-D", "-i", path]))


def expiry(value):
    return value["ExpirationDate"].replace(tzinfo=UTC)


def due(deadline, now):
    return deadline - now <= timedelta(hours=72)


def validate(profiles, config, now, previous=None):
    if len(profiles) != 2:
        raise ValueError("app and widget profiles are both required")
    expected = [config["bundle"], config["bundle"] + ".widget"]
    for item, bundle in zip(profiles, expected):
        entitlements = item.get("Entitlements", {})
        if item.get("TeamIdentifier") != [config["team"]]:
            raise ValueError("unexpected signing team")
        if entitlements.get("application-identifier") != config["team"] + "." + bundle:
            raise ValueError("unexpected app identifier")
        if config["udid"] not in item.get("ProvisionedDevices", []):
            raise ValueError("profile does not include this iPhone")
        if previous is not None and (expiry(item) <= previous or expiry(item) < now + timedelta(days=6)):
            raise ValueError("Apple did not issue a fresh profile; installed app kept")
    return min(expiry(p) for p in profiles)


def profiles_in(app):
    return [profile(app / "embedded.mobileprovision"),
            profile(app / "PlugIns/NoScrollWidget.appex/embedded.mobileprovision")]


def device(config, *args):
    return ["/usr/bin/xcrun", "devicectl", "device", *args,
            "--device", config["device"]]


def installed(config):
    target = ROOT / "installed.json"
    run(device(config, "info", "apps", "--bundle-id", config["bundle"],
               "--include-container-paths", "--json-output", target), ROOT / "device.log")
    apps = json.loads(target.read_text())["result"]["apps"]
    if len(apps) != 1 or apps[0].get("bundleIdentifier") != config["bundle"]:
        raise ValueError("NoScroll CG is not installed on this iPhone")
    container = apps[0].get("dataContainerPath")
    if not container:
        raise ValueError("iPhone app data is not accessible yet")
    return container


def save(state):
    target = ROOT / "status.json"
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.replace(target)
    print(json.dumps(state))


def continuity(config, write=False):
    local = ROOT / ("continuity-sent.txt" if write else "continuity-received.txt")
    remote = "Documents/.noscroll-renewal-check.txt"
    if write:
        local.write_text(str(uuid.uuid4()))
    else:
        local.unlink(missing_ok=True)
    run(device(config, "copy", "to" if write else "from",
               "--source", local if write else remote,
               "--destination", remote if write else local,
               "--domain-type", "appDataContainer", "--domain-identifier", config["bundle"]),
        ROOT / "continuity.log")
    return local.read_text()


def check(force):
    config = json.loads((ROOT / "config.json").read_text())
    app = Path(config["last_app"])
    now = datetime.now(UTC)
    deadline = validate(profiles_in(app), config, now)
    state = {"checked_at": now.isoformat(), "expires_at": deadline.isoformat()}
    if not force and not due(deadline, now):
        save(dict(state, state="healthy", action="none"))
        return
    installed(config)
    before = continuity(config, write=True)
    source = ROOT / "source"
    if run(["/usr/bin/git", "-C", source, "rev-parse", "HEAD"]).decode().strip() != config["commit"]:
        raise ValueError("renewal source is not the reviewed commit")
    if run(["/usr/bin/git", "-C", source, "status", "--porcelain"]).strip():
        raise ValueError("renewal source has changed")
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    archive = ROOT / "profile-backups" / stamp
    archive.mkdir(parents=True)
    expected = {config["team"] + "." + config["bundle"],
                config["team"] + "." + config["bundle"] + ".widget"}
    moved = []
    did_install = False
    try:
        for cached in Path(config["profile_cache"]).glob("*.mobileprovision"):
            data = profile(cached)
            if data.get("Entitlements", {}).get("application-identifier") in expected:
                backup = archive / cached.name
                cached.rename(backup)
                moved.append((cached, backup))
        derived = ROOT / "builds" / stamp
        run(["/usr/bin/caffeinate", "-dimsu", "/usr/bin/xcodebuild",
             "-project", source / "ios/NoScroll.xcodeproj", "-scheme", "NoScroll",
             "-configuration", "Debug", "-destination", "generic/platform=iOS",
             "-derivedDataPath", derived, "-allowProvisioningUpdates",
             "DEVELOPMENT_TEAM=" + config["team"], "CC=" + str(ROOT / "clang-discovery"),
             "build"], ROOT / "build.log")
        fresh = derived / "Build/Products/Debug-iphoneos/NoScroll.app"
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", fresh], ROOT / "signature.log")
        new_deadline = validate(profiles_in(fresh), config, now, deadline)
        run(device(config, "install", "app", fresh), ROOT / "install.log")
        did_install = True
        config["last_app"] = str(fresh)
        temp = ROOT / "config.tmp"
        temp.write_text(json.dumps(config, indent=2) + "\n")
        temp.replace(ROOT / "config.json")
        installed(config)
        # iOS can relocate the container during an update; verify its contents.
        if continuity(config) != before:
            raise ValueError("app data continuity marker was not preserved")
        save(dict(state, state="renewed", expires_at=new_deadline.isoformat(), data_continuity="verified"))
    except BaseException:
        for original, backup in moved:
            if not did_install and not original.exists():
                shutil.copy2(backup, original)
        raise


def self_test():
    now = datetime(2026, 1, 1, tzinfo=UTC)
    assert due(now + timedelta(hours=72), now)
    assert not due(now + timedelta(hours=73), now)
    assert due(now - timedelta(hours=1), now)
    config = {"bundle": "test.app", "team": "TEAM", "udid": "device"}
    items = [{"ExpirationDate": now + timedelta(days=7), "TeamIdentifier": ["TEAM"],
              "ProvisionedDevices": ["device"],
              "Entitlements": {"application-identifier": "TEAM." + name}}
             for name in ["test.app", "test.app.widget"]]
    assert validate(items, config, now, now + timedelta(days=3)) == now + timedelta(days=7)
    for mutate in [lambda x: x.pop(), lambda x: x[0].update(TeamIdentifier=["WRONG"]),
                   lambda x: x[1].update(ExpirationDate=now + timedelta(days=3))]:
        import copy
        bad = copy.deepcopy(items)
        mutate(bad)
        try:
            validate(bad, config, now, now + timedelta(days=3))
        except ValueError:
            pass
        else:
            raise AssertionError("invalid renewal accepted")
    print("RENEWAL_SELF_TEST_OK")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        sys.exit(0)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (ROOT / "renewal.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('{"state":"already_running"}')
            sys.exit(0)
        try:
            check(args.force)
        except Exception as error:
            state = {"state": "needs_attention", "checked_at": datetime.now(UTC).isoformat(), "error": str(error)}
            try:
                config = json.loads((ROOT / "config.json").read_text())
                state["expires_at"] = min(expiry(p) for p in profiles_in(Path(config["last_app"]))).isoformat()
            except Exception:
                pass
            save(state)
            sys.exit(1)
