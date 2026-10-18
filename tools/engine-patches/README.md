# Windows accessibility engine candidate

This candidate is independent of `F:/flutter` and the installed application.
The local installation passed engine tests, real-library navigation,
native accessibility tree checks, and active Narrator smoke verification.
Each newly built bundle must repeat those checks before deployment.

`windows-engine.json` pins the framework source, depot_tools, and upstream patch.
The upstream patch guards a null parent in `CreateRemoveReparentedNodesUpdate`.
`tingyu-accessibility.patch` combines it with the local root initialization and
detached-node filtering fix, including two additional regression tests.
`windows-test-aot-fixtures.patch` repairs test-only mocks and AOT fixture paths
so the Windows accessibility suite can run against a Release engine.

The prepared checkout is `app/build/flutter-engine/checkout`. Its `.gclient`
uses the framework repository at the pinned revision, with Android, Linux,
Fuchsia, and Emscripten dependency downloads disabled. The matching source is
already patched. `app/build/windows-stable-backup` contains the complete local
installation before this candidate work.

The environment script uses the isolated CPython downloaded by depot_tools,
and the pinned dependencies in `python-requirements.txt`. This avoids the
Google Python index bootstrap that fails with this machine's Windows locale.
The `git.bat` shim uses the installed Git for Windows. No global SDK cache is
modified.

The build dependency defaults to SDK 10.0.22621.0. Configure changes only its
SDK selection constant to the installed 10.0.26100.0, recorded in the manifest.
This toolchain difference must be considered when reviewing candidate tests.

Run from the repository root:

```powershell
# On a fresh machine, install CPython 3.11.9 and Visual Studio C++ tools first.
./tools/bootstrap-windows-engine.ps1 -PythonExecutable C:/path/to/python.exe
./tools/build-windows-engine.ps1 -Stage Sync -Jobs 1
./tools/build-windows-engine.ps1 -Stage Configure
./tools/build-windows-engine.ps1 -Stage Compile -Jobs 10
./tools/build-windows-engine.ps1 -Stage Test
./tools/build-windows-engine.ps1 -Stage App
./tools/build-windows-engine.ps1 -Stage Candidate
./tools/windows-smoke-test.ps1 `
  -AppDirectory ./app/build/windows-engine-candidate `
  -OutputDirectory ./app/build/windows-smoke/engine-candidate-library `
  -LibraryTrack -LibraryRow 1 -Cycles 30 -EnableAccessibility
```

Interrupted initial Git downloads may leave dependency repositories without
HEAD. `repair-windows-engine-deps.ps1` finishes only such dependencies at the
revisions pinned in DEPS. Some downloads on this machine require a separately
authorized direct Git fetch after an automated child fetch fails to write Git
objects. Do not treat a failed synchronization as a completed build.

The App stage compiles the application using Flutter's local engine flags.
The candidate stage copies that freshly built bundle and its engine symbols,
and records the DLL hash and source manifest alongside the candidate. It does
not install the candidate. The temporary runner guard has been removed.
`-EnableAccessibility` enables accessibility assertions in the smoke script;
its environment override only affects older guard-enabled application builds.
CI uses the same bootstrap and build stages, with two compiler jobs for the
hosted Windows runner. Visual Studio is discovered with vswhere, supporting
both the local Community edition and the hosted Enterprise edition. The remote
CI job has not been run from this session.

Smoke test results include native tree errors, named MSAA elements,
and recent playback snapshots. This engine defaults to MSAA, with UIA disabled;
UI Automation enumeration is retained as diagnostic context rather than an
assertion that Flutter controls must be available through UIA. Screenshots must confirm that the navigation
actually opened and closed the player. `windows-narrator-smoke-test.ps1` starts
Narrator when needed, records that it remains running before and after the
test, and closes a session it started. This checks active reader integration
and the exposed MSAA tree; it does not audit spoken output or all keyboard
reading flows.
An upstream null check passing unit tests is insufficient if real navigation
still corrupts the accessibility tree or leaves application controls absent.
