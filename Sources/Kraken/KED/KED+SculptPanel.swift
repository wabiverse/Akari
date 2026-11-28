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

#if os(macOS)
  import AppKit
#endif
import Foundation
import SwiftCrossUI

extension Kraken.SculptFalloff: CustomStringConvertible
{
  var description: String { rawValue }
}

extension Kraken.SculptShape: CustomStringConvertible
{
  var description: String { rawValue }
}

extension Kraken.SculptCombine: CustomStringConvertible
{
  var description: String { rawValue }
}

extension Kraken.SculptDetail: CustomStringConvertible
{
  var description: String { rawValue }
}

extension Kraken.SculptShading: CustomStringConvertible
{
  var description: String { rawValue }
}

extension Kraken.SculptPlacement: CustomStringConvertible
{
  var description: String { rawValue }
}

extension Kraken
{
  /// a text button as wide as the other controls in the column so the panel's right edge lines up
  @MainActor
  struct PanelButton: View
  {
    let title: String
    var accent = false
    let action: () -> Void

    @State private var hovered = false

    init(_ title: String, accent: Bool = false, action: @escaping () -> Void)
    {
      self.title = title
      self.accent = accent
      self.action = action
    }

    var body: some View
    {
      Text(title)
        .font(Properties.font)
        .foregroundColor(Properties.text)
        .frame(width: Double(Properties.controlWidth), height: Double(Properties.rowHeight))
        .background(RoundedRectangle(cornerRadius: 4)
          .fill(accent ? Properties.accent : hovered ? Properties.fieldHover : Properties.field))
        .onHover { hovered = $0 }
        .onTapGesture { action() }
    }
  }

  /// a small icon toggle for bars over the viewport
  @MainActor
  struct BarToggle: View
  {
    let symbol: String
    let label: String
    let on: Bool
    let action: () -> Void

    init(_ symbol: String, label: String = "", on: Bool, action: @escaping () -> Void)
    {
      self.symbol = symbol
      self.label = label
      self.on = on
      self.action = action
    }

    var body: some View
    {
      HStack(spacing: 3)
      {
        if !symbol.isEmpty { SymbolIcon(symbol, size: FormFactor.isTouch ? 14 : 10, white: on ? 1 : 0.8) }
        if !label.isEmpty
        {
          Text(label)
            .font(Properties.font)
            .foregroundColor(on ? Properties.text : Properties.label)
        }
      }
      .padding(.horizontal, 6)
      .frame(height: FormFactor.isTouch ? 36 : 22)
      .background(RoundedRectangle(cornerRadius: FormFactor.isTouch ? 9 : 4).fill(on ? Properties.accent : Properties.menu))
      .onTapGesture { action() }
    }
  }

  #if os(macOS)
    /// a header button that opens a menu under itself, drawn like the header's own buttons
    final class HeaderMenuView: NSView
    {
      var title = ""
      var symbol: String?
      var entries: () -> [MenuEntry] = { [] }
      private var hovered = false
      private var tracking: NSTrackingArea?

      private static let button = NSColor(white: 0.27, alpha: 1)
      private static let ink = NSColor(white: 0.88, alpha: 1)
      private static let font = NSFont.systemFont(ofSize: 11)

      override var isFlipped: Bool
      {
        true
      }

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
      }

      override func mouseEntered(with _: NSEvent)
      {
        hovered = true
        needsDisplay = true
      }

      override func mouseExited(with _: NSEvent)
      {
        hovered = false
        needsDisplay = true
      }

      override func mouseDown(with _: NSEvent)
      {
        MenuPanel.show(MenuEntry.menu(entries()), at: CGPoint(x: bounds.minX + 12, y: bounds.maxY + 12), in: self)
      }

      override func draw(_: NSRect)
      {
        let r = bounds.insetBy(dx: 0, dy: 1)
        (hovered ? Self.button.highlight(withLevel: 0.1) ?? Self.button : Self.button).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()

        var x = r.minX + 7
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
          .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Self.ink])))
        {
          let side: CGFloat = 13
          let scale = min(side / image.size.width, side / image.size.height, 1)
          let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
          image.draw(in: CGRect(x: x + (side - size.width) / 2, y: r.midY - size.height / 2, width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
          x += side + 6
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Self.ink]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: x, y: r.midY - size.height / 2), withAttributes: attributes)

        let arrow = "▾" as NSString
        let arrowSize = arrow.size(withAttributes: attributes)
        arrow.draw(at: CGPoint(x: r.maxX - arrowSize.width - 6, y: r.midY - arrowSize.height / 2), withAttributes: attributes)
      }
    }
  #endif

  /// a header button that opens a menu, the brush or the falloff picked from it
  @MainActor
  struct HeaderMenu: View
  {
    let title: String
    var symbol: String?
    let width: Double
    let entries: () -> [MenuEntry]

    init(_ title: String, symbol: String? = nil, width: Double, entries: @escaping () -> [MenuEntry])
    {
      self.title = title
      self.symbol = symbol
      self.width = width
      self.entries = entries
    }

    var body: some View
    {
      #if os(macOS)
        NativeView(make: { HeaderMenuView() },
                   update: { [title, symbol, entries] view in
                     view.title = title
                     view.symbol = symbol
                     view.entries = entries
                     view.needsDisplay = true
                   },
                   size: { [width] _ in ViewSize(width, 22) })
      #else
        Text(title)
          .font(Properties.font)
          .foregroundColor(Properties.text)
          .frame(width: width, height: 22)
      #endif
    }
  }

  /// the brushes down the side of the sculpt viewport, grouped the way they work
  @MainActor
  struct SculptToolShelf: View
  {
    @State private var sculpt: Sculpt
    let layout: Layout

    init(layout: Layout)
    {
      self.layout = layout
      _sculpt = State(wrappedValue: layout.sculpt)
    }

    static let cell = FormFactor.isTouch ? 42.0 : 28.0
    static let width = cell + 16

    var body: some View
    {
      if layout.showsToolbar
      {
        PropertiesScroll
        {
          VStack(spacing: 2)
          {
            ForEach(Array(SculptBrush.groups.indices), id: \.self)
            { g in
              ForEach(SculptBrush.groups[g], id: \.self)
              { brush in
                SymbolIcon(brush.symbol, size: Self.cell * 0.42, white: sculpt.brush == brush ? 1 : 0.82)
                  .frame(width: Self.cell, height: Self.cell)
                  .background(RoundedRectangle(cornerRadius: FormFactor.isTouch ? 10 : 4)
                    .fill(sculpt.brush == brush ? Properties.accent : Color(white: 0.16, opacity: 0.92)))
                  .onTapGesture { sculpt.brush = brush }
              }

              Spacer().frame(height: 6)
            }
          }
          .padding(8)
        }
        .frame(width: Self.width)
      }
    }
  }

  /// what the sculpt viewport is looking at, written over its top left corner
  @MainActor
  struct SculptInfo: View
  {
    @State private var sculpt: Sculpt
    let layout: Layout

    init(layout: Layout)
    {
      self.layout = layout
      _sculpt = State(wrappedValue: layout.sculpt)
    }

    private func line(_ text: String) -> some View
    {
      Text(text)
        .font(.system(size: 11))
        .foregroundColor(Color(white: 0.86))
    }

    var body: some View
    {
      VStack(alignment: .leading, spacing: 2)
      {
        line("User Perspective")
        if let path = sculpt.primPath
        {
          line(String(path.split(separator: "/").last ?? ""))
          Spacer().frame(height: 6)
          line("Vertices  \(sculpt.counts.vertices.formatted())")
          line("Faces  \(sculpt.counts.faces.formatted())")
          line("Sculpt Faces  \(sculpt.surfaceFaces.formatted())")
          line("Voxel Size  \(Sculpt.format(voxel: Double(sculpt.volume.voxel)))")
        }
      }
      .padding(.leading, layout.showsToolbar ? Int(SculptToolShelf.cell) + 22 : 12)
      .padding(.top, 10)
    }
  }

  /// every brush in a row under the viewport, larger than the tool column and named, sorted into the groups they work in
  @MainActor
  struct SculptShelf: View
  {
    @State private var sculpt: Sculpt
    @State private var group = -1

    init(sculpt: Sculpt)
    {
      _sculpt = State(wrappedValue: sculpt)
    }

    static let groupNames = ["Build", "Shape", "Move", "Paint"]

    private func tab(_ title: String, _ index: Int) -> some View
    {
      Text(title)
        .font(Properties.font)
        .foregroundColor(group == index ? Properties.text : Properties.label)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(group == index ? Properties.field : Color(white: 0, opacity: 0)))
        .onTapGesture { group = index }
    }

    var body: some View
    {
      if sculpt.showsShelf
      {
        let brushes = group < 0 ? SculptBrush.groups.flatMap { $0 } : SculptBrush.groups[group]
        VStack(alignment: .leading, spacing: 0)
        {
          Rectangle()
            .fill(Color(white: 0.09))
            .frame(height: 1)

          ScrollView(.horizontal)
          {
            HStack(spacing: 4)
            {
              ForEach(brushes, id: \.self)
              { brush in
                VStack(spacing: 3)
                {
                  SymbolIcon(brush.symbol, size: 22, white: sculpt.brush == brush ? 1 : 0.85)
                    .frame(width: 58, height: 38)
                  Text(brush.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(sculpt.brush == brush ? Properties.text : Properties.label)
                }
                .frame(width: 66, height: 62)
                .background(RoundedRectangle(cornerRadius: 5)
                  .fill(sculpt.brush == brush ? Properties.accent : Color(white: 0.16)))
                .onTapGesture { sculpt.brush = brush }
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
          }
          .frame(height: 74)

          HStack(spacing: 2)
          {
            tab("All", -1)
            ForEach(Array(Self.groupNames.indices), id: \.self) { i in tab(Self.groupNames[i], i) }
            Spacer()
          }
          .padding(.horizontal, 6)
          .padding(.bottom, 4)
        }
        .background(Properties.region)
      }
    }
  }

  /// the bar under the header with what the brush does, the way the tool settings sit over a viewport
  @MainActor
  struct SculptHeader: View
  {
    @State private var sculpt: Sculpt

    init(sculpt: Sculpt)
    {
      _sculpt = State(wrappedValue: sculpt)
    }

    private func label(_ text: String, _ width: Double) -> some View
    {
      Text(text)
        .font(Properties.font)
        .foregroundColor(Properties.label)
        .frame(width: width, alignment: .trailing)
    }

    private var brushes: [MenuEntry]
    {
      let sculpt = sculpt
      return SculptBrush.groups.enumerated().flatMap
      { i, group in
        (i > 0 ? [MenuEntry.separator] : [])
          + group.map { brush in MenuEntry(title: brush.rawValue, checked: sculpt.brush == brush) { sculpt.brush = brush } }
      }
    }

    var body: some View
    {
      let sculpt = sculpt
      HStack(spacing: 6)
      {
        HeaderMenu(sculpt.brush.rawValue, symbol: sculpt.brush.symbol, width: 124) { brushes }

        // labels and sliders hold their widths so a tight bar doesn't squeeze the text
        label("Size", 28)
        SliderField(value: sculpt.$radius, range: 2 ... 400, step: 1, width: 96) { "\(Int($0)) px" }
          .frame(width: 96)
        BarToggle("hand.draw", on: sculpt.pressureSize) { sculpt.pressureSize.toggle() }
        label("Strength", 50)
        SliderField(value: sculpt.$strength, range: 0 ... 1, step: 0.01, width: 86) { String(format: "%.3f", $0) }
          .frame(width: 86)
        BarToggle("hand.draw", on: sculpt.pressureStrength) { sculpt.pressureStrength.toggle() }

        HStack(spacing: 1)
        {
          BarToggle("plus", on: !sculpt.invert) { sculpt.invert = false }
          BarToggle("minus", on: sculpt.invert) { sculpt.invert = true }
        }

        HeaderMenu("Falloff", width: 74)
        {
          SculptFalloff.allCases.map { falloff in MenuEntry(title: falloff.rawValue, checked: sculpt.falloff == falloff) { sculpt.falloff = falloff } }
        }

        HeaderMenu("Stroke", width: 70)
        {
          [("Off", 0.0), ("Light", 0.3), ("Medium", 0.5), ("Strong", 0.8)].map
          { name, amount in
            MenuEntry(title: "Stabilizer \(name)", checked: abs(sculpt.lazy - amount) < 0.05) { sculpt.lazy = amount }
          }
        }

        Spacer()

        SymbolIcon("arrow.left.and.right.righttriangle.left.righttriangle.right", size: 11, white: 0.8)
        HStack(spacing: 1)
        {
          BarToggle("", label: "X", on: sculpt.mirror[0]) { sculpt.mirror[0].toggle() }
          BarToggle("", label: "Y", on: sculpt.mirror[1]) { sculpt.mirror[1].toggle() }
          BarToggle("", label: "Z", on: sculpt.mirror[2]) { sculpt.mirror[2].toggle() }
        }

        HeaderMenu(sculpt.isRemeshing ? "Remeshing..." : "Remesh: \(sculpt.detailName)", symbol: "point.3.connected.trianglepath.dotted", width: 132)
        {
          sculpt.remeshEntries
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(Properties.region)
    }
  }

  /// remesh beside the other sculpt buttons on touch, an hourglass while it runs
  @MainActor
  struct SculptRemeshButton: View
  {
    @State private var sculpt: Sculpt

    init(sculpt: Sculpt)
    {
      _sculpt = State(wrappedValue: sculpt)
    }

    var body: some View
    {
      let sculpt = sculpt
      MenuButton(symbol: sculpt.isRemeshing ? "hourglass" : "point.3.connected.trianglepath.dotted")
      {
        sculpt.remeshEntries
      }
    }
  }

  /// size and strength along the bottom of the viewport on touch, going to two rows when one would be too short to drag
  @MainActor
  struct SculptBrushBar: View
  {
    @State private var sculpt: Sculpt
    let width: Double

    init(sculpt: Sculpt, width: Double)
    {
      _sculpt = State(wrappedValue: sculpt)
      self.width = width
    }

    static let spacing = 8.0
    static let inset = 10.0
    static let icon = 14.0
    static let toggle = icon + 12
    static let widest = 220.0
    static let shortest = 110.0

    /// the width one slider gets when a row holds the given number of icon, slider and toggle sets
    private func slider(sets: Double) -> Double
    {
      let fixed = sets * (Self.icon + Self.toggle + Self.spacing * 2) + Self.spacing * (sets - 1) + Self.inset * 4
      return min(max((width - fixed) / sets, 0), Self.widest)
    }

    private func radius(_ width: Double) -> some View
    {
      HStack(spacing: Int(Self.spacing))
      {
        SymbolIcon("circle.dashed", size: Self.icon, white: 0.9)
        SliderField(value: sculpt.$radius, range: 4 ... 400, step: 1, width: width) { "\(Int($0))" }
          .frame(width: width)
        BarToggle("minus.circle", on: sculpt.invert) { sculpt.invert.toggle() }
      }
    }

    private func strength(_ width: Double) -> some View
    {
      HStack(spacing: Int(Self.spacing))
      {
        SymbolIcon("bolt.fill", size: Self.icon, white: 0.9)
        SliderField(value: sculpt.$strength, range: 0 ... 1, step: 0.01, width: width) { String(format: "%.2f", $0) }
          .frame(width: width)
        BarToggle("arrow.left.and.right.righttriangle.left.righttriangle.right", on: sculpt.mirror[0]) { sculpt.mirror[0].toggle() }
      }
    }

    var body: some View
    {
      let one = slider(sets: 2)
      let rows = Group
      {
        if one >= Self.shortest
        {
          HStack(spacing: Int(Self.spacing))
          {
            radius(one)
            strength(one)
          }
        }
        else
        {
          let two = slider(sets: 1)
          VStack(spacing: 6)
          {
            radius(two)
            strength(two)
          }
        }
      }

      return rows
        .padding(.horizontal, Int(Self.inset))
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Touch.chrome))
        .padding(Int(Self.inset))
    }
  }

  /// the sculpting tab's properties in the same frame as every other editor, tabs, header and scrolling panels
  @MainActor
  struct SculptProperties: View
  {
    @State private var sculpt: Sculpt
    @State private var tab = Tab.tool
    let layout: Layout

    /// the editor's tabs, top to bottom, split the way the render editor splits its own
    enum Tab: CaseIterable, Hashable
    {
      case tool, paint, sculpt, look

      var title: String
      {
        switch self
        {
          case .tool: "Tool"
          case .paint: "Paint"
          case .sculpt: "Sculpt"
          case .look: "Look"
        }
      }

      var icon: TabIcon.Kind
      {
        switch self
        {
          case .tool: .properties
          case .paint: .material
          case .sculpt: .object
          case .look: .render
        }
      }
    }

    /// `width` is what the sidebar gives the panels after the tab column, controls stretch to fill it
    init(layout: Layout, width: Int = Properties.width)
    {
      Properties.panelWidth = max(width, Properties.width)
      self.layout = layout
      _sculpt = State(wrappedValue: layout.sculpt)
    }

    /// colors kept as rgb numbers, shown through the same swatch every other panel uses
    private func color(_ get: @escaping () -> SIMD3<Double>, _ set: @escaping (SIMD3<Double>) -> Void) -> Binding<SIMD3<Float>>
    {
      Binding(get: { SIMD3<Float>(get()) }, set: { set(SIMD3<Double>($0)) })
    }

    private func swatch(_ label: String, _ binding: Binding<SIMD3<Float>>) -> some View
    {
      Properties.row(label) { ColorField(color: binding) }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double,
                        format: @escaping (Double) -> String = { String(format: "%.2f", $0) }) -> some View
    {
      Properties.row(label) { SliderField(value: value, range: range, step: step, format: format) }
    }

    private func choice<Value: Equatable & CustomStringConvertible>(_ label: String, _ options: [Value],
                                                                     _ get: @escaping () -> Value,
                                                                     _ set: @escaping (Value) -> Void) -> some View
    {
      Properties.row(label)
      {
        Dropdown(options: options, selection: Binding(get: { get() }, set: { if let v = $0 { set(v) } }))
      }
    }

    private func button(_ title: String, accent: Bool = false, _ action: @escaping () -> Void) -> some View
    {
      Properties.row("") { PanelButton(title, accent: accent, action: action) }
    }

    /// a checkbox under a label that names what it belongs to, the way the output panel lays them out
    private func check(_ label: String, _ title: String, _ isOn: Binding<Bool>) -> some View
    {
      Properties.row(label) { Checkbox(label: title, isOn: isOn) }
    }

    /// switches side by side across the control column, each on or off by itself
    private func toggles(_ label: String, _ items: [(String, Binding<Bool>)]) -> some View
    {
      let width = Double(Properties.controlWidth - (items.count - 1)) / Double(max(items.count, 1))
      return Properties.row(label)
      {
        HStack(spacing: 1)
        {
          ForEach(Array(items.indices), id: \.self)
          { i in
            Segment(title: items[i].0, selected: items[i].1.wrappedValue, width: width)
              .onTapGesture { items[i].1.wrappedValue.toggle() }
          }
        }
        .cornerRadius(4)
      }
    }

    /// paints that reach the painting's palette, bone, rose, ink, crimson, gunmetal and umber
    static let swatches: [SIMD3<Double>] = [
      SIMD3(0.93, 0.89, 0.86), SIMD3(0.78, 0.62, 0.58), SIMD3(0.55, 0.22, 0.27), SIMD3(0.62, 0.04, 0.09),
      SIMD3(0.06, 0.06, 0.07), SIMD3(0.22, 0.23, 0.25), SIMD3(0.42, 0.33, 0.24), SIMD3(0.72, 0.66, 0.55),
    ]

    var body: some View
    {
      HStack(spacing: 0)
      {
        VStack(spacing: 2)
        {
          ForEach(Tab.allCases, id: \.self)
          { t in
            TabIcon(kind: t.icon, background: tab == t ? Properties.tabActiveWhite : Properties.tabButtonWhite)
              .frame(width: 24, height: 24)
              .background(RoundedRectangle(cornerRadius: 4).fill(tab == t ? Properties.tabActive : Properties.tabButton))
              .onTapGesture { tab = t }
          }

          Spacer()
        }
        .padding(.vertical, 6)
        .frame(width: 30)
        .background(Properties.tabs)

        VStack(alignment: .leading, spacing: 0)
        {
          HStack(spacing: 6)
          {
            TabIcon(kind: tab.icon, background: Properties.tabActiveWhite)
            Text(tab.title)
              .font(.system(size: 11))
              .foregroundColor(Properties.text)
            Spacer()
            Text("AKARI 灯り")
              .font(.system(size: 10, weight: .semibold))
              .foregroundColor(Properties.label)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 7)

          PropertiesScroll
          {
            VStack(alignment: .leading, spacing: 4)
            {
              if tab == .tool
              {
                tool
              }
              else if tab == .paint
              {
                paint
              }
              else if tab == .sculpt
              {
                sculptTab(sculpt)
              }
              else
              {
                look
              }
            }
            .padding(6)
          }
        }
        .frame(width: Double(Properties.panelWidth))
        .background(Properties.region)
      }
    }

    /// the brush and what it draws with
    @ViewBuilder
    private var tool: some View
    {
      let sculpt = sculpt
      PropertiesPanel("Brush Asset")
      {
        Properties.row("")
        {
          VStack(alignment: .leading, spacing: 0)
          {
            SymbolIcon(sculpt.brush.symbol, size: 44, white: 0.92)
              .frame(width: Double(Properties.controlWidth), height: 84)
            Text(sculpt.brush.rawValue)
              .font(Properties.font)
              .foregroundColor(Properties.text)
              .padding(.horizontal, 8)
              .frame(width: Double(Properties.controlWidth), height: 22, alignment: .leading)
              .background(Color(white: 0.12))
          }
          .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.2)))
          .cornerRadius(5)
        }

        choice("Brush", SculptBrush.allCases.map(\.rawValue), { sculpt.brush.rawValue })
        { name in
          if let brush = SculptBrush(rawValue: name) { sculpt.brush = brush }
        }
      }

      PropertiesPanel("Brush Settings")
      {
        slider("Size", sculpt.$radius, 2 ... 400, 1) { "\(Int($0)) px" }
        slider("Strength", sculpt.$strength, 0 ... 1, 0.001) { String(format: "%.3f", $0) }
        Properties.row("Direction")
        {
          Segmented(options: ["Add", "Subtract"],
                    selection: Binding(get: { sculpt.invert ? "Subtract" : "Add" }, set: { sculpt.invert = $0 == "Subtract" }))
        }
        choice("Falloff", SculptFalloff.allCases, { sculpt.falloff }) { sculpt.falloff = $0 }
        slider("Stabilizer", sculpt.$lazy, 0 ... 1, 0.01)
        toggles("Pressure", [("Size", sculpt.$pressureSize), ("Strength", sculpt.$pressureStrength)])
        check("Paint", "While Sculpting", sculpt.$paintsWhileSculpting)
        #if !os(macOS)
          check("Fingers", "Sculpt", sculpt.$fingersSculpt)
        #endif
      }

      PropertiesPanel("Symmetry")
      {
        toggles("Mirror", [("X", Binding(get: { sculpt.mirror[0] }, set: { sculpt.mirror[0] = $0 })),
                           ("Y", Binding(get: { sculpt.mirror[1] }, set: { sculpt.mirror[1] = $0 })),
                           ("Z", Binding(get: { sculpt.mirror[2] }, set: { sculpt.mirror[2] = $0 }))])
      }

      PropertiesPanel("Pencil")
      {
        swatch("Color", color({ sculpt.pencilColor }) { sculpt.pencilColor = $0 })
        slider("Width", sculpt.$pencilWidth, 1 ... 60, 0.5) { "\(Int($0)) pt" }
        slider("Opacity", sculpt.$pencilOpacity, 0.05 ... 1, 0.01)
        choice("Placement", SculptPlacement.allCases, { sculpt.placement }) { sculpt.placement = $0 }
        button("Clear Strokes") { sculpt.clearPencil() }
      }

      PropertiesPanel("Shapes")
      {
        choice("Shape", SculptShape.allCases, { sculpt.shape }) { sculpt.shape = $0 }
        choice("Combine", SculptCombine.allCases, { sculpt.combine }) { sculpt.combine = $0 }
        button("Add at Brush", accent: true) { sculpt.insertShape() }
      }

      PropertiesPanel("Mask", expanded: false)
      {
        check("Overlay", "Show Mask", sculpt.$showsMask)
        button("Invert Mask") { sculpt.invertMask() }
        button("Clear Mask") { sculpt.clearMask() }
      }
    }

    /// the paint laid on the surface and the reference it can be projected from
    @ViewBuilder
    private var paint: some View
    {
      let sculpt = sculpt
      PropertiesPanel("Paint")
      {
        swatch("Color", color({ sculpt.paint }) { sculpt.paint = $0 })
        slider("Gloss", sculpt.$gloss, 0 ... 1, 0.01)
        Properties.row("Swatches")
        {
          let side = Double(Properties.controlWidth - 3 * (Self.swatches.count - 1)) / Double(Self.swatches.count)
          HStack(spacing: 3)
          {
            ForEach(Array(Self.swatches.indices), id: \.self)
            { i in
              let c = Self.swatches[i]
              RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: c.x, green: c.y, blue: c.z))
                .frame(width: side, height: Double(Properties.rowHeight))
                .onTapGesture { sculpt.paint = c }
            }
          }
        }

        button("Fill Surface") { sculpt.fillPaint() }
      }

      PropertiesPanel("Reference")
      {
        Properties.row("Image") { Readout(sculpt.reference?.url.lastPathComponent ?? "None") }
        button("Load Image…") { sculpt.chooseReference() }
        check("Overlay", "Show Over Sculpt", sculpt.$showsReference)
        slider("Opacity", sculpt.$referenceOpacity, 0 ... 1, 0.01)
        button("Project Paint From View", accent: true) { sculpt.projectReferenceFromView() }
        button("Remove Image") { sculpt.clearReference() }
      }
    }

    /// the sculpt itself, its detail and where it lives in the scene
    @ViewBuilder
    private func sculptTab(_ sculpt: Sculpt) -> some View
    {
      PropertiesPanel("Remesh")
      {
        let range = sculpt.voxelRange
        slider("Voxel Size", sculpt.$remeshVoxel, range, (range.upperBound - range.lowerBound) / 1000)
        { Sculpt.format(voxel: $0) }
        button(sculpt.isRemeshing ? "Remeshing..." : "Remesh", accent: true) { sculpt.remeshAtPanelSize() }
        button("Add Detail") { sculpt.addDetail() }
        button("Reduce Detail") { sculpt.reduceDetail() }
        choice("Detail Level", SculptDetail.allCases, { sculpt.detail }) { sculpt.setDetail($0) }
        Properties.row("Surface") { Readout("\(sculpt.surfaceFaces.formatted()) faces") }
        button("Smooth All") { sculpt.smoothAll() }
      }

      PropertiesPanel("Scene")
      {
        Properties.row("Prim") { Readout(sculpt.primPath ?? "Select a mesh") }
        button("Write to Scene Now", accent: true) { sculpt.writeNow() }
      }
    }

    /// how the viewport draws it
    @ViewBuilder
    private var look: some View
    {
      let sculpt = sculpt
      PropertiesPanel("Look")
      {
        choice("Shading", SculptShading.allCases, { sculpt.shading }) { sculpt.shading = $0 }
        slider("Lighting", sculpt.$lighting, 0 ... 1, 0.01)
        slider("Light Angle", sculpt.$lightAngle, -180 ... 180, 1) { "\(Int($0))°" }
        slider("Light Height", sculpt.$lightHeight, -10 ... 90, 1) { "\(Int($0))°" }
        slider("Warmth", sculpt.$warmth, 0 ... 1, 0.01)
        slider("Ambient", sculpt.$ambient, 0 ... 1, 0.01)
        slider("Rim", sculpt.$rim, 0 ... 2, 0.01)
        slider("Cavity", sculpt.$cavity, 0 ... 1, 0.01)
        swatch("Clay", color({ sculpt.clayColor }) { sculpt.clayColor = $0 })
        swatch("Backdrop Top", color({ sculpt.backgroundTop }) { sculpt.backgroundTop = $0 })
        swatch("Backdrop Bottom", color({ sculpt.backgroundBottom }) { sculpt.backgroundBottom = $0 })
      }

      PropertiesPanel("Painterly")
      {
        slider("Stroke Size", sculpt.$strokeSize, 2 ... 40, 0.5) { "\(Int($0)) pt" }
        slider("Stroke Length", sculpt.$strokeLength, 1 ... 6, 0.1)
        slider("Density", sculpt.$strokeDensity, 0 ... 1, 0.01)
        slider("Abstraction", sculpt.$abstraction, 1 ... 12, 0.5)
        slider("Value Bands", sculpt.$bands, 1 ... 10, 1) { "\(Int($0))" }
        slider("Canvas", sculpt.$canvasGrain, 0 ... 1, 0.01)
        slider("Lost Edges", sculpt.$lostEdges, 0 ... 1, 0.01)
        check("Splats", "Write to USD", sculpt.$writesSplats)
      }
    }
  }
}

extension Kraken.Sculpt
{
  /// how much surface the sculpt has and the ways to change it, the same in the header, the menus and on touch
  var remeshEntries: [Kraken.MenuEntry]
  {
    typealias Entry = Kraken.MenuEntry
    let voxel = Self.format(voxel: Double(volume.voxel))
    var entries = [Entry.header("\(detailName) Detail, voxel \(voxel), \(surfaceFaces.formatted()) faces"),
                   Entry("Add Detail", "r", [.control]) { self.addDetail() },
                   Entry("Reduce Detail", "r", [.control, .shift]) { self.reduceDetail() },
                   Entry.separator]

    for level in Kraken.SculptDetail.allCases
    {
      var item = Entry("Remesh at \(level.rawValue)") { self.setDetail(level) }
      item.checked = detailName == level.rawValue
      entries.append(item)
    }

    return entries
  }
}
