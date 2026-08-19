"""Verify add_months month-end clamping plus preservation of existing helpers."""
import datetime
import pathlib
import sys


def main():
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    import schedule

    d = datetime.date
    cases = [
        ((d(2026, 1, 31), 1), d(2026, 2, 28), "month-end clamp into shorter month"),
        ((d(2024, 1, 31), 1), d(2024, 2, 29), "leap-year clamp"),
        ((d(2026, 5, 31), 1), d(2026, 6, 30), "31-day into 30-day month"),
        ((d(2026, 12, 15), 1), d(2027, 1, 15), "year rollover forward"),
        ((d(2026, 3, 31), -1), d(2026, 2, 28), "negative months clamp"),
        ((d(2026, 1, 15), -1), d(2025, 12, 15), "year rollover backward"),
        ((d(2026, 1, 31), 13), d(2027, 2, 28), "multi-year offset with clamp"),
        ((d(2026, 6, 10), 0), d(2026, 6, 10), "zero months is identity"),
    ]
    failures = []
    for (value, months), want, label in cases:
        try:
            got = schedule.add_months(value, months)
        except Exception as exc:
            failures.append(f"{label}: raised {exc!r}")
            continue
        if got != want:
            failures.append(f"{label}: add_months({value}, {months}) = {got}, want {want}")

    # Pre-existing helpers must survive the whole-file rewrite.
    preserved = [
        ("parse_date", ("2026-02-03",), d(2026, 2, 3)),
        ("format_date", (d(2026, 2, 3),), "2026-02-03"),
        ("days_between", (d(2026, 1, 1), d(2026, 1, 31)), 30),
        ("is_weekend", (d(2026, 8, 15),), True),
        ("next_weekday", (d(2026, 8, 14),), d(2026, 8, 17)),
    ]
    for name, args, want in preserved:
        function = getattr(schedule, name, None)
        if function is None:
            failures.append(f"{name}: MISSING after rewrite")
            continue
        try:
            got = function(*args)
        except Exception as exc:
            failures.append(f"{name}: raised {exc!r}")
            continue
        if got != want:
            failures.append(f"{name}{args} = {got!r}, want {want!r}")

    if failures:
        print(f"FAIL ({len(failures)} problem(s))")
        for line in failures:
            print("  " + line)
        return 1
    print("OK (add_months clamping correct, 5 existing helpers intact)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
