# G16 Tune

Measurement and tuning scripts for the ASUS ROG Zephyrus G16 (2024, GU605) running [G-Helper](https://github.com/seerge/g-helper).

G-Helper controls the laptop. G16 Tune tells you whether the settings you chose are doing anything: it reads what the firmware and G-Helper are actually applying, logs temperatures, fan speeds and clocks while you play, compares runs, and applies a measured profile with a backup and an undo.

Plain Windows PowerShell 5.1. No install, no build, no dependencies beyond the ASUS driver G-Helper already requires. The whole thing is about 800 lines; read it before you run it.

## Why

Every G16 guide says to set custom fan curves and power limits. None of them show you how to check the result. After enough evenings of changing a number, playing for ten minutes and guessing, this is the tooling that replaced the guessing. The findings below came out of it, and a couple of them contradict the usual advice.

## Features

| Command | What it does |
|---|---|
| **Diagnose** | Reports whether the laptop ever really sleeps, what G-Helper is applying versus what is merely saved, startup load, background services, top CPU consumers since boot, and the Windows settings that cost frames. Saved as markdown. |
| **Log** | Samples CPU and GPU temperature, fan rpm, CPU clock and GPU power every 10 seconds to CSV. Run it during a game. |
| **Fan floor** | Writes a 0% curve up to 98°C for one minute and reports the lowest rpm each fan reached. Answers whether "fans off at idle" is possible on your unit. |
| **Stress** | 90 seconds of all-core load plus a cooldown, saved as CSV. |
| **Compare** | Two saved runs side by side: average and peak temperatures, average clock, fan speeds, GPU power. |
| **Profile** | A G-Helper profile with the reason for every value, applied after a backup. The included one is the measured result for the GU605MY. |
| **Screen mode** | Two scheduled tasks: Silent when the screen turns off, your G-Helper plugged-in mode when it turns on. For leaving the laptop on to download updates without it running Turbo all night. |
| **Debloat** | Opt-in, numbered lists: startup entries, Store apps, third-party services, game-drive indexing, Delivery Optimization, Windows suggestions. Everything is logged and `-Undo` reverses it. |

## Quick start

```powershell
git clone https://github.com/jgohil/g16-tune
cd g16-tune
powershell -ExecutionPolicy Bypass -File .\G16Tune.ps1
```

That opens a menu. Every item is also a switch: `-Diagnose`, `-Log -Seconds 600`, `-Compare before.csv after.csv`, and so on; the header of `G16Tune.ps1` lists them all.

Measuring needs no admin. Applying or restoring a profile and installing the screen-mode tasks do, because G-Helper itself runs elevated. Those steps ask for elevation when started from a normal prompt.

Suggested order: **Diagnose**, then **Fan floor**, then ten minutes of a game with **Log** running. Change one thing, log again, **Compare**.

## Example: the screen-off table

Diagnose reads the Kernel-Power events Windows writes when the display comes back on. On a machine set to never sleep, "screen off" looks like this:

```
| Screen on at | Screen was off for | Actually slept? | Time fully awake |
|---|---|---|---|
| 10-27 11:09 | 16.7 h | no | 100% |
| 10-26 17:41 | 0.2 h | no | 100% |
| 10-26 17:25 | 0.3 h | no | 100% |
```

Windows logs these sessions as Modern Standby. The event data shows zero time in a low-power state: launchers, updaters and overlays ran all night in whatever mode was active, which at a desk is usually Turbo. The screen-mode tasks exist because of this table. With them installed, the same overnight session ran in Silent, the updates still downloaded, and the chassis was cool in the morning.

## Findings on a GU605MY (Core Ultra 9 185H, RTX 4090 Laptop)

Measured on one unit. Yours may differ, which is the reason the tool exists.

- **Any non-zero point in a fan curve runs that fan at roughly 2000 rpm.** There is no quiet 10%. A curve has to be a true 0 up to the temperature where the fan should start.
- **The CPU fan does not stop while the CPU is warm**, even with a curve of 0% to 98°C. In Ultimate GPU mode (dGPU always driving the display) the CPU idles at 64 to 75°C, so the floor at the desk is about 2000 rpm. The GPU fan does stop.
- **Less CPU power was faster.** G-Helper applies an 80 W sustained limit on this model. At 80 W under all-core load the chip sits at its 96°C limit and the average clock across all cores reads about 107% of nominal (Windows' "% Processor Performance" counter against the 2000 MHz it reports for this chip, roughly 2.1 GHz). At 65 W it stays off the thermal limit and reads about 137%, roughly 2.7 GHz. Battlefield 6 went from a CPU-bound 67 fps to 80 to 100 fps with the same settings. Fifteen watts less, 28% more clock.
- **The Windows CPU temperature sensor freezes while the display is off.** Readings taken with the screen off are stale. The logger prints a reminder when it starts.
- **Memory Integrity (Core isolation) is widely reported to cost a few percent in games.** It was on by default here. The tool reports it and leaves the decision to you, since it is a security feature.
- **Stopping the Armoury Crate services and letting G-Helper run the laptop caused no problems.** Keep the ASUS touchpad driver. GlideX, the ASUS display utilities, the Intel graphics apps (idle when the dGPU drives the screen) and the NVIDIA app overlay were background load with no benefit for gaming.

## The profile

[profiles/g16-2024-quiet-gaming.json](profiles/g16-2024-quiet-gaming.json) is the result of the above. Each setting has an `explain` entry, and `-ShowProfile` prints them. In short: fans at a true 0 until the CPU passes 70°C and the GPU passes 60°C, a hard ramp above that, a 65 W sustained CPU limit, a 110 W burst limit, and a 75°C GPU temperature target, because in CPU-bound games the GPU has headroom and a cooler GPU takes heat off the shared heatsink.

Verified on one 2024 GU605MY. The 2025 G16 has a different CPU family and GPU; its best power limit will be a different number. The method carries over, the numbers do not.

## How it works

The same way G-Helper does: the ASUS ACPI driver (`\\.\ATKACPI`) and the device ids documented in G-Helper's source. Reading fan speeds and switching the firmware mode works without admin. Fan curves use the same 16-byte format G-Helper stores in its `config.json`, so the profile, the screen-mode script and G-Helper share one source of truth. Temperatures come from the Windows thermal zone and `nvidia-smi`, because the ASUS temperature registers are not exposed on this model.

No code is shared with G-Helper. It does the controlling; this does the measuring.

## Safety

- Nothing changes without a prompt unless you pass `-Force`. That includes undo and restore.
- Every profile apply backs up G-Helper's `config.json` first. `-RestoreLatest` puts the newest backup back; `-RestoreGHelper <file>` picks a specific one.
- Debloat writes an undo log and shows it before reversing anything. Entries that fail to reverse stay in the log for another try. Store apps are the one thing it cannot reinstall; the Microsoft Store can.
- Power limits and fan curves go through G-Helper's own config, so G-Helper stays in charge and re-applies them on every screen-on and at startup.
- The fan floor test restores your curves when it finishes, including on Ctrl-C.
- No drivers, no services of its own, no network access.

## Not covered

- Switching GPU mode (Ultimate/Standard). Do that in G-Helper; it needs a reboot.
- Undervolting. G-Helper's undervolt is AMD-only, and there is no confirmed working path for the Core Ultra 185H.
- BIOS updates and repasting. A PTM7950 repaste is the usual recommendation for this chassis; the 80 W limit is worth re-testing after one.

## Feedback

Results from other ROG models are welcome. The useful things to attach to an issue are the Diagnose report and the fan floor result, both saved under `%LOCALAPPDATA%\G16Tune`.

## License

MIT. It is your laptop; use at your own risk.
