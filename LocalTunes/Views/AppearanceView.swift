import SwiftUI

struct AppearanceView: View {
    @AppStorage("theme.appearance") private var appearance = "system"
    @AppStorage("theme.accent") private var accent = "crimson"
    @AppStorage("theme.custom") private var hex = "FA243C"
    @AppStorage("theme.motion") private var motion = true
    @AppStorage("theme.blur") private var blur = 85.0
    @State private var color = Color.red
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            Picker("Accent", selection: $accent) { Text("Crimson").tag("crimson"); Text("Album artwork").tag("artwork"); Text("Custom").tag("custom") }
            if accent == "custom" {
                ColorPicker("Accent colour", selection: $color, supportsOpacity: false)
                    .onChange(of: color) { _, value in
                        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                        UIColor(value).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                        hex = String(format: "%02X%02X%02X", Int(min(1, max(0, red)) * 255), Int(min(1, max(0, green)) * 255), Int(min(1, max(0, blue)) * 255))
                    }
            }
            Toggle("Animate player background", isOn: $motion)
            LabeledContent("Player blur", value: String(Int(blur)))
            Slider(value: $blur, in: 20...120)
            Text("System Reduce Motion and Reduce Transparency take priority. Accent brightness adapts for readable controls.").font(.footnote).foregroundStyle(.secondary)
            Button("Reset appearance") { appearance = "system"; accent = "crimson"; hex = "FA243C"; motion = true; blur = 85 }
        }.navigationTitle("Appearance").onAppear {
            let value = UInt32(hex, radix: 16) ?? 0xFA243C
            color = Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }
    }
}
