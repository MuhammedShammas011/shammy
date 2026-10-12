// KeyboardView.swift
// MacLink – iOS Client
// On-screen keyboard for text entry, special keys, and modifier combinations.

import SwiftUI

struct KeyboardView: View {
    @EnvironmentObject var session: ClientSession
    let onDismiss: () -> Void

    @State private var modifiers: Set<ModifierKey> = []
    @State private var textInput = ""

    enum ModifierKey: String, CaseIterable, Identifiable {
        case command = "⌘"
        case option  = "⌥"
        case control = "⌃"
        case shift   = "⇧"
        var id: String { rawValue }

        var flag: UInt32 {
            switch self {
            case .command: return ModifierFlag.command.rawValue
            case .option:  return ModifierFlag.option.rawValue
            case .control: return ModifierFlag.control.rawValue
            case .shift:   return ModifierFlag.shift.rawValue
            }
        }
    }

    var currentFlags: UInt32 {
        modifiers.reduce(0) { $0 | $1.flag }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {

                // MARK: Text input bar
                HStack(spacing: 12) {
                    TextField("Type and send…", text: $textInput)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.12))
                        .cornerRadius(10)

                    Button("Send") {
                        sendText()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .cornerRadius(10)
                    .disabled(textInput.isEmpty)
                }
                .padding(.horizontal, 16)

                Divider().background(Color(white: 0.2))

                // MARK: Modifier keys
                HStack(spacing: 10) {
                    ForEach(ModifierKey.allCases) { key in
                        modifierButton(key)
                    }
                }
                .padding(.horizontal, 16)

                // MARK: Special keys grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                           spacing: 8) {
                    specialKey("Esc",  keyCode: MacKeyCode.escape.rawValue)
                    specialKey("Tab",  keyCode: MacKeyCode.tab.rawValue)
                    specialKey("⏎",    keyCode: MacKeyCode.return.rawValue)
                    specialKey("⌫",    keyCode: MacKeyCode.delete.rawValue)
                    specialKey("↑",    keyCode: MacKeyCode.upArrow.rawValue)
                    specialKey("↓",    keyCode: MacKeyCode.downArrow.rawValue)
                    specialKey("←",    keyCode: MacKeyCode.leftArrow.rawValue)
                    specialKey("→",    keyCode: MacKeyCode.rightArrow.rawValue)
                    specialKey("Home", keyCode: MacKeyCode.home.rawValue)
                    specialKey("End",  keyCode: MacKeyCode.end.rawValue)
                    specialKey("PgUp", keyCode: MacKeyCode.pageUp.rawValue)
                    specialKey("PgDn", keyCode: MacKeyCode.pageDown.rawValue)
                }
                .padding(.horizontal, 16)

                Divider().background(Color(white: 0.2))

                // MARK: Common shortcuts
                VStack(alignment: .leading, spacing: 10) {
                    Text("SHORTCUTS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            shortcutButton("⌘C",  keyCode: MacKeyCode.c.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘V",  keyCode: MacKeyCode.v.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘X",  keyCode: MacKeyCode.x.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘Z",  keyCode: MacKeyCode.z.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘A",  keyCode: MacKeyCode.a.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘⇥",  keyCode: MacKeyCode.tab.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘⎵",  keyCode: MacKeyCode.space.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘W",  keyCode: MacKeyCode.w.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘Q",  keyCode: MacKeyCode.q.rawValue, mods: ModifierFlag.command.rawValue)
                            shortcutButton("⌘T",  keyCode: MacKeyCode.t.rawValue, mods: ModifierFlag.command.rawValue)
                        }
                        .padding(.horizontal, 16)
                    }
                }

                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
            .background(Color(white: 0.05).ignoresSafeArea())
        }
    }

    // MARK: - Helpers

    private func modifierButton(_ key: ModifierKey) -> some View {
        let active = modifiers.contains(key)
        return Button {
            if active { modifiers.remove(key) }
            else { modifiers.insert(key) }
        } label: {
            Text(key.rawValue)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(active ? Color.white : Color(white: 0.15))
                .foregroundStyle(active ? Color.black : Color.white)
                .cornerRadius(10)
        }
    }

    private func specialKey(_ label: String, keyCode: UInt16) -> some View {
        Button {
            sendKey(keyCode: keyCode)
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color(white: 0.15))
                .foregroundStyle(.white)
                .cornerRadius(10)
        }
    }

    private func shortcutButton(_ label: String, keyCode: UInt16, mods: UInt32) -> some View {
        Button {
            sendKey(keyCode: keyCode, extraMods: mods)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.15))
                .foregroundStyle(.white)
                .cornerRadius(10)
        }
    }

    private func sendText() {
        let msg = ControlMessage(type: .textInput,
                                  payload: .textInput(TextInputPayload(text: textInput)))
        session.send(msg)
        textInput = ""
        modifiers = []
    }

    private func sendKey(keyCode: UInt16, extraMods: UInt32 = 0) {
        let flags = currentFlags | extraMods
        let down = ControlMessage(type: .keyDown,
                                   payload: .keyEvent(KeyEventPayload(
                                     keyCode: keyCode, pressed: true, modifiers: flags)))
        let up = ControlMessage(type: .keyUp,
                                 payload: .keyEvent(KeyEventPayload(
                                   keyCode: keyCode, pressed: false, modifiers: 0)))
        session.send(down)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.session.send(up)
            // Auto-clear sticky modifiers after one use
            self.modifiers = []
        }
    }
}
