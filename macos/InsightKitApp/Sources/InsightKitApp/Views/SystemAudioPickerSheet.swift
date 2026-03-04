import SwiftUI

struct SystemAudioPickerSheet: View {
    let sources: [SystemAudioSourceItem]
    let selectedID: String?
    let onReload: () -> Void
    let onSelect: (String?) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var draftSelectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("系统音频源")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("刷新") {
                    onReload()
                }
            }

            if sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("未发现可用音频源。")
                    Text("请先开始播放系统音频后再刷新。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(sources, selection: $draftSelectedID) { source in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.title)
                                .font(.body.weight(.medium))
                            Text(source.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if draftSelectedID == source.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(InsightTheme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draftSelectedID = source.id
                    }
                    .tag(Optional(source.id))
                }
                .listStyle(.inset)
            }

            HStack {
                Button("确定") {
                    onSelect(draftSelectedID)
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftSelectedID == nil)
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 620, height: 460)
        .onAppear {
            if draftSelectedID == nil {
                draftSelectedID = selectedID ?? sources.first?.id
            }
        }
        .onChange(of: selectedID) { _, newValue in
            draftSelectedID = newValue
        }
        .onChange(of: sources) { _, newSources in
            if let current = draftSelectedID, newSources.contains(where: { $0.id == current }) {
                return
            }
            draftSelectedID = newSources.first?.id
        }
    }
}
