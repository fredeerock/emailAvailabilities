# Quick Availability

Quick Availability is a Mac app that helps you quickly send meeting availability. It reads your Apple Calendar and creates clean, copy-ready time options.

## Download

Download the latest release here:

- https://github.com/fredeerock/quick-availability/releases/latest

## What It Does

- Reads your selected Apple Calendar calendars
- Finds open times based on your settings
- Supports two generation modes:
	- Suggested options
	- Free stretches
- Lets you copy the final result in one click

## Requirements

- macOS 13 or newer

## Install

1. Download `Quick Availability.zip` from Releases.
2. Unzip it.
3. Drag `Quick Availability.app` to `Applications` (recommended).
4. Open the app.

## First Launch (Calendar Permission)

When the app opens, macOS should ask for Calendar access.

- Click `Allow` so the app can detect your busy times.

If you do not see the prompt or previously denied it:

1. Open `System Settings`
2. Go to `Privacy & Security`
3. Open `Calendars`
4. Enable `Quick Availability`

## How To Use

1. Set `Start date` and `End date`.
2. Choose your day window (`Day start` / `Day end`).
3. Choose `Output mode`:
	 - `Free stretches` to see larger open blocks
	 - `Suggested options` for specific meeting times
4. Pick calendars in `Calendars Used`.
5. Click `Generate`.
6. Click `Copy` and paste into email/text.

## Output Styles

When using `Suggested options`, you can choose:

- Numbered
- Casual
- Friendly
- Professional
- Formal

## Tips

- Use `Free stretches` when you want broad availability windows.
- Use `Suggested options` when you want ready-to-send choices.
- Increase `Lead time` to avoid offering near-term slots.

## Troubleshooting

If you see `Calendar access denied` in the app:

1. Quit the app.
2. Re-open and allow access when prompted.
3. If needed, manually enable it in `System Settings > Privacy & Security > Calendars`.

## For Developers

If you want to build from source, see `Package.swift` and run:

```bash
swift run AppleAvailabilityApp
```
