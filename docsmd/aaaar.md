# Lambda Python Upgrade: Gotchas & Pre-Flight Checklist

### Upgrading any function from Python 3.9 / 3.10 / 3.11 / 3.12 → **3.13** or **3.14**

*Current as of July 2026. A focused companion to the full Lambda Python upgrade guide — this is the "what will bite me and what do I check" list.*

---

## How to use this document

Work top to bottom **before** you flip the runtime, then use the [final checklist](#the-pre-flight-checklist) as a gate. The gotchas are ordered by how often they actually break Lambda deployments.

**One critical framing point:** every Python version you skip stacks its own breaking changes. Going 3.9 → 3.13 crosses **four** releases (3.10, 3.11, 3.12, 3.13), so you inherit *every* removal along the way — not just 3.13's. The single biggest one (`distutils`, removed in 3.12) hits everyone coming from 3.9/3.10/3.11. If you're already on 3.12, you've cleared the worst of it and the jump to 3.13/3.14 is small.

---

## Gotcha #1 — `distutils` is gone (removed in 3.12) — **the #1 breaker**

**Who it hits:** anyone coming from **3.9, 3.10, or 3.11**. (If you're on 3.12 already, you've passed this.)

`distutils` was deleted from the standard library in Python 3.12. If your code — or *any dependency* — does `import distutils`, it fails on 3.12, 3.13, and 3.14.

**Check for it:**
```bash
# Search your code AND your vendored dependencies
grep -rn "distutils" . --include="*.py"
```

**Fix:**
- Replace `distutils` with `setuptools` (`from setuptools import ...`) or the `packaging` library.
- For version parsing (`distutils.version.LooseVersion`), switch to `packaging.version`.
- Upgrade any old dependency that still imports it — usually a newer release has already fixed this.

---

## Gotcha #2 — The "dead batteries": 19 stdlib modules removed in 3.13

**Who it hits:** anyone landing on **3.13 or 3.14**, regardless of starting point.

Python 3.13 deleted 19 long-deprecated standard-library modules (PEP 594). The ones that actually appear in real Lambda code:

| Removed module | What to use instead |
|---|---|
| `cgi`, `cgitb` | Parse forms with `urllib.parse`; handle multipart yourself or via a library |
| `telnetlib` | `subprocess` + a client library, or `telnetlib3` from PyPI |
| `imghdr` | `filetype`, `puremagic`, or `python-magic` from PyPI |
| `pipes` | `subprocess`; use `shlex.quote()` for the old `pipes.quote` |
| `crypt` / `spwd` | `python-pam` or a proper hashing library (`passlib`, `bcrypt`) |
| `sndhdr`, `aifc`, `sunau`, `audioop`, `chunk` | `filetype`/`puremagic`, or the PyPI redistributions |
| `nntplib`, `uu`, `xdrlib`, `mailcap`, `nis`, `msilib`, `ossaudiodev` | Third-party equivalents where needed |

Also removed in 3.13: the **`2to3`** tool and **`lib2to3`** module, `tkinter.tix`, `locale.resetlocale()`, and the `typing.io` / `typing.re` namespaces.

**Check for it:**
```bash
# Look for imports of the removed modules
grep -rEn "import (cgi|cgitb|telnetlib|imghdr|pipes|crypt|spwd|sndhdr|aifc|sunau|audioop|chunk|nntplib|uu|xdrlib|mailcap|nis|lib2to3)" . --include="*.py"
```

**Fix:** replace each with the mapping above. `cgi` and `imghdr` are the ones most likely to surface in web/image-handling Lambdas.

---

## Gotcha #3 — Native/compiled dependencies must be rebuilt for the target

**Who it hits:** everyone using packages with C extensions — `numpy`, `pandas`, `pydantic` (v1 core), `psycopg2`, `Pillow`, `cryptography`, `lxml`, `grpcio`, etc.

Compiled wheels are built for a **specific Python version, OS, and CPU architecture**. A wheel built for Python 3.9 on Amazon Linux 2 (`x86_64`) will **not** load on Python 3.13 on Amazon Linux 2023 — you'll get an `ImportError` or a segfault at cold start, not at deploy time.

**Two things change at once on this jump:**
1. **Python version** (3.9→3.13, etc.) — new ABI.
2. **Operating system** — 3.9/3.10/3.11 run on **Amazon Linux 2**, while **3.12/3.13/3.14 run on Amazon Linux 2023**. Different system libraries (glibc, OpenSSL) underneath.

**Fix:**
- Rebuild your deployment package / Lambda layer **against the target Python version on an Amazon Linux 2023 base**. The cleanest way is building inside the matching AWS base image (e.g., `public.ecr.aws/lambda/python:3.13`).
- Match the **architecture** — if the function is `arm64` (Graviton), install `arm64`/`aarch64` wheels, not `x86_64`.
- Verify with `pip install --platform ... --only-binary=:all:` targeting the right tags, or just build in-container.
- **Test that every import loads**, not merely that the zip deploys.

**Library-readiness shortcut:** check your dependencies against **pyreadiness.org/3.13** (and /3.14) before upgrading. A few niche C-extension packages lagged at 3.13/3.14 launch; the mainstream stack (Django, Flask, FastAPI, NumPy, pandas) is fine now.

---

## Gotcha #4 — The Amazon Linux 2 → 2023 jump brings its own surprises

**Who it hits:** anyone coming from **3.9, 3.10, or 3.11** (AL2-based) to **3.12+** (AL2023-based). Staying within AL2023 (3.12→3.13) avoids this.

Beyond the compiled-wheel issue, the OS change itself can matter if your function:
- **Shells out** to system commands or expects specific system binaries/libraries to be present — AL2023's package set differs.
- Relies on a particular **OpenSSL / TLS** version or certificate behavior — the crypto stack changed.
- Uses a **container image** deployment — the base image changes and the package manager moves to `dnf`/`microdnf` (no `yum` conventions, no `amazon-linux-extras`). You must rebuild the image from the AL2023-based Lambda base image.

**Check for it:** grep your code for `subprocess`, `os.system`, hard-coded paths like `/usr/bin/...`, and any assumptions about installed system packages.

---

## Gotcha #5 — `asyncio` `loop` parameter removed (async functions)

**Who it hits:** async Lambdas coming from **3.9** especially.

The long-deprecated `loop=` parameter was removed from many `asyncio` APIs across 3.10–3.12. Calls like `asyncio.sleep(1, loop=loop)` or passing `loop=` to `asyncio.gather`, `Queue`, `Lock`, etc., now raise `TypeError`.

**Fix:** drop the `loop=` argument entirely; modern `asyncio` infers the running loop. Use `asyncio.run()` as the entry point rather than manually managing loops.

**Check for it:**
```bash
grep -rn "loop=" . --include="*.py"
```

---

## Gotcha #6 — Unicode / JSON output differences

**Who it hits:** any function whose output is byte-compared downstream, or that produces non-ASCII JSON.

Across these versions there are subtle changes in string/Unicode handling and JSON serialization defaults. If a downstream system (a signature check, a diff, a strict parser) depends on **byte-for-byte identical output**, it can break even when the logic is unchanged.

**Fix:** compare serialized output before vs. after on representative inputs. Don't assume identical bytes; assert on parsed structures where possible rather than raw strings.

---

## Gotcha #7 — `__annotations__` / deferred annotations (3.14 specifically)

**Who it hits:** functions targeting **3.14** that introspect type annotations at runtime.

Python 3.14 makes annotations **deferred** (evaluated lazily) by default. Most code is unaffected, but if you **eagerly read or manipulate `__annotations__`** — some serialization, validation, or ORM-style libraries do — behavior can change.

**Fix:** use the new `annotationlib` APIs to read annotations, and upgrade libraries (Pydantic, dataclass helpers, etc.) to versions that understand deferred annotations. This is a reason to prefer **3.13** unless you specifically want 3.14's features and have verified your stack.

---

## Gotcha #8 — The bundled AWS SDK (`boto3`/`botocore`) version changes

**Who it hits:** functions that rely on the runtime's *built-in* `boto3` and depend on a specific SDK behavior.

Each runtime ships a different bundled `boto3`/`botocore` version. Moving runtimes can silently change the SDK version under you, which can alter defaults or surface newer API behavior.

**Fix:** if you depend on a specific SDK version, **bundle your own** `boto3`/`botocore` in the deployment package or a layer rather than relying on the runtime's copy. This also protects you from automatic runtime patch updates.

---

## Gotcha #9 — Infrastructure-as-Code drift

**Who it hits:** anyone whose functions are defined in CloudFormation, SAM, CDK, or Terraform.

If the function is managed by IaC and you change the runtime in the **Console or CLI**, your next deploy **overwrites it** back to whatever the template says.

**Fix:** change the runtime in the **template**, not by hand:
- **SAM/CloudFormation:** `Runtime: python3.13`
- **CDK (Python):** `runtime=_lambda.Runtime.PYTHON_3_13`
- **Terraform:** `runtime = "python3.13"`

---

## Gotcha #10 — Rollback becomes impossible after the block date

**Who it hits:** anyone upgrading *away* from an already-deprecated runtime (e.g., leaving 3.9).

You can only revert to an old runtime while it still accepts updates. After a deprecated runtime hits its **"block update"** date, you **cannot go back**.

- **Python 3.9** is deprecated; block-create and block-update land **Aug 31, 2026** and **Sep 30, 2026**.
- **3.10** (deprecates Oct 31, 2026) and **3.11** (Jun 30, 2027) run on Amazon Linux 2 and are on their own clocks.

**Fix:** use **versions and aliases** so rollback is an instant alias re-point — and complete the upgrade (and keep your rollback window open) *before* the block-update date.

---

## Which target: 3.13 or 3.14?

| | **Python 3.13** | **Python 3.14** |
|---|---|---|
| Lambda support until | Jun 30, 2029 | Jun 30, 2029 |
| Stability / ecosystem | Near-universal; mature | Good and improving; a few niche C-extensions may lag |
| Annotation behavior | Standard | **Deferred by default** (see Gotcha #7) |
| Recommendation | **Safe default for most** | Choose for latest features *after* verifying your stack on pyreadiness.org/3.14 |

Both are Amazon Linux 2023-based and both get two years of full support plus three of security fixes. **Default to 3.13** unless you have a specific reason for 3.14.

---

## Quick reference: what each starting point inherits

| Starting from | Must handle |
|---|---|
| **3.9** | `distutils` (#1), dead batteries (#2), native rebuilds + AL2→AL2023 (#3, #4), `asyncio loop=` (#5), Unicode/JSON (#6), SDK (#8) — **everything** |
| **3.10** | `distutils` (#1), dead batteries (#2), native rebuilds + AL2→AL2023 (#3, #4), Unicode/JSON (#6), SDK (#8) |
| **3.11** | `distutils` (#1), dead batteries (#2), native rebuilds + AL2→AL2023 (#3, #4), SDK (#8) |
| **3.12** | dead batteries (#2), native rebuilds for new Python ABI (#3, *same OS*), SDK (#8) — **lightest jump** |

*(Plus #7 if targeting 3.14, and #9/#10 always.)*

---

## The Pre-Flight Checklist

Copy this and tick each box before switching the runtime in production.

**Code audit**
- [ ] Searched code **and dependencies** for `import distutils` → replaced (if from 3.9/3.10/3.11)
- [ ] Searched for removed stdlib modules (`cgi`, `imghdr`, `telnetlib`, `pipes`, `crypt`, etc.) → replaced
- [ ] Searched async code for `loop=` arguments → removed (if applicable)
- [ ] Checked for `__annotations__` eager introspection → adapted (if targeting 3.14)
- [ ] Reviewed "What's New in Python 3.10 / 3.11 / 3.12 / 3.13 (/3.14)" *Removed* sections for every version being skipped

**Dependencies**
- [ ] All dependencies confirmed compatible via **pyreadiness.org/3.13** (or /3.14)
- [ ] Native/compiled packages **rebuilt** against target Python version
- [ ] Rebuilt on an **Amazon Linux 2023** base (if coming from 3.9/3.10/3.11)
- [ ] Architecture matches the function (`x86_64` vs `arm64`)
- [ ] Bundled own `boto3`/`botocore` if depending on a specific SDK version

**Deployment mechanics**
- [ ] Runtime changed in **IaC template**, not Console/CLI (if IaC-managed)
- [ ] **Versions + aliases** set up for gradual traffic shift and instant rollback
- [ ] Rollback window confirmed open (before old runtime's block-update date)

**Testing**
- [ ] Every import verified to **load** on the new runtime (not just successful deploy)
- [ ] Full test suite passed against the upgraded function in **non-prod** first
- [ ] Serialized output **byte-compared** before vs. after (if downstream is strict)
- [ ] Cold-start and duration/error metrics watched during phased rollout

**Cleanup**
- [ ] Old function versions retired only **after** the new one is proven in production

---

*End of checklist. For the full step-by-step upgrade procedure and the options comparison (Console vs CLI vs IaC vs AWS Transform custom), see the main Lambda Python upgrade guide.*
