// builds a lightsaber in kraken over the script socket, run it with `kraken -S Scenes/Lightsaber.swift`

import Kraken

Scene.new(up: .z)
// watch the hilt get built
let view = scene.camera(focus: [0, 0, 0.06], distance: 0.55, pitch: 10, yaw: 40)
scene.documentation = "a lightsaber with a toothed hilt and a dark or light blade"

scene.build
{
  Xform("saber")
  {
    Scope("Looks")
    {
      Surface("Aluminum", .metal([0.40, 0.41, 0.42], roughness: 0.62))
      Surface("Gunmetal", .metal([0.16, 0.13, 0.115], roughness: 0.6))
      Surface("Steel", .metal([0.08, 0.08, 0.085], roughness: 0.35))
      Surface("Black", .dielectric([0.015, 0.015, 0.016], roughness: 0.38))
      Surface("Cord", .dielectric([0.012, 0.012, 0.012], roughness: 0.85))
    }

    Xform("Hilt")
    {
      part(Cylinder("BottomRing", radius: 0.030, z: foot ... foot + 0.056), "Black")
        .edit
        { mesh in
          teeth(mesh, z: foot + 0.006 ... foot + 0.046, radius: 0.030, depth: 0.003)
          shoulder(mesh, top: false, steps: [(0.002, 0.92)])
        }

      // overlaps the rings so no seam
      part(Cylinder("LowerBody", radius: 0.026, z: gripTop - grip - 0.002 ... gripTop), "Gunmetal")

      part(Cylinder("UpperRing", radius: 0.030, z: -0.040 ... 0.014), "Black")
        .edit
        { mesh in
          teeth(mesh, z: -0.036 ... -0.008, radius: 0.030, depth: 0.003)
          shoulder(mesh, steps: [(0.003, 0.93), (0.002, 0.88)])
        }

      part(Cylinder("Grey", radius: 0.021, z: 0.012 ... 0.040), "Aluminum")

      part(Cylinder("Canister", radius: 0.0295, z: 0.045 ... 0.098), "Aluminum")
        .edit
        { mesh in
          // groove near the bottom
          mesh.loopCut(through: [0.0295, 0, 0.0485])
          mesh.loopCut(through: [0.0295, 0, 0.0505])
          mesh.select { $0.isSide && (0.0485 ... 0.0505).contains($0.center.z) }
          mesh.extrude()
          mesh.resize([0.96, 0.96, 1], about: [0, 0, 0.0495])

          // round off both ends
          let bevel: [(rise: Double, pull: Double)] = [(0.004, 0.92), (0.003, 0.86), (0.002, 0.88)]
          shoulder(mesh, steps: bevel)
          shoulder(mesh, top: false, steps: bevel)
        }

      part(Cylinder("Emitter", radius: 0.0205, z: 0.100 ... 0.129), "Aluminum")
        .edit
        { mesh in
          // hollow out the top
          mesh.select { $0.isTop }
          mesh.inset(0.2)
          mesh.extrude(-0.021)
        }

      part(Cylinder("EmitterInside", radius: 0.0162, z: 0.1085 ... 0.1100), "Gunmetal")

      // sits flush on the top of the canister bevel
      part(Cylinder("EmitterTongue", radius: 0.0207, z: 0.107 ... 0.184), "Aluminum")
        .edit
        { mesh in
          // keep the back half of the wall round the emitter
          mesh.select { !$0.isSide || abs($0.center.azimuth - 90) > 90 }
          mesh.delete(.faces)

          // laid flat the outline is two straight edges that run into a round tip right where they touch it
          let r = 0.0207, base = 0.107, top = 0.184
          let corner = r * .pi / 2
          let tip = r * .pi / 3
          let center = top - tip
          let reach = (corner * corner + (base - center) * (base - center)).squareRoot()
          let touch = atan2(base - center, corner) + acos(tip / reach)
          let meet = center + tip * sin(touch)
          let edge = ((corner - tip * cos(touch)) * (corner - tip * cos(touch)) + (meet - base) * (meet - base)).squareRoot()
          let arc = tip * (.pi / 2 - touch)

          func halfWidth(_ z: Double) -> Double
          {
            if z <= meet { return corner + (tip * cos(touch) - corner) * (z - base) / (meet - base) }
            return max(tip * tip - (z - center) * (z - center), 0).squareRoot()
          }

          // even rows along the outline so the quads stay even all the way to the tip
          let rows = 16
          for k in 1 ..< rows
          {
            let along = (edge + arc) * Double(k) / Double(rows)
            let z = along < edge ? base + (meet - base) * along / edge : center + tip * sin(touch + (along - edge) / tip)
            mesh.loopCut(through: [0, r, z])
          }

          // spread each row across the outline round the back
          mesh.selectAll()
          mesh.reshape
          { _, p in
            let across = (p.azimuth - 90) / 90
            let angle = .pi / 2 + across * halfWidth(p.z) / r
            return [p.radial * cos(angle), p.radial * sin(angle), p.z]
          }

          // close the top to a point
          mesh.selectVerts { _, p in p.z > top - 0.0001 }
          mesh.merge()

          mesh.selectAll()
          mesh.extrude(0.0012)
        }

      // lanyard loop and clip
      part(Torus("Lanyard", radius: 0.006, thickness: 0.0018, at: [0.0335, 0, foot + 0.021]), "Cord")
        .transform(rotation: [90, 0, 0])

      part(Torus("Clasp", radius: 0.014, thickness: 0.003, at: [0.052, 0, foot + 0.006], segments: 40, sides: 8), "Steel")
        .edit
        { mesh in
          // stretch into a carabiner
          mesh.selectVerts { _, p in p.x > 0.052 }
          mesh.move([0.036, 0, 0])
        }
        .transform(rotation: [90, 58, 0])
    }

    Xform("Blade")

    Variant("side", "dark")
    {
      blade(core: [1, 0.75, 0.725], coreStrength: 40, sheath: [1, 0.0375, 0.025], sheathStrength: 12,
            light: [1, 0.04, 0.03])
    }

    Variant("side", "light")
    {
      blade(core: [0.85, 0.85, 1], coreStrength: 40, sheath: [0.42, 0.22, 1], sheathStrength: 11,
            light: [0.45, 0.3, 1])
    }
  }
}

// grip length so a hand fits
var grip: Double { 0.110 }
// where the grip ends up top
var gripTop: Double { -0.036 }
// bottom of the hilt
var foot: Double { gripTop - grip - 0.056 }

// ring of teeth around a band
func teeth(_ mesh: EditMesh, z: ClosedRange<Double>, radius: Double, depth: Double)
{
  mesh.loopCut(through: [radius, 0, z.lowerBound])
  mesh.loopCut(through: [radius, 0, z.upperBound])
  mesh.select { $0.isSide && z.contains($0.center.z) }
  mesh.checkerDeselect()
  mesh.extrude()

  let grow = (radius + depth) / radius
  mesh.resize([grow, grow, 1], about: [0, 0, z.middle])
}

// rounds off a cap
func shoulder(_ mesh: EditMesh, top: Bool = true, steps: [(rise: Double, pull: Double)])
{
  mesh.select { top ? $0.isTop : $0.isBottom }
  for step in steps
  {
    mesh.extrude(step.rise)
    mesh.resize([step.pull, step.pull, 1])
  }
}

// two sided, smoothed by subdivision with its hard edges held, with a material
func part(_ node: Node, _ material: String) -> Node
{
  node.set("doubleSided", true).subdivision(creasing: 30).material(material)
}

// glowing blade and its light
@SceneBuilder
func blade(core: Vec3, coreStrength: Double, sheath: Vec3, sheathStrength: Double, light: Vec3) -> [Node]
{
  Within("Looks")
  {
    Surface("Core", .emissive(core, strength: coreStrength))
    Surface("Sheath", .emissive(sheath, strength: sheathStrength, opacity: 0.12))
  }

  Within("Blade")
  {
    part(Cylinder("Core", radius: 0.010, z: 0.118 ... 1.084), "Core")
      .edit { shoulder($0, steps: [(0.003, 0.7), (0.0015, 0.4)]) }
    part(Cylinder("Sheath", radius: 0.0165, z: 0.130 ... 1.090), "Sheath")
      .edit { shoulder($0, steps: [(0.004, 0.7), (0.0025, 0.4)]) }
    // turned to point up the blade
    CylinderLight("Light", radius: 0.02, length: 0.93, intensity: 220, color: light)
      .transform(location: [0, 0, 0.62], rotation: [0, 90, 0])
  }
}

// sunset with the hilt in focus
scene.sun(height: 0.10)
scene.depthOfField(focus: scene["/saber/Hilt/Canister"], fStop: 1.2)
scene.shading = .rendered

scene.defaultPrim = scene["/saber"]
scene.save(to: "Lightsaber.usda")
print("built \(scene.file ?? "Lightsaber.usda")")

// a dark backdrop behind it only the viewport sees
scene.session
{
  let facing = (-view.forward).azimuth + 90
  let backdrop = scene.add(.plane, "Backdrop", at: view.focus + view.forward * 0.6, AddOptions(size: 4))
  backdrop.transform(rotation: [90, 0, facing])
  backdrop.material = scene.material("Backdrop").dielectric([0.03, 0.03, 0.035], roughness: 0.7)
}
