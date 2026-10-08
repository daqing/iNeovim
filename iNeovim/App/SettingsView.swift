import SwiftUI

/// Settings window: appearance (font family/size), input behavior, and
/// animation toggles. Changes apply live — `AppSettings` is shared with the
/// render view.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    private let families = AppSettings.monospacedFamilies()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Font", selection: $settings.fontFamily) {
                    Text("System Monospaced").tag("")
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.fontSize, in: 8...32, step: 1)
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Input") {
                Toggle("Option as Meta (\u{2325})", isOn: $settings.optionAsMeta)
                Toggle("Pass Command chords to Neovim", isOn: $settings.passCmdKeysThrough)
            }

            Section("Animation") {
                Toggle("Animate scrolling", isOn: $settings.scrollAnimationEnabled)
                Toggle("Animate cursor", isOn: $settings.cursorAnimationEnabled)
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}

#Preview {
    SettingsView(settings: AppSettings.shared)
}
