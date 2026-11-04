"""Generate a replay CSV that starts with GPS cold-start garbage, then a valid track.

Takes the deterministic straight-line log as template and overwrites the GPS column of the
first GARBAGE_SECONDS with positions scattered across the world (one new position per second,
held for 4 rows of 250 ms), as a GPS that was off for a long time can report before its fix.
The rest of the template stays unchanged (valid track near the default test area).

Usage: python generate_gps_coldstart_garbage.py
Output: Synthetic_Logs/DemoTelemetry_Synthetic_GpsColdstartGarbage_250ms.csv
"""
import random
from pathlib import Path

HERE = Path(__file__).parent
TEMPLATE = HERE / "Synthetic_Logs" / "DemoTelemetry_Synthetic_1min_straightLine_250ms.csv"
OUT = HERE / "Synthetic_Logs" / "DemoTelemetry_Synthetic_GpsColdstartGarbage_250ms.csv"
GARBAGE_SECONDS = 30
ROWS_PER_SECOND = 4


def main() -> None:
    rnd = random.Random(4711)
    lines = TEMPLATE.read_text(encoding="latin-1").splitlines()
    header, rows = lines[0], lines[1:]
    gps_col = header.split(",").index("GPS")

    garbage = [(0.0, 0.0)]
    for _ in range(GARBAGE_SECONDS - 1):
        garbage.append((rnd.uniform(-60.0, 70.0), rnd.uniform(-170.0, 170.0)))

    out = [header]
    for i, row in enumerate(rows):
        cols = row.split(",")
        sec = i // ROWS_PER_SECOND
        if sec < GARBAGE_SECONDS:
            lat, lon = garbage[sec]
            cols[gps_col] = f"{lat:.6f} {lon:.6f}"
        out.append(",".join(cols))
    OUT.write_text("\n".join(out) + "\n", encoding="latin-1")
    print(f"wrote {OUT.name}: {len(rows)} rows, first {GARBAGE_SECONDS} s garbage")


if __name__ == "__main__":
    main()
