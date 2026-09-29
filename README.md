# Modem handling package (ModemManager based)

Keeps a GSM modem connected on Raspberry Pi CM4/CM4S/CM5 running Raspberry Pi OS
Bookworm or Trixie: connects automatically at boot using a configured APN,
reconnects on link loss, and recovers a wedged modem by escalating from a pulse
on its reset line to a full power cycle.

The heavy lifting is done by ModemManager and NetworkManager. The custom code
is two short shell scripts: `modem-guard`, which decides when an intervention
is needed, and `modem-gpio`, which drives the modem control lines.

## Design principle: one concern, one owner

| Concern | Owner |
|---|---|
| Connecting and reconnecting the data link | NetworkManager (`autoconnect`) |
| Modem state, registration, signal, PIN | ModemManager |
| Supervising the daemons themselves | systemd |
| Deciding on a soft/hard reset | `modem-guard` |

`modem-guard` is the *only* thing that decides about interventions, and it
never brings connections up itself - after a reset NetworkManager reconnects on
its own. Running a second, independent recovery mechanism alongside it is what
produces reset loops that fight NetworkManager's own retry logic.

How that plays out at boot:

```
BOOT
 │
 ├─► modem-gpio-init.service ──► loads and instantiates an I2C GPIO
 │   (Before=modem-power)       expander, if the board has one
 │
 ├─► modem-power.service ──► modem-gpio poweron
 │   (Before=ModemManager)   powers the modem; the GPIO output state
 │                           survives the process exit, so no daemon
 │                                        ↓
 ├─► ModemManager  ◄──────── modem enumerates on USB
 │   owns: AT/QMI/MBIM, SIM PIN, registration, signal
 │                                        ↓
 ├─► NetworkManager ◄─────── modem.nmconnection  (APN / PIN / credentials)
 │   owns: bringing the link up and reconnecting (autoconnect)
 │                                        ↓
 │                            data link up (ppp0, or wwanN on QMI/MBIM)
 │
 └─► modem-guard.timer ──every 10 s──► modem-guard.service
                                       owns: reset decisions, nothing else
                                       reads: /etc/modem.conf
```

## Contents

```
bin/modem-guard                     decision logic - when to intervene
bin/modem-gpio                      drives the control lines, both backends
etc/modem.conf                      GPIO backend and lines, ping, timings
etc/modem.nmconnection.example      APN/PIN - NetworkManager keyfile
systemd/modem-gpio-init.service     prepares the GPIO backend at boot
systemd/modem-power.service         power on via GPIO, before ModemManager
systemd/modem-soft-reset.service    pulse the modem's reset line
systemd/modem-hard-reset.service    cut and restore modem power
systemd/modem-guard.{service,timer} runs the decision logic every 10 s
```

## Requirements

- Raspberry Pi CM4 / CM4S / CM5, Raspberry Pi OS Bookworm or Trixie (arm64)
- A modem supported by ModemManager (verify with `mmcli -L`)
- Two GPIO lines to the modem, one for reset and one for power. They may sit
  on the CPU or on an I2C expander - both are supported, see
  `MODEM_GPIO_BACKEND` below.
- For the expander backend, which is the default: I2C enabled in
  `/boot/firmware/config.txt`. It is off on a stock image - see below.

Packages installed by the installer: `modemmanager`, `network-manager`,
`libqmi-utils`, `libmbim-utils`, `raspi-utils`, and `gpiod` for the expander
backend.

## Installation

### Before installing: enable I2C

Only needed for the `expander` backend, which is the default. I2C is **off**
on a stock Raspberry Pi OS, and without it the expander cannot be reached.

Add to `/boot/firmware/config.txt`:

```
dtparam=i2c_arm=on    # I2C on the ARM GPIO header
dtparam=i2c0=on
```

Then reboot - this is firmware configuration and does not take effect until
the next boot. `sudo raspi-config` → Interface Options → I2C does the same
thing through a menu.

Check afterwards that the bus is there and the chip answers:

```sh
sudo apt install i2c-tools
i2cdetect -l            # which buses exist
i2cdetect -y 10         # the expander should show at its address
```

Note the bus number and address you see - they go into `MODEM_I2C_BUS` and
`MODEM_I2C_ADDR` if they differ from the defaults.

### From the .deb (preferred)

Download the package from the [releases page](../../releases) and install it:

```sh
sudo apt update
sudo apt install ./modem-guard_<version>_all.deb
```

**The `./` is required.** Without it apt reads the argument as a package name
to look up in the repositories and reports that no such package exists. An
absolute path works just as well.

Use `apt`, not `dpkg -i`. `dpkg` only unpacks and configures the file it is
given: it knows nothing about repositories and downloads nothing, so it stops
with unmet dependencies. If that has already happened, `sudo apt -f install`
pulls in what is missing and finishes the job.

`apt` also registers the config files as conffiles - your edits survive
upgrades, and dpkg asks before replacing a file you changed - and enables the
units. It does **not** start them; see the note printed on install, and the
configuration section below.

The package is `Architecture: all`, so the same file works on arm64 and armhf.

### From the source tree

```sh
sudo ./install.sh install
```

Equivalent, for when a `.deb` is inconvenient. The installer never overwrites
existing configuration, so it is safe to re-run.

### Building the .deb yourself

```sh
./packaging/build-deb.sh <version> dist
```

No compilation is involved, so this works on any machine with `dpkg-deb` - it
does not need to run on a Raspberry Pi. Pushing a version tag
(`git tag v<version> && git push origin v<version>`) makes CI build the same
package and attach it to a GitHub release.

## Configuration

Two files, both edited directly.

### 1. `/etc/modem.conf` - hardware and connectivity check

```ini
MODEM_GPIO_BACKEND=expander
MODEM_I2C_BUS=10
MODEM_I2C_ADDR=0x21
MODEM_I2C_CHIP=mcp23008
MODEM_GPIO_WAIT=30
MODEM_RESET_GPIO=
MODEM_RESET_ACTIVE=high
MODEM_RESET_PULSE=1
MODEM_POWER_GPIO=
MODEM_POWER_ACTIVE=high
MODEM_POWER_OFF_TIME=1
MODEM_PING_TARGET=8.8.8.8
MODEM_PING_TARGET_2=1.1.1.1
MODEM_IFACE=
MODEM_PING_INTERVAL=60
MODEM_SETTLE_SOFT=30
MODEM_SETTLE_HARD=60
MODEM_HEARTBEAT=600
MODEM_DEBUG=NO
```

**Where the lines live** is set by `MODEM_GPIO_BACKEND`:

| Backend | Lines are | Driven with | Extra setup |
|---|---|---|---|
| `expander` (default) | offsets on an I2C chip (0-7 on an MCP23008) | `libgpiod` | chip instantiated at boot |
| `soc` | CPU GPIOs, BCM numbers | `pinctrl` | none |

`expander` is the default because that is how most of the boards are built.
`modem-gpio-init.service` loads `gpio-mcp23s08` and instantiates the chip at
`MODEM_I2C_ADDR` on `MODEM_I2C_BUS`; the resulting gpiochip number is looked
up rather than assumed, because it depends on what else is registered. This
needs the `gpiod` package, which the package recommends.

At boot that unit starts before the I2C bus is registered, so it waits up to
`MODEM_GPIO_WAIT` seconds for the bus, and again for the driver to register
the gpiochip. The wait matters: systemd does not retry a `oneshot`, so giving
up on the first look would leave the unit failed for good and the modem
unpowered until someone started it by hand.

**A board without an expander must set `MODEM_GPIO_BACKEND=soc` explicitly.**
Left on the default it fails at boot with a message about a missing I2C bus,
rather than driving anything it should not - but it does fail, and that is
deliberate: silently guessing which kind of board this is would be worse.

**The two GPIO lines** come from your board documentation.

With the `expander` backend they can be left empty: those boards always wire
reset to offset 6 and power to offset 7, so the defaults apply. Set them
explicitly only if your board departs from that.

With the `soc` backend they ship empty on purpose and the units refuse to run
until you fill them in. There is no convention to fall back on there - the
pins differ from board to board, and a wrong one drives an arbitrary line.

- `MODEM_RESET_GPIO` - the modem's reset input, used by the soft rung.
- `MODEM_POWER_GPIO` - the line controlling modem power, used by the hard rung
  and to power the modem at boot.

With the `soc` backend, SoC lines in BANK0 (0-27), BANK1 (28-45) and
BANK2 (46-53) are supported.

**`MODEM_RESET_PULSE`:** check the modem datasheet. The required assert time
differs between models, and if your board wires PWRKEY rather than RESET_N,
too long a pulse powers the modem off instead of resetting it.

**Polarity:** `MODEM_RESET_ACTIVE` is the level that asserts reset, and
`MODEM_POWER_ACTIVE` the level at which the modem is powered. Check both
against your schematic - the two lines need not share a polarity, and on the
board this was first deployed against they do not behave alike.

Getting the reset line backwards is the worst case: every reset then finishes
with the line still asserted, the modem stays down, and no amount of power
cycling helps until the line is corrected. Should that happen,
`modem-gpio poweron` recovers it - it releases the reset line before applying
power, for exactly this reason.

**`MODEM_IFACE`:** leave empty to detect the modem's IP interface from
NetworkManager - `ppp0` for PPP bearers, `wwanN` for QMI/MBIM. Set it
explicitly if detection picks the wrong one. Note that NetworkManager names a
GSM *device* after its control port (`ttyUSB2`), which is not an interface;
detection resolves that to the actual IP interface.

### 2. `/etc/NetworkManager/system-connections/modem.nmconnection` - connection

APN, PIN and credentials.

**`apn` has to be set.** Left empty, NetworkManager dials with an empty APN
and the operator rejects the connection - the modem registers on the network
but no data link ever comes up.

**The file must be `root:root` with mode `0600`** - NetworkManager silently
ignores keyfiles with any other permissions.

After editing:

```sh
nmcli connection reload
```

## How recovery works

`modem-guard` runs every 10 s and asks two questions:

1. What does ModemManager say the modem's state is?
2. If it claims to be `connected`, do packets actually get through?

The second question matters because a modem can sit in state `connected` while
nothing passes - a hung bearer. The check is an ICMP ping **bound to the
modem's own interface**, so a working Ethernet uplink cannot mask a dead modem.

When the answer is unhealthy, recovery proceeds in **rounds**. One round is both
repair actions performed one after another, each followed by enough time for the
modem to come back and for NetworkManager to reconnect:

```
  soft reset - pulse the modem's reset line (power stays on)
      -> up to MODEM_SETTLE_SOFT for NetworkManager to reconnect
  still down? hard reset - cut modem power and restore it
      -> up to MODEM_SETTLE_HARD for NetworkManager to reconnect
  still down? round failed -> pause, then start the next round
```

Both rungs drive a GPIO line; they differ in severity. The soft rung uses the
modem's own reset input, so the modem reboots without losing power. The hard
rung removes power entirely.

A software reset through ModemManager (`mmcli --reset`) is deliberately not
used: it is unsupported by a good number of modems - it fails outright on the
ZTE this was first deployed against - whereas the reset line is a property of
the hardware and always works.

The settle windows are **upper bounds, not fixed delays**. Health is evaluated
on every tick before any window is considered, so a modem that recovers 15 s
into a 60 s window is picked up right then - it never sits out the remainder.

### The decision on every tick

Each tick is a complete pass through the same logic. Nothing is carried in
memory between ticks; the only thing that persists is a timestamp in the state
file.

```
    ┌───────────── every 10 s, always entered from the top ──────────┐
    │                                                                │
    ▼                                                                │
  modem state from ModemManager  +  ping bound to the modem's iface  │
    │                                                                │
    ├─ locked ────────────► do nothing (a reset cannot supply a PIN) ─┤
    │                                                                │
    ├─ connected + ping reply ─► HEALTHY → clear state ──────────────┤
    │                                                                │
    ├─ window of the last action still open ─► wait, silently ───────┤
    │                                                                │
    ├─ round 0 and state transitional ─► leave alone (normal start) ─┤
    │                                                                │
    └─ unhealthy AND window expired                                  │
            │                                                        │
            ├─ phase 0 ─► SOFT reset ─► window SETTLE_SOFT, phase:=1 ┤
            ├─ phase 1 ─► HARD reset ─► window SETTLE_HARD, phase:=2 ┤
            └─ phase 2 ─► pause 1/5/15 min,               phase:=0 ──┘
```

Every branch ends the run and re-enters at the top on the next tick, so the
health check is the **only** way in. A soft reset can therefore never be
followed by a hard reset without checks in between: with a 30 s window and a
10 s tick, the modem is examined at least twice before the next rung is used.

The pause applies **between rounds**, not between the two actions inside one:

| After round | Pause before the next round |
|---|---|
| 1 | 1 min |
| 2 | 5 min |
| 3 and later | 15 min |

Rounds repeat indefinitely until connectivity returns, at which point the
recovery state is cleared and the next fault starts again from round 1.

### A full recovery, with the defaults

```
t=0     fault detected    ROUND 1 ──► soft reset          window 30 s
t=30    still down                ──► hard reset          window 60 s
t=90    still down                ──► round 1 failed      pause  60 s
t=150   retry             ROUND 2 ──► soft reset          window 30 s
t=180   still down                ──► hard reset          window 60 s
t=240   still down                ──► round 2 failed      pause 300 s
t=540   retry             ROUND 3 ──► soft ... hard ...   pause 900 s
...     from here on, rounds keep repeating with a 15 min pause

at any tick in between, if the link comes back:
        ──► recovery state cleared, back to round 0
```

The ticks between the actions are where the checking happens. Between t=0 and
t=30 the modem is examined at t=10 and t=20, logging `waiting: 20s left` and
`waiting: 10s left`. Had it recovered at t=20, the hard reset would never have
run.

Two safeguards are built in:

- **Startup is not a fault.** Before any intervention, transitional states
  (`connecting`, `searching`, `registering`, `enabling`, `initializing`) are
  left alone - that is a modem doing its job. Once a round is underway, the
  settle windows serve as the grace period instead, so a modem that is briefly
  absent because *we* just reset it is never mistaken for a failed repair.
- **`locked` never triggers a reset.** A reset cannot supply a SIM PIN, and
  looping resets would burn PIN attempts and lock the card to PUK. A locked SIM
  stays locked and visible in the status output instead.

### State

Everything the script remembers lives in one line in `/run/modem-guard.state`:

```
1 1 1790064030 absent 1790064000
│ │ │          │      └─ last_probe  - when the link was last pinged
│ │ │          └──────── last_state  - so only changes get logged
│ │ └─────────────────── not_before  - absolute timestamp when the current
│ │                                    window expires
│ └───────────────────── phase       - 0: soft next, 1: hard next,
│                                      2: round exhausted
└─────────────────────── round       - 0 means no recovery in progress
```

Note that `not_before` is an **absolute timestamp, not a duration**. The script
never sleeps and holds no counter: at each tick it simply compares it against
the current time, and `not_before - now` is what the logs report as "left". A
consequence worth knowing is that the service can be killed or restarted at any
moment - after resuming it reads the file and carries on exactly where it was.

Being on tmpfs, the file deliberately disappears on reboot, so a restarted
device always starts from a clean slate.

## Diagnostics

### Are the services running?

```sh
systemctl is-enabled modem-gpio-init.service modem-power.service modem-guard.timer
systemctl is-active  modem-gpio-init.service modem-power.service modem-guard.timer
```

A healthy system answers like this:

| Unit | enabled | active |
|---|---|---|
| `modem-gpio-init.service` | `enabled` | `active` |
| `modem-power.service` | `enabled` | `active` |
| `modem-guard.timer` | `enabled` | `active` |
| `modem-guard.service` | `static` | `inactive` |
| `modem-soft-reset.service`, `modem-hard-reset.service` | `static` | `inactive` |

Three answers look like faults and are not:

- **`inactive` for `modem-guard.service`** is correct. It is a `oneshot`: the
  timer starts it, it runs for a fraction of a second and exits. Between ticks
  there is nothing to be active.
- **`static`** is not "disabled". Those units have no `[Install]` section on
  purpose, so they cannot be enabled or disabled - the timer starts the guard,
  and the guard starts the reset units. Only the timer and the two boot-time
  units are enabled.
- **`active` for `modem-power.service` and `modem-gpio-init.service`** does not
  mean a process is running. They are `oneshot` with `RemainAfterExit`, so
  `active` records that the work succeeded - the line was driven, the expander
  was prepared.

What an actual fault looks like: `modem-gpio-init.service` in `failed`, and
`modem-power.service` `inactive` as a consequence, because it requires it. The
reason is in its log:

```sh
systemctl status modem-gpio-init.service --no-pager -l
journalctl -u modem-gpio-init.service -b --no-pager
```

When the timer fires next, and when it last did:

```sh
systemctl list-timers modem-guard.timer --no-pager
```

### Logs

Start here - everything this package does, in one stream:

```sh
journalctl -f -u 'modem-*'
```

The individual units, when you want to narrow it down:

```sh
# decisions, state changes and the heartbeat - this is the one to read
journalctl -u modem-guard.service -n 50 --no-pager

# only ever logs when a reset actually ran.
# "No entries" means none was needed, which is the healthy case
journalctl -u modem-soft-reset.service -u modem-hard-reset.service

# whether the GPIO backend came up at boot
journalctl -u modem-gpio-init.service -b --no-pager

# the layer underneath, where connection failures are explained
journalctl -u ModemManager -u NetworkManager
```

Current state without waiting for a tick:

```sh
mmcli -L                       # modems known to ModemManager
mmcli -m <path>                # state, operator, signal, registration
nmcli device status            # connection state and interface
nmcli connection show modem    # active profile
cat /run/modem-guard.state     # round, phase, window, last seen state
systemctl list-timers modem-guard.timer --no-pager
```

### Log levels

Normally only state changes, decisions and a periodic heartbeat are recorded,
so the journal stays readable at a 10 s tick.

The heartbeat exists because a healthy link changes nothing and decides
nothing, so without it the guard would log once and then stay silent forever -
which reads exactly like a supervisor that has died. One line every
`MODEM_HEARTBEAT` seconds says what it sees:

```
heartbeat: state=connected round=0 iface=ppp0 signal=67%
```

Every intervention line carries its reason, so a production log tells you
*why* a reset happened:

```
modem state: failed (round 0, phase 0)
round 1: modem state failed -> starting modem-soft-reset.service, giving it up to 30s
round 1: link hung (state connected, no traffic) -> starting modem-soft-reset.service ...
connectivity restored during round 1 - clearing recovery state
```

For diagnosis, set `MODEM_DEBUG=YES` in `/etc/modem.conf`. Every tick is then
recorded as well - the wake-up itself, the state file contents, how much of the
current window is left and each individual ping result:

```
debug: woke up (tick)
debug: state file: round=1 phase=1 last_state=connected window_left=10s
debug: modem path: none on D-Bus
debug: modem state: absent
debug: waiting: 10s left of the current window (round 1, phase 1)
```

The setting is read on every tick, so it takes effect immediately - no restart
needed.

## Driving the modem by hand

`modem-gpio` is the tool the units call, and it can be run directly. It reads
`/etc/modem.conf`, so by hand it drives the same lines, with the same polarity
and the same timings, as the automatic path.

| Command | What it does |
|---|---|
| `modem-gpio init` | Prepares the backend. With an expander it loads the driver and instantiates the chip; on `soc` it does nothing. Safe to repeat. |
| `modem-gpio reset` | **Soft reset.** Asserts the reset line for `MODEM_RESET_PULSE`, then returns it to rest. Power stays on. |
| `modem-gpio powercycle` | **Hard reset.** Cuts power for `MODEM_POWER_OFF_TIME`, then restores it. |
| `modem-gpio poweron` | Releases the reset line, then applies power. This is what recovers a modem stuck in reset. |
| `modem-gpio set high\|low PIN` | Drives one line directly. For working out which pin does what. |

Anything that fails says why and exits non-zero - an unconfigured pin, an
expander that was never initialised, a `gpioset` that would not take the line.

Stop the automation first, or the guard may intervene halfway through a test:

```sh
systemctl stop modem-guard.timer
```

A reset, watching the modem leave and come back:

```sh
modem-gpio init
modem-gpio reset
for i in $(seq 1 40); do sleep 1; printf "%2ds usb=%s mm=%s\n" "$i" \
  "$(lsusb | grep -c 19d2:)" "$(mmcli -L 2>/dev/null | grep -c Modem/)"; done
```

`usb` should drop to 0 and return to 1, then `mm` follows once ModemManager
has probed it. The number of seconds until `mm` returns is what the settle
windows have to cover - measure it for both `reset` and `powercycle` and set
`MODEM_SETTLE_SOFT` and `MODEM_SETTLE_HARD` above it, with room to spare.

Afterwards, confirm the reset line went back to rest. This is the check worth
making, because a line left asserted holds the modem down indefinitely:

```sh
gpioget --as-is -c gpiochip2 6 7     # expander backend
pinctrl get 30 31                    # soc backend
```

`--as-is` matters: without it, libgpiod switches the line to an input and
wipes the output you just set.

The same two actions through systemd, which is the path the guard uses:

```sh
systemctl start modem-soft-reset.service
systemctl start modem-hard-reset.service
journalctl -u modem-soft-reset.service -u modem-hard-reset.service -n 10 --no-pager
```

Then put the automation back:

```sh
systemctl start modem-guard.timer
rm -f /run/modem-guard.state      # start from a clean slate
```

## Tuning

- **Settle windows** (`MODEM_SETTLE_SOFT`, `MODEM_SETTLE_HARD`) in
  `/etc/modem.conf` are the values to calibrate first: they must cover reset
  plus registration plus reconnect on your hardware. Too short, and the hard
  reset fires while the modem is still coming back from the soft reset.
- **Probe interval while healthy** (`MODEM_PING_INTERVAL`) in `/etc/modem.conf`.
  Ignored during a recovery round, where every tick probes.
- **Tick** (10 s) is `OnUnitActiveSec=` in `modem-guard.timer`. It sets the
  *resolution* of every interval above: a 20 s settle window can only be
  honoured if the check runs at least that often. Keep the tick well below the
  shortest interval you configure. Ticks with nothing to do cost nothing - the
  script exits immediately and logs nothing.
- **Pause between rounds** (1/5/15 min) and the **transitional state list** are
  in `backoff_for()` and `is_transitional()` in `/usr/sbin/modem-guard`.

Only state changes and decisions are logged, so the journal stays readable
despite the fast tick.

## To verify on real hardware

- ModemManager coverage for GM500 and RG255C could not be confirmed from
  upstream documentation - check with `mmcli -L`. Quectel (EC25/EG25),
  SIMCOM (SIM7000/SIM7600), Huawei (ME909/MU709) and Telit have upstream
  plugins, and ZTE ME3630 (19d2:1476) is known to work over PPP.
- That `pinctrl` is present for the `soc` backend, or `gpioset` for the
  `expander` one; the installer warns if `pinctrl` is missing.
- For an expander board: that I2C is enabled, the chip answers at the
  configured address (`i2cdetect -y 10`), and `modem-gpio init` reports a
  gpiochip.
- **The polarity of both lines**, against the schematic. Getting the reset
  line backwards leaves the modem held down after every reset, and that is not
  obvious from the logs - the reset reports success.
- That `MODEM_IFACE` auto-detection picks the modem's real IP interface, and
  that the APN in use does not block ICMP to the configured ping targets.
- Whether the modem needs QMI/MBIM rather than PPP, and that the in-kernel
  `qmi_wwan` / `cdc_mbim` driver binds it.

## License

MIT - see [LICENSE](LICENSE).

This package is built entirely on open-source software and is itself open
source. It is published as **an example of how to put existing components
together**, not as a product: no license fee, no restrictions, no gated
features. Use, modify and redistribute it freely; the only constraints are the
licenses of the third-party components it relies on, which are listed in
`LICENSE` and installed from your distribution's own repositories.

Provided as is, with no warranty and no liability for any use, modification or
consequence of running it.
