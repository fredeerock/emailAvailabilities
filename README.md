# Quick Availability

Quick Availability is a native macOS app that reads Apple Calendar and generates ready-to-paste availability options.

## What It Does

- Reads busy events from selected Apple calendars
- Suggests open meeting slots in a chosen date range
- Lets you tune slot spread with a 5-step date bias slider
- Supports multiple output line styles (no extra intro/outro text)
- Copies generated availability to clipboard with one click

## Requirements

- macOS 13+
- Xcode Command Line Tools

Install command line tools if needed:

```bash
xcode-select --install
```

## Run From Source

From the project folder:

```bash
swift run AppleAvailabilityApp
```

## Use The Packaged App

The packaged app bundle is:

- `Quick Availability.app`

Open it from Finder.

## First Launch

The app requests Calendar permission on first run.

If permission is denied, re-enable it in:

1. System Settings
2. Privacy & Security
3. Calendars

## Quick Workflow

1. Expand `Settings`
2. Set date/time range and generation options
3. (Optional) Expand `Calendars Used` inside `Settings` and choose calendars
4. Click `Generate`
5. Pick `Output style` if needed
6. Click `Copy`

## Output Styles

Available styles:

- `Numbered`
- `Casual`
- `Friendly`
- `Professional`
- `Formal`

All styles output only the list lines themselves (no greeting or signature text).
