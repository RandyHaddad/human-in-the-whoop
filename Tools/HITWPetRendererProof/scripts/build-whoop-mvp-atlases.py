#!/usr/bin/env python3
"""Build structurally valid WHOOP Sensor B V2 atlases for the demo MVP.

The MVP intentionally reuses the accepted tier idle loop for lifecycle rows that
have not been authored yet. Positive-refill jumping remains animated: an accepted
jump row is used when present, otherwise a small deterministic vertical bounce is
derived from the tier's accepted idle frame. Look cells remain a documented static
idle fallback until the production direction pass is completed.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image


TIERS = ("energetic", "normal", "tired", "exhausted")
ROW_SPECS = (
    ("idle", 6),
    ("running-right", 8),
    ("running-left", 8),
    ("waving", 4),
    ("jumping", 5),
    ("failed", 8),
    ("waiting", 6),
    ("running", 6),
    ("review", 6),
)
LOOK_LABELS = (
    "000",
    "022.5",
    "045",
    "067.5",
    "090",
    "112.5",
    "135",
    "157.5",
    "180",
    "202.5",
    "225",
    "247.5",
    "270",
    "292.5",
    "315",
    "337.5",
)
CHROMA_KEY = "#FF00FF"
CELL_SIZE = (192, 208)


def run(*parts: str) -> None:
    subprocess.run(parts, check=True)


def image_files(directory: Path) -> list[Path]:
    return sorted(
        path
        for path in directory.iterdir()
        if path.suffix.lower() in {".png", ".webp", ".jpg", ".jpeg"}
    )


def accepted_row_frames(run_dir: Path, state: str, count: int) -> list[Path] | None:
    directory = run_dir / "qa" / "rows" / state / "frames" / state
    if not directory.is_dir():
        return None
    files = image_files(directory)
    if len(files) < count:
        return None
    return files[:count]


def copy_frames(sources: list[Path], destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for index, source in enumerate(sources):
        shutil.copyfile(source, destination / f"{index:02d}.png")


def static_idle_frames(idle_frames: list[Path], count: int) -> list[Path]:
    return [idle_frames[index % len(idle_frames)] for index in range(count)]


def derive_bounce(source: Path, destination: Path) -> None:
    with Image.open(source) as opened:
        frame = opened.convert("RGBA")
    if frame.size != CELL_SIZE:
        raise SystemExit(f"bounce source must be {CELL_SIZE[0]}x{CELL_SIZE[1]}: {source}")

    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit(f"bounce source has no visible pixels: {source}")
    amplitude = min(12, max(2, bbox[1] - 2))
    offsets = (0, -(amplitude // 2), -amplitude, -(amplitude // 2), 0)
    destination.mkdir(parents=True, exist_ok=True)
    for index, offset in enumerate(offsets):
        output = Image.new("RGBA", CELL_SIZE, (0, 0, 0, 0))
        output.alpha_composite(frame, (0, offset))
        output.save(destination / f"{index:02d}.png")


def build_tier(project_root: Path, skill_scripts: Path, tier: str) -> dict[str, object]:
    run_dir = project_root / "Assets" / "HITWPets" / "runs" / "whoop-sensor-b" / tier
    mvp_dir = run_dir / "mvp"
    if mvp_dir.exists():
        if mvp_dir.name != "mvp" or "whoop-sensor-b" not in mvp_dir.parts:
            raise SystemExit(f"refusing to replace unsafe MVP directory: {mvp_dir}")
        shutil.rmtree(mvp_dir)

    frames_root = mvp_dir / "frames"
    look_cells = mvp_dir / "look-cells"
    final_dir = run_dir / "final"
    qa_dir = run_dir / "qa"
    frames_root.mkdir(parents=True)
    look_cells.mkdir(parents=True)
    final_dir.mkdir(parents=True, exist_ok=True)
    qa_dir.mkdir(parents=True, exist_ok=True)

    idle_frames = accepted_row_frames(run_dir, "idle", 6)
    if idle_frames is None:
        raise SystemExit(f"{tier} is missing its accepted six-frame idle row")

    row_sources: dict[str, str] = {}
    for state, count in ROW_SPECS:
        accepted = accepted_row_frames(run_dir, state, count)
        destination = frames_root / state
        if accepted is not None:
            copy_frames(accepted, destination)
            row_sources[state] = "accepted-row"
        elif state == "jumping":
            derive_bounce(idle_frames[0], destination)
            row_sources[state] = "derived-refill-bounce"
        else:
            copy_frames(static_idle_frames(idle_frames, count), destination)
            row_sources[state] = "static-idle-fallback"

    for label in LOOK_LABELS:
        shutil.copyfile(idle_frames[0], look_cells / f"{label}.png")

    python = sys.executable
    standard_png = final_dir / "spritesheet.png"
    standard_webp = final_dir / "spritesheet.webp"
    extended_png = final_dir / "spritesheet-extended.png"
    extended_webp = final_dir / "spritesheet-extended.webp"

    run(
        python,
        str(skill_scripts / "inspect_frames.py"),
        "--frames-root",
        str(frames_root),
        "--json-out",
        str(qa_dir / "mvp-review.json"),
        "--require-components",
    )
    run(
        python,
        str(skill_scripts / "compose_atlas.py"),
        "--frames-root",
        str(frames_root),
        "--output",
        str(standard_png),
        "--webp-output",
        str(standard_webp),
    )
    run(
        python,
        str(skill_scripts / "assemble_extended_atlas.py"),
        "--base-atlas",
        str(standard_webp),
        "--look-cells-dir",
        str(look_cells),
        "--neutral-cell",
        str(idle_frames[0]),
        "--chroma-key",
        CHROMA_KEY,
        "--chroma-threshold",
        "96",
        "--output",
        str(extended_png),
        "--webp-output",
        str(extended_webp),
        "--manifest-output",
        str(final_dir / "spritesheet-extended.json"),
    )
    run(
        python,
        str(skill_scripts / "despill_chroma_edges.py"),
        str(extended_png),
        "--output",
        str(extended_png),
        "--webp-output",
        str(extended_webp),
        "--chroma-key",
        CHROMA_KEY,
        "--json-out",
        str(qa_dir / "chroma-despill-extended.json"),
    )
    run(
        python,
        str(skill_scripts / "validate_atlas.py"),
        str(extended_webp),
        "--json-out",
        str(final_dir / "validation-extended.json"),
        "--chroma-key",
        CHROMA_KEY,
        "--require-v2",
    )
    run(
        python,
        str(skill_scripts / "make_contact_sheet.py"),
        str(extended_webp),
        "--output",
        str(qa_dir / "contact-sheet-extended.png"),
    )
    run(
        python,
        str(skill_scripts / "render_animation_previews.py"),
        "--frames-root",
        str(frames_root),
        "--output-dir",
        str(qa_dir / "mvp-previews"),
    )

    report = {
        "schemaVersion": 1,
        "mode": "demo-mvp",
        "identity": "whoop-sensor-b",
        "tier": tier,
        "atlas": str(extended_webp.relative_to(project_root)),
        "rowSources": row_sources,
        "lookDirections": "static-idle-fallback",
        "deferred": [
            "authored lifecycle reactions for rows marked static-idle-fallback",
            "authored 16-pose look-direction sweep",
            "production blind direction QA",
        ],
    }
    report_path = qa_dir / "mvp-build.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[3],
    )
    parser.add_argument(
        "--skill-scripts",
        type=Path,
        default=Path.home() / ".codex" / "skills" / "hatch-pet" / "scripts",
    )
    parser.add_argument(
        "--tiers",
        nargs="+",
        choices=TIERS,
        default=list(TIERS),
        help="WHOOP tiers to rebuild (defaults to all four)",
    )
    args = parser.parse_args()

    project_root = args.project_root.expanduser().resolve()
    skill_scripts = args.skill_scripts.expanduser().resolve()
    if not (skill_scripts / "compose_atlas.py").is_file():
        raise SystemExit(f"hatch-pet scripts not found: {skill_scripts}")

    reports = [build_tier(project_root, skill_scripts, tier) for tier in args.tiers]
    print(json.dumps({"ok": True, "reports": reports}, indent=2))


if __name__ == "__main__":
    main()
