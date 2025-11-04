## Features
- Automatic switching between power-saver, balanced and performance
- Tray icon for manual control
- Override system via simple cache files
- GPU-aware and thermally adaptive

## How it works
A bash daemon monitors load, temperature and GPU utilization, then sets
the active profile via `powerprofilesctl`. The tray provides manual overrides.
