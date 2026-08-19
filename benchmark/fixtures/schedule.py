"""Recurring-schedule helpers for the todo app."""
import datetime


def parse_date(text):
    """Parse an ISO date string into a date object."""
    return datetime.date.fromisoformat(text)


def format_date(value):
    """Render a date as an ISO string."""
    return value.isoformat()


def days_between(start, end):
    """Whole days from start to end; negative if end precedes start."""
    return (end - start).days


def is_weekend(value):
    """True for Saturday and Sunday."""
    return value.weekday() >= 5


def next_weekday(value):
    """The next date that is not a weekend."""
    step = value + datetime.timedelta(days=1)
    while is_weekend(step):
        step = step + datetime.timedelta(days=1)
    return step
