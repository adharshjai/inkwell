# Inkwell 🖋️

A native macOS PDF editor built for the way STEM homework actually works: open the assignment PDF, work the problems on it, and turn in a clean flattened copy. SwiftUI + PDFKit with the macOS 26 Liquid Glass design — no Electron.

<p align="center"><img src="Assets/icon_preview.png" width="128"></p>

## Highlights

- **Typeset math** — type it casually (`omega0 = 1/sqrt(LC)`, `K_a = [H^+][A^-]/[HA]`, `N2 + 3H2 <=> 2NH3`), see the derived LaTeX, and place textbook-quality equations as solid vector ink: stacked fractions, radicals, limits under Σ and lim, vector arrows.
- **Notes mode** — trackpad drawing without clicking: hold **F** and glide to ink, **S** to sketch shapes that snap clean (shaky circle → perfect ellipse), **W** to click-route wires, **E** to erase. Drag on empty space to box-select; move, resize, and delete selections. An infinite landscape canvas (zoom 0.05×–16×) or endless letter paper.
- **Real annotation tools** — pen, highlighter, text, shapes, eraser, native form filling, drag-to-move, undo/redo everywhere.
- **STEM stamps** — 31 vector stamps: circuit symbols (op-amps, MOSFETs, sources), chemistry (benzene, equilibrium arrows), physics (springs, pulleys, axes).
- **Real paper** — insert college-ruled, quad, engineering, Cartesian, semilog (Bode-ready), log-log, and polar pages.
- **Turn It In** — pre-flight checks, a submission filename builder, and flattened export so every grader sees exactly what you see.

## Build

Requires macOS 26+ and Swift 6.2 (Command Line Tools are enough — no Xcode needed).

```sh
./build_app.sh          # builds build/Inkwell.app
swift run Inkwell --selftest   # 45 headless checks, incl. pixel-level render tests
```

## Layout

```
Sources/Inkwell/
  InkwellApp.swift        app entry, menus, delegate
  AppState.swift          observable app state
  Engine/                 math typesetter, casual→LaTeX, shape recognizer,
                          stamps, paper templates, annotation factory, exporter
  Views/                  PDF view + tools, palette, inspector, sheets
```
