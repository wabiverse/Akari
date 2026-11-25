/* -----------------------------------------------------------------
 * :: :  A  K  A  R  I  :                                         ::
 * -----------------------------------------------------------------
 * Redistribution  and  use  in  source  and  binary  forms, with or
 * without  modification,  are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions  in  binary  form  must  reproduce  the  above
 *    copyright  notice,  this  list of conditions and the following
 *    disclaimer   in   the  documentation  and/or  other  materials
 *    provided with the distribution.
 *
 * 3. Neither the name of  the copyright holder nor the names of its
 *    contributors  may  be  used  to  endorse  or  promote products
 *    derived  from  this  software  without  specific prior written
 *    permission.
 *
 * THIS   SOFTWARE   IS   PROVIDED  BY  THE  COPYRIGHT  HOLDERS  AND
 * CONTRIBUTORS  "AS  IS"  AND  ANY  EXPRESS  OR IMPLIED WARRANTIES,
 * INCLUDING,   BUT  NOT  LIMITED  TO,  THE  IMPLIED  WARRANTIES  OF
 * MERCHANTABILITY   AND   FITNESS  FOR  A  PARTICULAR  PURPOSE  ARE
 * DISCLAIMED.   IN   NO   EVENT   SHALL  THE  COPYRIGHT  HOLDER  OR
 * CONTRIBUTORS  BE  LIABLE  FOR  ANY  DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL,  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
 * USE,  DATA,  OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND  ON  ANY  THEORY  OF  LIABILITY,  WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY  WAY  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 *                               Copyright (C) 2026 Wabi Foundation.
 *                                              All rights reserved.
 * -----------------------------------------------------------------
 *  . x x x . o o o . x x x . : : : .    o  x  o    . : : : .
 * ----------------------------------------------------------------- */

import AkariCore
import AkariRender
import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd

extension Kraken
{
  /// serves kraken scripts over a socket and runs each request through the same operations the ui uses
  @MainActor
  final class ScriptServer
  {
    struct Failure: Error
    {
      var message: String

      init(_ message: String)
      {
        self.message = message
      }
    }

    /// a value the frame queue fills in for the main actor
    final class Box<T>: @unchecked Sendable
    {
      var value: T

      init(_ value: T)
      {
        self.value = value
      }
    }

    let layout: Layout
    /// frames whats built after each edit so a script can be watched
    private var follow = false
    /// the socket scripts connect to
    let socketPath: String
    private var listener: Int32 = -1
    /// outside tools can connect too
    private let everyone = Box(false)
    /// largest request in bytes
    nonisolated static let longestRequest = 256 << 20

    static var shared: ScriptServer?

    /// starts the server once, shared lets outside tools connect
    @discardableResult
    static func start(_ layout: Layout, shared open: Bool = false) -> ScriptServer
    {
      let server = shared ?? ScriptServer(layout: layout)
      if open, !server.everyone.value
      {
        server.everyone.value = true
        Console.warn("script socket is open to every process of this user at \(server.socketPath)")
      }

      if shared == nil
      {
        server.listen()
        shared = server
      }

      return server
    }

    private init(layout: Layout)
    {
      self.layout = layout
      socketPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kraken-\(getpid()).sock").path
    }

    private func listen()
    {
      unlink(socketPath)
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { return Console.error("script socket: \(String(cString: strerror(errno)))") }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(socketPath.utf8CString)
      guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return Console.error("script socket path is too long") }
      withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
      let bound = withUnsafePointer(to: &address)
      {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }

      // only this user can reach the socket
      guard bound == 0, chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 8) == 0 else
      {
        Console.error("script socket: \(String(cString: strerror(errno)))")
        close(fd)
        return
      }

      listener = fd
      let everyone = everyone
      let thread = Thread { [weak self] in
        while true
        {
          let client = accept(fd, nil, nil)
          if client < 0 { if errno == EINTR { continue }; return }
          guard Self.trusted(client, anyone: everyone.value) else
          {
            Console.warn("script socket turned away a process kraken didn't start, launch with --script-socket to allow it")
            close(client)
            continue
          }

          let serve = Thread { self?.serve(client) }
          serve.start()
        }
      }

      thread.name = "Kraken script socket"
      thread.start()
    }

    /// same user, and kraken or one of its children unless shared
    nonisolated static func trusted(_ client: Int32, anyone: Bool) -> Bool
    {
      var uid = uid_t(), gid = gid_t()
      guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return false }
      if anyone { return true }

      #if os(macOS)
        var pid = pid_t(0)
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return false }

        // walk up the parent pids looking for kraken
        let kraken = getpid()
        for _ in 0 ..< 64
        {
          if pid == kraken { return true }
          if pid <= 1 { return false }
          var info = proc_bsdinfo()
          let length = Int32(MemoryLayout<proc_bsdinfo>.size)
          guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length else { return false }
          pid = pid_t(info.pbi_ppid)
        }

        return false
      #else
        return true
      #endif
    }

    /// answers one scripts requests in order until it hangs up
    nonisolated private func serve(_ client: Int32)
    {
      var pending = Data()
      var chunk = [UInt8](repeating: 0, count: 65536)
      defer { close(client) }
      while true
      {
        let count = read(client, &chunk, chunk.count)
        if count <= 0 { return }
        pending.append(chunk, count: count)
        while let newline = pending.firstIndex(of: 0x0A)
        {
          let line = pending[pending.startIndex ..< newline]
          pending = Data(pending[pending.index(after: newline)...])
          let reply = Box(Data())
          let done = DispatchSemaphore(value: 0)
          let request = Data(line)
          Task
          { @MainActor [weak self] in
            reply.value = await self?.answer(request) ?? Data("{\"ok\":false,\"error\":\"Kraken is closing\"}".utf8)
            done.signal()
          }

          done.wait()
          var out = reply.value
          out.append(0x0A)
          let sent = out.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count
            {
              let n = write(client, raw.baseAddress! + offset, raw.count - offset)
              if n <= 0 { return false }
              offset += n
            }

            return true
          }

          if !sent { return }
        }

        // cap request size
        if pending.count > Self.longestRequest { return }
      }
    }

    private func answer(_ line: Data) async -> Data
    {
      var id: Any = NSNull()
      var reply: [String: Any]
      do
      {
        guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let op = request["op"] as? String else { throw Failure("a request needs an op") }
        id = request["id"] ?? NSNull()
        let result = try await handle(op, request["args"] as? [String: Any] ?? [:])
        if follow, ["add", "parent", "transform", "mesh.op", "object", "remove"].contains(op) { layout.hydra.frameAll() }
        reply = ["id": id, "ok": true, "result": result]
      }
      catch let failure as Failure
      {
        reply = ["id": id, "ok": false, "error": failure.message]
      }
      catch
      {
        reply = ["id": id, "ok": false, "error": "\(error)"]
      }

      // json has no nan or infinity and foundation aborts on them rather than throwing, so they go out as null
      return (try? JSONSerialization.data(withJSONObject: Self.finite(reply))) ?? Data("{\"ok\":false,\"error\":\"unencodable reply\"}".utf8)
    }

    /// the reply with every number that is not finite turned into null
    nonisolated static func finite(_ value: Any) -> Any
    {
      switch value
      {
        case let number as Double: number.isFinite ? number : NSNull()
        case let number as Float: number.isFinite ? number : NSNull()
        case let list as [Any]: list.map(finite)
        case let table as [String: Any]: table.mapValues(finite)
        default: value
      }
    }

    /// waits a few round trips through the frame queue so queued edits land
    func settle(_ rounds: Int = 3) async
    {
      for _ in 0 ..< rounds
      {
        await withCheckedContinuation
        { (done: CheckedContinuation<Void, Never>) in
          layout.hydra.performOnFrameQueue { DispatchQueue.main.async { done.resume() } }
        }
      }
    }

    /// runs body on the frame queue with the stage
    func onStage<T: Sendable>(_ body: @escaping @Sendable (UsdStage) -> T) async -> T
    {
      let hydra = layout.hydra
      return await withCheckedContinuation
      { (done: CheckedContinuation<T, Never>) in
        hydra.performOnFrameQueue { done.resume(returning: body(hydra.stage)) }
      }
    }

    private func string(_ args: [String: Any], _ key: String) throws -> String
    {
      guard let value = args[key] as? String, !value.isEmpty else { throw Failure("needs \(key)") }
      return value
    }

    private func numbers(_ args: [String: Any], _ key: String) -> [Double]?
    {
      if let n = args[key] as? Double { return [n] }
      if let n = args[key] as? Int { return [Double(n)] }
      return (args[key] as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
    }

    private func vector(_ args: [String: Any], _ key: String) throws -> SIMD3<Double>
    {
      guard let v = numbers(args, key), v.count == 3 else { throw Failure("needs \(key) as [x, y, z]") }
      return SIMD3(v[0], v[1], v[2])
    }

    private func optionalVector(_ args: [String: Any], _ key: String) throws -> SIMD3<Double>?
    {
      args[key] == nil ? nil : try vector(args, key)
    }

    private func json(_ v: SIMD3<Double>) -> [Double]
    {
      [v.x, v.y, v.z]
    }

    private func exists(_ path: String) async -> Bool
    {
      await onStage { $0.GetPrimAtPath(Sdf.Path(path)).isValid }
    }

    private func needsPrim(_ args: [String: Any], _ key: String = "path") async throws -> String
    {
      let path = try string(args, key)
      guard await exists(path) else { throw Failure("\(path) isn't on the stage") }
      return path
    }

    private func needsMesh() throws -> EditMesh
    {
      guard layout.mode == .edit, let mesh = layout.mesh else { throw Failure("needs a mesh in edit mode, call edit first") }
      return mesh
    }

    private func handle(_ op: String, _ args: [String: Any]) async throws -> Any
    {
      switch op
      {
        case "hello":
          return ["version": Akari.version, "socket": socketPath, "scene": layout.sceneURL?.path ?? ""]
        case "status":
          layout.status = args["text"] as? String ?? ""
          return true
        case "stats":
          // what the fps counter shows, averaged over the last second
          guard let stats = layout.driver?.snapshot() else { throw Failure("no viewport is drawing") }
          return ["fps": stats.framesPerSecond, "ms": stats.frameMilliseconds]
        case "camera":
          // the script aims the view itself from here on
          follow = false
          return try await viewCamera(args)
        case "sun":
          guard let settings = layout.settings else { throw Failure("no render settings to change") }
          let height = Float(numbers(args, "height")?.first ?? 0.6)
          settings.edit
          {
            $0.light.sunHeight = min(max(height, -1), 1)
            $0.light.overridesStageSun = true
          }

          return true
        case "feature":
          guard let settings = layout.settings else { throw Failure("no render settings to change") }
          let features: [String: RenderFeatures] = ["ibl": .imageBasedLighting, "probes": .lightProbes, "shadows": .shadowMaps,
                                                    "ssr": .screenSpaceReflections, "ssgi": .screenSpaceGI, "taa": .temporalAA,
                                                    "bloom": .bloom, "dof": .depthOfField, "volumes": .volumetrics,
                                                    "raytracing": .hardwareRayTracing, "dynamic": .dynamicResolution,
                                                    "motionblur": .motionBlur]
          guard let feature = features[try string(args, "name")] else { throw Failure("feature is one of \(features.keys.sorted())") }
          let on = args["on"] as? Bool ?? true
          settings.edit { if on { $0.features.insert(feature) } else { $0.features.remove(feature) } }
          return on
        case "sky":
          guard let settings = layout.settings else { throw Failure("no render settings to change") }
          let on = args["on"] as? Bool ?? true
          settings.edit { $0.light.showsSky = on }
          return on
        case "session":
          // edits go to the session layer which is never saved
          let on = args["on"] as? Bool ?? true
          let department = layout.department
          await onStage
          { stage in
            if on { stage.SetEditTarget(Kraken.Authoring.target(stage.GetSessionLayer())) }
            else { Kraken.Authoring.work(in: department, stage) }
          }

          return on
        case "dof":
          return try await depthOfField(args)
        case "follow":
          follow = args["on"] as? Bool ?? true
          if follow { layout.hydra.frameAll() }
          return follow
        case "new":
          return try await newScene(args)
        case "open":
          let url = URL(fileURLWithPath: try string(args, "path"))
          await withCheckedContinuation
          { (done: CheckedContinuation<Void, Never>) in
            layout.replaceStage(with: url, asking: false) { done.resume() }
          }

          await settle()
          return try await stageInfo()
        case "save":
          let path = args["path"] as? String
          if path == nil, layout.isUntitled { throw Failure("an untitled scene needs a path to save to") }

          // waits until the saved file is the open scene before answering
          let saved = await withCheckedContinuation
          { (done: CheckedContinuation<Bool, Never>) in
            var answered = false
            layout.save(as: path)
            {
              answered = true
              done.resume(returning: true)
            }

            // a failed save never calls back
            Task
            { @MainActor in
              try? await Task.sleep(for: .seconds(30))
              if !answered
              {
                answered = true
                done.resume(returning: false)
              }
            }
          }

          if !saved { throw Failure("couldn't save, \(layout.status)") }
          await settle()
          return layout.sceneURL?.path ?? ""
        case "stage":
          if args.isEmpty { return try await stageInfo() }
          layout.setStageMetadata(upAxis: args["upAxis"] as? String ?? "", defaultPrim: args["defaultPrim"] as? String ?? "",
                                  documentation: args["doc"] as? String ?? "")
          await settle()
          return try await stageInfo()
        case "prims":
          let root = args["root"] as? String ?? "/"
          return await onStage
          { stage in
            stage.traverse().filter { root == "/" || $0.GetPath().string.hasPrefix(root + "/") }
              .map { ["path": $0.GetPath().string, "type": $0.typeName.string] }
          }
        case "get":
          return try await describe(try await needsPrim(args))
        case "add":
          return try await add(args)
        case "select":
          let paths = args["paths"] as? [String] ?? []
          if layout.mode == .edit { layout.exitEdit() }
          layout.select(paths)
          await settle()
          return layout.selection
        case "rename":
          let path = try await needsPrim(args)
          return try await rename(path, try string(args, "name"))
        case "parent":
          let paths = args["paths"] as? [String] ?? []
          let parent = try string(args, "parent")
          guard !paths.isEmpty else { throw Failure("needs paths") }
          return try await reparent(paths, parent)
        case "remove":
          let paths = args["paths"] as? [String] ?? []
          if layout.mode == .edit { layout.exitEdit() }
          layout.select(paths)
          layout.deleteSelected()
          await settle()
          return true
        case "join":
          // the last path is the active one everything joins into
          if let paths = args["paths"] as? [String] { layout.select(paths) }
          layout.joinSelected()
          await settle()
          return ["selection": layout.selection, "status": layout.status]
        case "select.hierarchy":
          if let paths = args["paths"] as? [String] { layout.select(paths) }
          layout.selectHierarchy()
          await settle()
          return layout.selection
        case "transform":
          return try await transform(try await needsPrim(args), args)
        case "cursor":
          if let v = try optionalVector(args, "location") { layout.cursor = v * layout.unit }
          return json(layout.cursor / layout.unit)
        case "attr.set":
          return try await setAttribute(try await needsPrim(args), args)
        case "attr.get":
          let path = try await needsPrim(args)
          let name = Tf.Token(try string(args, "name"))
          let time = layout.hydra.currentTimeCode
          return await onStage { Array(Kraken.SceneEdit.values($0, path, [name], time)) }
        case "token.set":
          let path = try await needsPrim(args)
          let name = Tf.Token(try string(args, "name")), value = Tf.Token(try string(args, "value"))
          layout.checkpoint()
          let wrote = await onStage { Kraken.SceneEdit.setToken($0, path, name, value) }
          if !wrote { throw Failure("couldn't set \(name.string)") }
          return true
        case "retype":
          let path = try await needsPrim(args)
          let type = Tf.Token(try string(args, "type"))
          layout.checkpoint()
          let done = await onStage
          { stage in
            Kraken.Authoring.edit(stage, path)
            { found, _ in
              var prim = found
              guard prim.SetTypeName(type) else { return false }

              // a prim that isnt xformable keeps no transform
              if !prim.isA(.xformable)
              {
                _ = prim.RemoveProperty(Tf.Token("xformOp:transform"))
                _ = prim.RemoveProperty(Tf.Token("xformOpOrder"))
              }

              return true
            }
          }

          if !done { throw Failure("couldn't make \(path) a \(type.string)") }
          layout.primsChanged()
          return true
        case "material.new":
          return try await newMaterial(args)
        case "material.bind":
          let path = try await needsPrim(args)
          let material = try await needsPrim(args, "material")
          layout.checkpoint()
          let bound = await onStage { Kraken.SceneEdit.bindMaterial($0, path, material) }
          if !bound { throw Failure("couldn't bind \(material) to \(path)") }
          layout.inspector.reload()
          return true
        case "material.set":
          return try await setMaterialInput(args)
        case "materials":
          return await onStage { Kraken.SceneEdit.materials($0) }
        case "variant.add":
          let path = try await needsPrim(args)
          layout.select([path])
          layout.addVariant(set: try string(args, "set"), variant: try string(args, "variant"))
          await settle()
          return try await variants(path)
        case "variant.select":
          let path = try await needsPrim(args)
          layout.selectVariant(set: try string(args, "set"), variant: try string(args, "variant"), on: path)
          await settle()
          return try await variants(path)
        case "variant.edit":
          let path = try await needsPrim(args)
          layout.editVariant(set: try string(args, "set"), variant: try string(args, "variant"), on: path)
          await settle()
          return true
        case "variant.done":
          layout.editVariant(set: "", variant: nil)
          await settle()
          return true
        case "variants":
          return try await variants(try await needsPrim(args))
        case "edit":
          return try await beginEdit(try await needsPrim(args))
        case "object":
          if layout.mode == .edit { layout.exitEdit() }
          await settle()
          return true
        case "mesh":
          return snapshot(try needsMesh())
        case "mesh.select":
          return try selectElements(args)
        case "mesh.op":
          return try await meshOp(try string(args, "op"), args)
        case "view":
          try view(try string(args, "view"))
          return true
        case "shading":
          let modes: [String: ViewportShading] = ["solid": .solid, "material": .materialPreview, "rendered": .rendered,
                                                  "wireframe": .wireframe]
          guard let mode = modes[try string(args, "mode")] else { throw Failure("shading is solid, material, rendered or wireframe") }
          layout.setShading(mode)
          return true
        case "undo":
          layout.undo()
          await settle()
          return true
        case "redo":
          layout.redo()
          await settle()
          return true
        default:
          throw Failure("unknown op \(op)")
      }
    }

    private func stageInfo() async throws -> [String: Any]
    {
      let info = await onStage
      { stage -> [String] in
        let home = stage.GetDefaultPrim()
        return [UsdGeom.getUpAxis(for: stage) == .z ? "Z" : "Y", home.isValid ? home.GetPath().string : "",
                String(UsdGeom.getMetersPerUnit(for: stage))]
      }

      return ["upAxis": info[0], "defaultPrim": info[1], "metersPerUnit": Double(info[2]) ?? 1,
              "path": layout.sceneURL?.path ?? ""]
    }

    /// file new with the starter prims removed
    private func newScene(_ args: [String: Any]) async throws -> Any
    {
      await withCheckedContinuation
      { (done: CheckedContinuation<Void, Never>) in
        layout.replaceStage(with: nil, asking: false) { done.resume() }
      }

      await settle()
      if !(args["keep"] as? Bool ?? false)
      {
        let roots = await onStage { stage in Kraken.SceneEdit.children(stage.GetPseudoRoot()).map { $0.GetPath().string } }
        layout.select(roots)
        layout.deleteSelected()
        await settle()
      }

      if let up = args["upAxis"] as? String
      {
        layout.setStageMetadata(upAxis: up)
        await settle()
      }

      layout.cursor = .zero
      return try await stageInfo()
    }

    private func describe(_ path: String) async throws -> [String: Any]
    {
      let time = layout.hydra.currentTimeCode
      let read = await onStage
      { stage -> (String, [Double]?, String, [String]) in
        let prim = stage.GetPrimAtPath(Sdf.Path(path))
        let placed = Layout.placement(stage, path, time)
        let parts = placed.map
        { p -> [Double] in
          let (t, r, s) = Inspector.euler(p.local)
          return [t.x, t.y, t.z, r.x, r.y, r.z, s.x, s.y, s.z]
        }

        let material = Kraken.SceneEdit.boundMaterial(prim).map { $0.GetPrim().GetPath().string } ?? ""
        let children = Kraken.SceneEdit.children(prim).map { $0.GetPath().string }
        return (prim.typeName.string, parts, material, children)
      }

      var info: [String: Any] = ["path": path, "type": read.0, "material": read.2, "children": read.3]
      if let p = read.1
      {
        let u = layout.unit
        info["location"] = [p[0] / u, p[1] / u, p[2] / u]
        info["rotation"] = [p[3], p[4], p[5]]
        info["scale"] = [p[6], p[7], p[8]]
      }

      return info
    }

    /// adds a primitive then renames and parents it with the uis own operations
    private func add(_ args: [String: Any]) async throws -> Any
    {
      let word = try string(args, "kind").lowercased()
      guard let kind = AddKind.allCases.first(where: { $0.rawValue == word || $0.name.lowercased() == word }) else
      {
        throw Failure("unknown kind \(word), one of \(AddKind.allCases.map(\.rawValue).joined(separator: ", "))")
      }

      var options = AddOptions()
      if let o = args["options"] as? [String: Any]
      {
        func f(_ key: String) -> Float? { (o[key] as? Double).map(Float.init) ?? (o[key] as? Int).map(Float.init) }
        func i(_ key: String) -> Int? { (o[key] as? Int) ?? (o[key] as? Double).flatMap { Int(exactly: $0.rounded()) } }
        options.radius = f("radius") ?? options.radius
        options.depth = f("depth") ?? options.depth
        options.size = f("size") ?? options.size
        options.vertices = i("vertices") ?? options.vertices
        options.rings = i("rings") ?? options.rings
        options.subdivisions = i("subdivisions") ?? options.subdivisions
        options.cuts = i("cuts") ?? options.cuts
        options.majorRadius = f("majorRadius") ?? options.majorRadius
        options.minorRadius = f("minorRadius") ?? options.minorRadius
        options.majorSegments = i("majorSegments") ?? options.majorSegments
        options.minorSegments = i("minorSegments") ?? options.minorSegments
      }

      // sizes are meters but the stage units may not be
      let u = Float(layout.unit)
      options.radius *= u; options.depth *= u; options.size *= u; options.majorRadius *= u; options.minorRadius *= u
      let parent = args["parent"] as? String
      if let parent, parent != "/", !(await exists(parent)) { throw Failure("\(parent) isn't on the stage") }
      let saved = layout.cursor
      if let at = try optionalVector(args, "location") { layout.cursor = at * layout.unit }
      defer { layout.cursor = saved }
      let before = layout.active
      layout.add(kind, options: options, under: parent)
      await settle()
      guard var path = layout.active, path != before else { throw Failure("couldn't add \(word)") }
      if let name = args["name"] as? String, !name.isEmpty, !path.hasSuffix("/" + name)
      {
        path = try await rename(path, name)
      }

      layout.select([path])
      await settle()
      let made = path
      let type = await onStage { $0.GetPrimAtPath(Sdf.Path(made)).typeName.string }
      return ["path": made, "type": type]
    }

    private func rename(_ path: String, _ name: String) async throws -> String
    {
      let renamed = await withCheckedContinuation
      { (done: CheckedContinuation<String?, Never>) in
        var answered = false
        layout.rename(path, to: name)
        { new in
          answered = true
          done.resume(returning: new)
        }

        // a failed rename never calls back so give up once it would have landed
        Task
        { @MainActor in
          await self.settle(6)
          if !answered
          {
            answered = true
            done.resume(returning: nil)
          }
        }
      }

      guard let renamed else { throw Failure("couldn't rename \(path) to \(name)") }
      await settle()
      return renamed
    }

    private func reparent(_ paths: [String], _ parent: String) async throws -> [String]
    {
      if parent != "/", !(await exists(parent)) { throw Failure("\(parent) isn't on the stage") }
      if layout.mode == .edit { layout.exitEdit() }
      layout.select(paths)
      await settle()
      let moved = await withCheckedContinuation
      { (done: CheckedContinuation<[String], Never>) in
        layout.parentSelected(to: parent) { done.resume(returning: $0) }
      }

      guard moved.count == paths.count else { throw Failure("couldn't parent \(paths.joined(separator: ", ")) to \(parent)") }
      await settle()
      return moved
    }

    /// sets location in meters, rotation in degrees and scale, keeping any left out
    private func transform(_ path: String, _ args: [String: Any]) async throws -> Any
    {
      if layout.mode == .edit { layout.exitEdit() }
      let time = layout.hydra.currentTimeCode
      guard let placement = await onStage({ Layout.placement($0, path, time) }) else { throw Failure("\(path) has no transform") }
      var (t, r, s) = Inspector.euler(placement.local)
      if let v = try optionalVector(args, "location") { t = v * layout.unit }
      if let v = try optionalVector(args, "rotation") { r = v }
      if let v = try optionalVector(args, "scale") { s = v }
      layout.checkpoint()
      layout.setLocals([path: Inspector.compose(t, r, s)])
      await settle()
      layout.inspector.reload()
      return try await describe(path)
    }

    private func setAttribute(_ path: String, _ args: [String: Any]) async throws -> Any
    {
      let name = Tf.Token(try string(args, "name"))
      let triple: Bool
      let values: [Double]
      if let flag = args["value"] as? Bool { values = [flag ? 1 : 0]; triple = false }
      else
      {
        guard let v = numbers(args, "value"), !v.isEmpty else { throw Failure("needs a value") }
        values = v
        triple = v.count == 3
      }

      layout.checkpoint()
      let wrote = await onStage
      {
        Kraken.SceneEdit.setValue($0, path, name, values, type: Sdf.getValueType(for: triple ? .float3 : .float))
      }

      if !wrote { throw Failure("couldn't set \(name.string) on \(path)") }
      layout.inspector.reload()
      return true
    }

    private func newMaterial(_ args: [String: Any]) async throws -> Any
    {
      let name = args["name"] as? String ?? "Material"
      let scope = args["scope"] as? String ?? ""
      let bind = args["bind"] as? String
      if let bind, !(await exists(bind)) { throw Failure("\(bind) isn't on the stage") }
      layout.checkpoint()
      let made = await onStage
      { stage -> String in
        let target = bind.map { stage.GetPrimAtPath(Sdf.Path($0)) }
        return Kraken.SceneEdit.newMaterial(stage, binding: target, named: name, in: scope)
      }

      guard !made.isEmpty else { throw Failure("couldn't make the material \(name)") }
      layout.primsChanged()
      layout.inspector.reload()
      return made
    }

    /// sets a pxrsurface input, its preview surface follows
    private func setMaterialInput(_ args: [String: Any]) async throws -> Any
    {
      let material = try await needsPrim(args, "material")
      let input = try string(args, "input")
      let name = Tf.Token(input.hasPrefix("inputs:") ? input : "inputs:" + input)
      guard let values = numbers(args, "value"), !values.isEmpty else { throw Failure("needs a value") }
      let color = values.count == 3
      layout.checkpoint()
      let wrote = await onStage
      { stage -> Bool in
        let shader = material + "/" + UsdShade.Shader.ShaderId.pxrSurface.getToken().string
        return Kraken.SceneEdit.setValue(stage, shader, name, values, type: Sdf.getValueType(for: color ? .color3f : .float))
      }

      if !wrote { throw Failure("couldn't set \(input) on \(material)") }
      layout.inspector.reload()
      return true
    }

    private func variants(_ path: String) async throws -> [[String: Any]]
    {
      await onStage { Kraken.SceneEdit.variantSets($0, path) }.map
      {
        ["name": $0.name, "selection": $0.selection, "variants": $0.variants]
      }
    }

    private func beginEdit(_ path: String) async throws -> Any
    {
      if layout.mode == .edit, layout.mesh?.path == path { return snapshot(try needsMesh()) }
      if layout.mode == .edit { layout.exitEdit() }
      layout.select([path])
      await settle()
      layout.enterEdit()
      await settle()
      guard layout.mode == .edit, layout.mesh?.path == path else { throw Failure("\(path) isn't a mesh") }
      return snapshot(try needsMesh())
    }

    /// the edit mesh in world space and meters
    private func snapshot(_ mesh: EditMesh) -> [String: Any]
    {
      let world = layout.meshWorld
      let normals = world.inverse.transpose
      let u = layout.unit
      func place(_ p: SIMD3<Float>) -> [Double]
      {
        let w = world * SIMD4(SIMD3<Double>(p), 1)
        return [w.x / u, w.y / u, w.z / u]
      }

      let faces = mesh.faces.map
      { face -> [String: Any] in
        let n4 = normals * SIMD4(SIMD3<Double>(mesh.normal(face)), 0)
        let n = simd_normalize(SIMD3(n4.x, n4.y, n4.z))
        return ["verts": face, "center": place(mesh.center(face)), "normal": [n.x, n.y, n.z]]
      }

      return ["path": mesh.path, "points": mesh.points.map(place), "faces": faces,
              "edges": mesh.allEdges.map { [$0.a, $0.b] },
              "selectedFaces": mesh.selectedFaceList, "selectedVerts": mesh.verts.sorted()]
    }

    private func selectElements(_ args: [String: Any]) throws -> Any
    {
      let extend = args["extend"] as? Bool ?? false

      // picking faces switches to face mode and picking verts to vertex mode
      if args["faces"] != nil, layout.selectMode != .face { layout.setSelectMode(.face) }
      if args["verts"] != nil, layout.selectMode != .vertex { layout.setSelectMode(.vertex) }
      var mesh = try needsMesh()
      if let faces = args["faces"] as? [Int]
      {
        let chosen = Set(faces.filter { $0 >= 0 && $0 < mesh.faces.count }).union(extend ? Set(mesh.selectedFaceList) : [])
        mesh.select(faces: Array(chosen))
        mesh.flush()
      }
      else if let verts = args["verts"] as? [Int]
      {
        let chosen = Set(verts.filter { $0 >= 0 && $0 < mesh.points.count })
        mesh.select(verts: chosen.union(extend ? mesh.verts : []))
      }
      else if args["all"] as? Bool == true
      {
        mesh.selectAll(true)
      }
      else
      {
        mesh.clearSelection()
      }

      layout.mesh = mesh
      return snapshot(mesh)
    }

    private static func translation(_ t: SIMD3<Double>) -> simd_double4x4
    {
      var m = matrix_identity_double4x4
      m.columns.3 = SIMD4(t, 1)
      return m
    }

    /// applies a world space change to the selected verts about a pivot
    private func change(_ d: simd_double4x4, about pivot: SIMD3<Double>?) throws
    {
      guard let pivot = pivot ?? layout.pivot else { throw Failure("nothing selected") }
      let m = Self.translation(pivot) * d * Self.translation(-pivot)
      layout.editMesh
      { mesh, world in
        let local = world.inverse * m * world
        for v in mesh.verts
        {
          let p = local * SIMD4(SIMD3<Double>(mesh.points[v]), 1)
          mesh.points[v] = SIMD3<Float>(SIMD3(p.x, p.y, p.z))
        }
      }
    }

    private func meshOp(_ op: String, _ args: [String: Any]) async throws -> Any
    {
      let mesh = try needsMesh()
      let u = layout.unit
      let pivot = try optionalVector(args, "pivot").map { $0 * u }
      switch op
      {
        case "move":
          try change(Self.translation(try vector(args, "by") * u), about: .zero)
        case "resize":
          try change(simd_double4x4(diagonal: SIMD4(try vector(args, "by"), 1)), about: pivot)
        case "rotate":
          let degrees = numbers(args, "degrees")?.first ?? 0
          try change(simd_double4x4(simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(try vector(args, "axis")))),
                     about: pivot)
        case "extrude":
          guard !mesh.verts.isEmpty else { throw Failure("nothing selected to extrude") }
          var direction: SIMD3<Float>?
          layout.editMesh { mesh, _ in direction = mesh.extrude() }
          if let distance = numbers(args, "distance")?.first
          {
            guard let direction else { throw Failure("the extrusion faces every way, extrude without a distance and move it") }
            let w = layout.meshWorld * SIMD4(SIMD3<Double>(direction), 0)
            try change(Self.translation(simd_normalize(SIMD3(w.x, w.y, w.z)) * distance * u), about: .zero)
          }
        case "inset":
          guard !mesh.selectedFaceList.isEmpty else { throw Failure("no faces selected to inset") }
          let t = Float(numbers(args, "amount")?.first ?? 0.1)
          layout.editMesh { mesh, _ in mesh.inset(t) }
        case "loopcut":
          // through cuts where the loop passes a point, near cuts the nearest edge at a fraction
          let through = args["through"] != nil
          let p = try vector(args, through ? "through" : "near") * u
          let local4 = layout.meshWorld.inverse * SIMD4(p, 1)
          let local = SIMD3<Float>(SIMD3(local4.x, local4.y, local4.z))
          func along(_ e: Kraken.Edge) -> Float
          {
            let a = mesh.points[e.a], b = mesh.points[e.b], d = b - a
            let length = simd_length_squared(d)
            return length > 0 ? min(max(simd_dot(local - a, d) / length, 0), 1) : 0.5
          }

          func distance(_ e: Kraken.Edge) -> Float
          {
            through ? simd_distance(simd_mix(mesh.points[e.a], mesh.points[e.b], SIMD3(repeating: along(e))), local)
              : simd_distance((mesh.points[e.a] + mesh.points[e.b]) / 2, local)
          }

          guard let edge = mesh.allEdges.min(by: { distance($0) < distance($1) }) else { throw Failure("the mesh has no edges") }
          let t = through ? along(edge) : Float(numbers(args, "at")?.first ?? 0.5)
          guard t > 1e-4, t < 1 - 1e-4 else { throw Failure("the loop would cut through an existing vert") }
          layout.editMesh { mesh, _ in mesh.loopCut(edge, at: t) }
        case "set":
          // moves verts to world positions in meters
          let verts = args["verts"] as? [Int] ?? []
          let points = (args["points"] as? [[Any]] ?? []).map { $0.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) } }
          guard verts.count == points.count, points.allSatisfy({ $0.count == 3 }) else { throw Failure("set needs a point for each vert") }
          guard verts.allSatisfy({ $0 >= 0 && $0 < mesh.points.count }) else { throw Failure("set got a vert the mesh doesn't have") }
          layout.editMesh
          { mesh, world in
            let local = world.inverse
            for (v, p) in zip(verts, points)
            {
              let q = local * SIMD4(p[0] * u, p[1] * u, p[2] * u, 1)
              mesh.points[v] = SIMD3<Float>(SIMD3(q.x, q.y, q.z))
            }
          }
        case "subdivide":
          layout.editMesh { mesh, _ in mesh.subdivide() }
        case "crease":
          guard !mesh.selectedEdgeList.isEmpty else { throw Failure("no edges selected to crease") }
          let value = Float(numbers(args, "value")?.first ?? 1)
          layout.editMesh { mesh, _ in mesh.setCrease(value) }
        case "sharp":
          guard !mesh.selectedEdgeList.isEmpty else { throw Failure("no edges selected to mark") }
          let on = args["on"] as? Bool ?? true
          layout.editMesh { mesh, _ in mesh.markSharp(on) }
        case "selectsharp":
          let angle = Float(numbers(args, "angle")?.first ?? 30)
          layout.editMesh { mesh, _ in mesh.selectSharp(angle: angle) }
        case "fill":
          var filled = false
          layout.editMesh { mesh, _ in filled = mesh.fill() }
          if !filled { throw Failure("couldn't fill, select three or more verts") }
        case "checker":
          layout.mesh?.checkerDeselect()
        case "linked":
          layout.mesh?.selectLinked()
        case "invert":
          layout.mesh?.invert()
        case "duplicate":
          var made = false
          layout.editMesh { mesh, _ in made = mesh.duplicate() }
          if !made { throw Failure("no faces selected to duplicate") }
        case "delete":
          let kinds: [String: EditMesh.Removal] = ["verts": .vertices, "edges": .edges, "faces": .faces]
          guard let kind = kinds[args["what"] as? String ?? "faces"] else { throw Failure("delete verts, edges or faces") }
          layout.editMesh { mesh, _ in mesh.delete(kind) }
        case "merge":
          switch args["at"] as? String ?? "center"
          {
            case "center":
              layout.editMesh { mesh, _ in mesh.merge(at: nil) }
            case "cursor":
              let cursor = layout.cursor
              layout.editMesh
              { mesh, world in
                let p = world.inverse * SIMD4(cursor, 1)
                mesh.merge(at: SIMD3<Float>(SIMD3(p.x, p.y, p.z)))
              }
            case "distance":
              let d = Float((numbers(args, "distance")?.first ?? 0.0001) * u)
              layout.editMesh { mesh, _ in mesh.mergeByDistance(d) }
            default:
              throw Failure("merge at center, cursor or distance")
          }
        case "mode":
          let modes: [String: SelectMode] = ["vertex": .vertex, "edge": .edge, "face": .face]
          guard let mode = modes[args["mode"] as? String ?? ""] else { throw Failure("mode is vertex, edge or face") }
          layout.setSelectMode(mode)
        case "add":
          #if os(macOS)
            let word = try string(args, "kind")
            guard let kind = AddKind.meshes.first(where: { $0.rawValue == word }) else { throw Failure("unknown mesh \(word)") }
            guard let viewport = layout.viewport else { throw Failure("no viewport") }
            viewport.add(kind)
            await settle()
          #endif
        default:
          throw Failure("unknown mesh op \(op)")
      }

      await settle(1)
      return snapshot(try needsMesh())
    }

    /// aims the view camera and answers where it ends up
    private func viewCamera(_ args: [String: Any]) async throws -> Any
    {
      let u = layout.unit
      let focus = try optionalVector(args, "focus").map { $0 * u }
      let distance = numbers(args, "distance")?.first.map { $0 * u }
      let pitch = numbers(args, "pitch")?.first, yaw = numbers(args, "yaw")?.first
      let hydra = layout.hydra
      let placed = await onStage
      { _ -> [Double] in
        hydra.stopFlick()
        if let focus { hydra.viewCamera.focus = Pixar.GfVec3d(focus.x, focus.y, focus.z) }
        if let distance { hydra.viewCamera.distance = max(distance, 0.01) }
        if pitch != nil || yaw != nil
        {
          let now = hydra.viewCamera.rotation
          hydra.viewCamera.rotation = Pixar.GfVec3d(pitch ?? now[0], yaw ?? now[1], now[2])
        }

        let m = hydra.viewCamera.getTransform()
        let eye = m.Transform(Pixar.GfVec3d(0, 0, 0)), ahead = m.TransformDir(Pixar.GfVec3d(0, 0, -1))
        let at = hydra.viewCamera.focus
        return [eye[0], eye[1], eye[2], ahead[0], ahead[1], ahead[2], at[0], at[1], at[2]]
      }

      let p = placed.map { $0 / u }
      let ahead = simd_normalize(SIMD3(placed[3], placed[4], placed[5]))
      return ["eye": [p[0], p[1], p[2]], "forward": [ahead.x, ahead.y, ahead.z], "focus": [p[6], p[7], p[8]]]
    }

    /// sets view depth of field on a prim or a distance
    private func depthOfField(_ args: [String: Any]) async throws -> Any
    {
      guard let settings = layout.settings else { throw Failure("no render settings to change") }
      let on = args["on"] as? Bool ?? true
      var point = SIMD3<Double>.zero
      let focus = args["focus"] as? String ?? ""
      if !focus.isEmpty
      {
        guard await exists(focus) else { throw Failure("\(focus) isn't on the stage") }
        let time = layout.hydra.currentTimeCode
        point = await onStage
        { stage -> SIMD3<Double> in
          var p = [0.0, 0.0, 0.0]
          _ = Pixar.HdAkariPrimLocalCenter(stage, std.string(focus), time, &p)
          return SIMD3(p[0], p[1], p[2])
        }
      }

      let distance = numbers(args, "distance")?.first
      let fStop = numbers(args, "fStop")?.first
      let maxSize = numbers(args, "maxSize")?.first
      settings.edit
      {
        if on { $0.features.insert(.depthOfField) } else { $0.features.remove(.depthOfField) }
        guard on else { return }
        $0.depthOfField.overridesCamera = true
        $0.depthOfField.focusObject = focus
        $0.depthOfField.focusPoint = point
        if let distance { $0.depthOfField.focusDistance = Float(distance) }
        if let fStop { $0.depthOfField.fStop = Float(fStop) }
        if let maxSize { $0.depthOfField.maxSize = Float(maxSize) }
      }

      return on
    }

    private func view(_ name: String) throws
    {
      switch name
      {
        case "front": layout.hydra.setStandardView(.front)
        case "back": layout.hydra.setStandardView(.back)
        case "top": layout.hydra.setStandardView(.top)
        case "bottom": layout.hydra.setStandardView(.bottom)
        case "right": layout.hydra.setStandardView(.right)
        case "left": layout.hydra.setStandardView(.left)
        case "all": layout.frameAll()
        case "selected": layout.frameSelected()
        case "camera": layout.toggleCamera?()
        default: throw Failure("view is front, back, top, bottom, right, left, all, selected or camera")
      }
    }
  }
}
