// Writes Discodrome's app icon as an Icon Composer document:
//
//   swift Tools/MakeIconArt.swift Resources/AppIcon.icon
//
// build.sh compiles it with Xcode's actool into the Assets.car that macOS 26 and later light, darken
// and tint from its layers, and into AppIcon.icns for macOS 15. Icon Composer can open the document
// to try changes; the shapes are kept here so they stay exact.
//
// The disc a player turns: a black record with fine grooves and a sheen, and a warm label, on a
// graphite square. Three layers, top first: the label (glass), the grooves (soft, not glass), the
// record.
import Foundation

let document = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icon")
let assets = document.appending(path: "Assets")
try? FileManager.default.removeItem(at: document)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

/// A 1024 canvas, y downwards; the system masks it to the icon's rounded square.
let centre = 512.0
let discRadius = 395.0
let labelRadius = 139.0
let holeRadius = 25.0

func f(_ value: Double) -> String { String(format: "%.2f", value) }
func svg(_ body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(body)
    </svg>

    """
}
/// A see-through white for strokes: Icon Composer's renderer ignores stroke-opacity, but honours a
/// gradient's stop-opacity.
func veil(_ id: String, _ opacity: Double) -> String {
    """
    <linearGradient id="\(id)" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="1024" y2="1024">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="\(opacity)"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="\(opacity)"/>
    </linearGradient>
    """
}
func write(_ name: String, _ contents: String) throws {
    try contents.write(to: assets.appending(path: name), atomically: true, encoding: .utf8)
}

try write("Record.svg", svg("""
  <defs>
    <radialGradient id="record" gradientUnits="userSpaceOnUse" cx="\(f(centre))" cy="\(f(centre))" r="\(f(discRadius))">
      <stop offset="0" stop-color="#26262B"/>
      <stop offset="1" stop-color="#08080A"/>
    </radialGradient>
  </defs>
  <circle cx="\(f(centre))" cy="\(f(centre))" r="\(f(discRadius))" fill="url(#record)"/>
"""))

// Grooves: thin rings, every other band a little brighter, and two sheens opposite each other.
var rings = ""
var radius = 164.0
var band = 0
while radius < discRadius - 10 {
    rings += "<circle cx=\"\(f(centre))\" cy=\"\(f(centre))\" r=\"\(f(radius))\" stroke=\"url(#\(band % 4 < 2 ? "groove" : "faint"))\"/>\n"
    radius += 8.7
    band += 1
}
var sheens = ""
for (index, start) in [Double.pi * 0.20, Double.pi * 1.20].enumerated() {
    let end = start + .pi * 0.28
    // SVG's y runs down: angles turn clockwise on screen, as Core Graphics' did upside down.
    let a = (x: centre + cos(start) * discRadius, y: centre - sin(start) * discRadius)
    let b = (x: centre + cos(end) * discRadius, y: centre - sin(end) * discRadius)
    sheens += """
      <linearGradient id="sheen\(index)" gradientUnits="userSpaceOnUse" x1="\(f(a.x))" y1="\(f(a.y))" x2="\(f(b.x))" y2="\(f(b.y))">
        <stop offset="0" stop-color="#FFFFFF" stop-opacity="0"/>
        <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.2"/>
        <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
      </linearGradient>
      <path d="M \(f(centre)) \(f(centre)) L \(f(a.x)) \(f(a.y)) A \(f(discRadius)) \(f(discRadius)) 0 0 0 \(f(b.x)) \(f(b.y)) Z" fill="url(#sheen\(index))"/>

    """
}
try write("Grooves.svg", svg("""
  <defs>
  \(veil("groove", 0.06))
  \(veil("faint", 0.03))
  \(veil("rim", 0.16))
  </defs>
  <g fill="none" stroke-width="2.5">
  \(rings)  </g>
  \(sheens)
  <circle cx="\(f(centre))" cy="\(f(centre))" r="\(f(discRadius - 2))" fill="none" stroke="url(#rim)" stroke-width="4"/>
"""))

// The label, with the spindle hole cut out so the record shows through it.
let labelPath = "M \(f(centre - labelRadius)) \(f(centre)) a \(f(labelRadius)) \(f(labelRadius)) 0 1 0 \(f(labelRadius * 2)) 0 a \(f(labelRadius)) \(f(labelRadius)) 0 1 0 \(f(-labelRadius * 2)) 0 Z "
    + "M \(f(centre - holeRadius)) \(f(centre)) a \(f(holeRadius)) \(f(holeRadius)) 0 1 0 \(f(holeRadius * 2)) 0 a \(f(holeRadius)) \(f(holeRadius)) 0 1 0 \(f(-holeRadius * 2)) 0 Z"
try write("Label.svg", svg("""
  <defs>
    <linearGradient id="label" gradientUnits="userSpaceOnUse" x1="\(f(centre - labelRadius))" y1="\(f(centre - labelRadius))" x2="\(f(centre + labelRadius))" y2="\(f(centre + labelRadius))">
      <stop offset="0" stop-color="#FF8F47"/>
      <stop offset="1" stop-color="#ED4054"/>
    </linearGradient>
    \(veil("ring", 0.25))
  </defs>
  <path d="\(labelPath)" fill="url(#label)" fill-rule="evenodd"/>
  <circle cx="\(f(centre))" cy="\(f(centre))" r="\(f(labelRadius - 32))" fill="none" stroke="url(#ring)" stroke-width="2.5"/>
"""))

// Graphite, a shade darker in Dark mode. The label floats in a group of its own, above the record.
let icon = """
{
  "fill-specializations" : [
    {
      "value" : {
        "linear-gradient" : [ "srgb:0.25000,0.26000,0.30000,1.00000", "srgb:0.09000,0.09000,0.11000,1.00000" ],
        "orientation" : { "start" : { "x" : 0.5, "y" : 0 }, "stop" : { "x" : 0.5, "y" : 1 } }
      }
    },
    {
      "appearance" : "dark",
      "value" : {
        "linear-gradient" : [ "srgb:0.15000,0.15500,0.18000,1.00000", "srgb:0.04000,0.04000,0.05000,1.00000" ],
        "orientation" : { "start" : { "x" : 0.5, "y" : 0 }, "stop" : { "x" : 0.5, "y" : 1 } }
      }
    }
  ],
  "groups" : [
    {
      "layers" : [ { "image-name" : "Label.svg", "name" : "Label" } ]
    },
    {
      "layers" : [
        { "image-name" : "Grooves.svg", "name" : "Grooves", "glass" : false },
        { "image-name" : "Record.svg", "name" : "Record" }
      ]
    }
  ],
  "supported-platforms" : { "circles" : [ "watchOS" ], "squares" : "shared" }
}

"""
try icon.write(to: document.appending(path: "icon.json"), atomically: true, encoding: .utf8)
print("wrote \(document.path)")
